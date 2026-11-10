# Test for REGISTRY_MIRRORS, in its three places:
#
#   - the launcher (flake.nix) refuses a malformed value before it touches the
#     host;
#   - scripts/registry-mirrors.sh, run here against a scratch root exactly as
#     cri-registry-mirrors runs it against / at boot, writes each runtime's
#     config — and nothing when unset, when sealed, or for an entry that would
#     otherwise become a path outside the root;
#   - the evaluated guest wires it up: the service runs before every daemon,
#     dockerd takes the mirror flag, and both containerd instances read the
#     hosts directory.
{ pkgs, lib, runner, config }:

let
  envGet = pkgs.writeShellApplication {
    name = "microvm-env-get";
    text = builtins.readFile ../scripts/microvm-env-get.sh;
  };
  mirrors = pkgs.writeShellApplication {
    name = "registry-mirrors";
    runtimeInputs = with pkgs; [ coreutils envGet ];
    text = builtins.readFile ../scripts/registry-mirrors.sh;
  };

  svc = config.systemd.services.cri-registry-mirrors;
  daemons = [ "cri-activate.service" "containerd.service" "containerd-crun.service" "crio.service" "docker.service" "podman.service" ];
  docker = config.systemd.services.docker.serviceConfig;
  etc = config.environment.etc;

  structural = [
    {
      # The env file is read as root.
      name = "the boot script reads the env file as data, never sources it";
      ok = let s = builtins.readFile ../scripts/registry-mirrors.sh; in
        !lib.any (p: lib.hasInfix p s) [ ''source "$env_file"'' ''. "$env_file"'' ]
        && lib.hasInfix ''microvm-env-get "$env_file" REGISTRY_MIRRORS'' s;
    }
    {
      name = "cri-registry-mirrors runs before every container daemon";
      ok = lib.all (d: lib.elem d svc.before) daemons;
    }
    {
      name = "it reads the launcher's env file and writes to /";
      ok = lib.hasSuffix "/bin/registry-mirrors ${config.claude-vm.instance.dir}/env /" svc.serviceConfig.ExecStart;
    }
    {
      name = "dockerd takes $DOCKERD_MIRROR_ARGS unbraced, so unset adds no argument";
      ok = lib.hasSuffix " $DOCKERD_MIRROR_ARGS" docker.ExecStart;
    }
    {
      name = "dockerd reads the env file it comes from, optionally";
      ok = lib.elem "-/run/cri-registry-mirrors.env" (lib.toList docker.EnvironmentFile);
    }
    {
      name = "both containerd instances read /etc/containerd/certs.d";
      ok = lib.all (f: lib.hasInfix ''config_path = "/etc/containerd/certs.d"'' etc.${f}.text)
        [ "containerd/config.toml" "containerd/config-crun.toml" ];
    }
  ];

  failed = lib.filter (c: !c.ok) structural;
in
pkgs.runCommand "registry-mirrors" { } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${lib.concatMapStrings (c: ''ok ${lib.escapeShellArg c.name}
  '') (lib.filter (c: c.ok) structural)}
  ${lib.concatMapStrings (c: ''bad ${lib.escapeShellArg c.name}
  '') failed}

  # --- the launcher ---------------------------------------------------------
  script=${runner}/bin/microvm-run
  mkdir -p "$TMPDIR/w"
  for v in 'docker.io' 'docker.io=10.0.2.2:5101' 'docker.io=ftp://h' \
           'docker.io=http://h/path' '../etc=http://h' 'docker.io=http://h,,ghcr.io=http://h'; do
    if REGISTRY_MIRRORS="$v" WORK_DIR=$TMPDIR/w "$script" >/dev/null 2>launch.err; then
      bad "REGISTRY_MIRRORS='$v' was accepted"
    elif grep -q "REGISTRY_MIRRORS entries must be" launch.err; then
      ok "the launcher refuses REGISTRY_MIRRORS='$v'"
    else
      bad "REGISTRY_MIRRORS='$v' failed, but not with the validation message:"; cat launch.err >&2
    fi
  done
  if REGISTRY_MIRRORS='docker.io=http://h,ghcr.io=http://g,docker.io=http://g' WORK_DIR=$TMPDIR/w "$script" >/dev/null 2>launch.err; then
    bad "a registry listed twice was accepted"
  elif grep -q "REGISTRY_MIRRORS lists docker.io more than once" launch.err; then
    ok "the launcher refuses a registry listed twice"
  else
    bad "a registry listed twice failed, but not with the duplicate message:"; cat launch.err >&2
  fi
  # A good value gets past validation; the launch then fails for want of a
  # host, which is not what is under test.
  REGISTRY_MIRRORS='docker.io=http://10.0.2.2:5101,localhost:5000=https://m.example:8443/' \
    WORK_DIR=$TMPDIR/w "$script" >/dev/null 2>launch.err || true
  if grep -q "REGISTRY_MIRRORS" launch.err; then
    bad "a valid REGISTRY_MIRRORS was refused:"; cat launch.err >&2
  else
    ok "the launcher accepts a valid REGISTRY_MIRRORS"
  fi
  if [ "$(grep -c 'REGISTRY_MIRRORS=%q' "$script")" -eq 1 ]; then
    ok "the launcher hands REGISTRY_MIRRORS to the guest, %q-quoted"
  else
    bad "REGISTRY_MIRRORS is not written to the env file exactly once"
  fi

  # --- the boot script --------------------------------------------------------
  # An env line as the launcher writes it: printf %q, which escapes the commas.
  q () { printf '%s=%q' "$1" "$2"; }
  run () { # name env-file-content
    root="$TMPDIR/$1"; mkdir -p "$root"
    printf '%s\n' "$2" > "$root.env"
    ${mirrors}/bin/registry-mirrors "$root.env" "$root" >"$root.out" 2>&1
  }
  has () { # file text label
    if grep -qF -- "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3: '$2' not in $1"; cat "$1" >&2 2>/dev/null || true; fi
  }

  run unset 'ENABLE_CRI=docker'
  if [ -z "$(find "$TMPDIR/unset" -type f)" ]; then ok "unset writes nothing"; else bad "unset wrote files"; fi

  run typical "$(q REGISTRY_MIRRORS 'docker.io=http://10.0.2.2:5101,ghcr.io=http://10.0.2.2:5102/,localhost:5000=https://m.example:8443')"
  R=$TMPDIR/typical
  has $R/etc/containerd/certs.d/docker.io/hosts.toml 'server = "https://registry-1.docker.io"' "Docker Hub's API host is the containerd server"
  has $R/etc/containerd/certs.d/docker.io/hosts.toml '[host."http://10.0.2.2:5101"]' "docker.io gets its mirror"
  has $R/etc/containerd/certs.d/docker.io/hosts.toml 'capabilities = ["pull", "resolve"]' "the mirror may pull and resolve, never push"
  has $R/etc/containerd/certs.d/ghcr.io/hosts.toml 'server = "https://ghcr.io"' "other registries are their own server"
  has $R/etc/containerd/certs.d/ghcr.io/hosts.toml '[host."http://10.0.2.2:5102"]' "a trailing slash is dropped"
  has $R/etc/containerd/certs.d/localhost:5000/hosts.toml '[host."https://m.example:8443"]' "a registry with a port is its own directory"
  C=$R/etc/containers/registries.conf.d/50-registry-mirrors.conf
  has $C 'prefix = "docker.io"' "podman/CRI-O: docker.io is a registry entry"
  has $C 'location = "10.0.2.2:5101"' "podman/CRI-O: its mirror, without the scheme"
  has $C 'location = "m.example:8443"' "podman/CRI-O: the https mirror"
  if [ "$(grep -c 'insecure = true' $C)" -eq 2 ] && [ "$(grep -c 'insecure = false' $C)" -eq 1 ]; then
    ok "http mirrors are insecure, https ones are not"
  else bad "insecure flags wrong"; cat $C >&2; fi
  has $R/run/cri-registry-mirrors.env 'DOCKERD_MIRROR_ARGS=--registry-mirror=http://10.0.2.2:5101' "dockerd mirrors Docker Hub"
  has $R.out 'mirroring docker.io ghcr.io localhost:5000' "says what it mirrored"

  run nohub "$(q REGISTRY_MIRRORS 'ghcr.io=http://10.0.2.2:5102')"
  if [ "$(cat $TMPDIR/nohub/run/cri-registry-mirrors.env)" = "DOCKERD_MIRROR_ARGS=" ]; then
    ok "without docker.io, dockerd gets no mirror"
  else bad "dockerd got a mirror with no docker.io entry"; fi

  for p in shadow enforce; do
    run "sealed-$p" "$(q REGISTRY_MIRRORS 'docker.io=http://10.0.2.2:5101')
EGRESS_POLICY=$p"
    if [ -z "$(find "$TMPDIR/sealed-$p" -type f)" ] && grep -q "ignoring REGISTRY_MIRRORS" "$TMPDIR/sealed-$p.out"; then
      ok "EGRESS_POLICY=$p writes nothing, and says why"
    else bad "EGRESS_POLICY=$p wrote mirror config"; fi
  done

  # The script trusts nothing it reads: an entry that reaches here unvalidated must
  # not become a path outside the root, or a config line it was not meant to be.
  run hostile "$(q REGISTRY_MIRRORS '../../evil=http://h,docker.io=http://h/x"y,a/b=http://h,ghcr.io=http://10.0.2.2:5102')"
  R=$TMPDIR/hostile
  if [ -z "$(find "$TMPDIR" -maxdepth 1 -name evil)" ] && [ ! -e "$R/etc/evil" ] && [ ! -e "$R/evil" ]; then
    ok "a ../ registry name writes nothing outside the hosts dir"
  else bad "a ../ registry name escaped"; fi
  if [ "$(ls "$R/etc/containerd/certs.d")" = "ghcr.io" ]; then
    ok "only the well-formed entry is written"
  else bad "malformed entries were written: $(ls "$R/etc/containerd/certs.d")"; fi
  if [ "$(grep -c 'skipping malformed entry' "$R.out")" -eq 3 ]; then
    ok "each malformed entry is reported"
  else bad "malformed entries not all reported"; cat "$R.out" >&2; fi

  # Nor may anything in the file run: the script is root.
  canary=$TMPDIR/canary
  run code "touch $canary
REGISTRY_MIRRORS=\$(touch $canary)docker.io=http://h
EGRESS_POLICY=\`touch $canary\`
REGISTRY_MIRRORS=ghcr.io=http://10.0.2.2:5102; touch $canary"
  if [ ! -e $canary ]; then ok "nothing in the env file is run"; else bad "the boot script ran code from the env file"; fi
  if [ -z "$(find $TMPDIR/code/etc/containerd -type f 2>/dev/null)" ]; then
    ok "a hostile REGISTRY_MIRRORS line mirrors nothing"
  else bad "a hostile REGISTRY_MIRRORS line was mirrored: $(find $TMPDIR/code -type f)"; fi

  # A registry listed twice keeps its first mirror, the same in every runtime.
  run dup "$(q REGISTRY_MIRRORS 'docker.io=http://10.0.2.2:5101,ghcr.io=http://10.0.2.2:5102,docker.io=http://10.0.2.2:5999')"
  R=$TMPDIR/dup
  has $R/etc/containerd/certs.d/docker.io/hosts.toml '[host."http://10.0.2.2:5101"]' "duplicate: containerd keeps the first mirror"
  if ! grep -q 5999 $R/etc/containerd/certs.d/docker.io/hosts.toml $R/run/cri-registry-mirrors.env $R/etc/containers/registries.conf.d/50-registry-mirrors.conf; then
    ok "duplicate: the later mirror is written nowhere"
  else bad "duplicate: the later mirror was written"; fi
  has $R/run/cri-registry-mirrors.env 'DOCKERD_MIRROR_ARGS=--registry-mirror=http://10.0.2.2:5101' "duplicate: dockerd keeps the first mirror"
  if [ "$(grep -c 'prefix = "docker.io"' $R/etc/containers/registries.conf.d/50-registry-mirrors.conf)" -eq 1 ]; then
    ok "duplicate: podman/CRI-O get one docker.io entry"
  else bad "duplicate: podman/CRI-O got docker.io more than once"; fi
  has $R.out "skipping duplicate entry 'docker.io=http://10.0.2.2:5999'" "duplicate: the skipped entry is reported"
  has $R.out 'mirroring docker.io ghcr.io' "duplicate: the rest is still mirrored"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
