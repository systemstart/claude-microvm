# Test for claude-vm.shares (README "Extra shares"): host directories a
# downstream flake adds to the guest, declared at build time, given at launch.
#
#   - the guest: each share is a virtiofs share tagged share-<name> at its
#     mount point, mounted ro unless declared writable; a bad name or a
#     mount point over one the VM uses is refused at evaluation;
#   - the built launcher, run for real with systemd and QEMU stubbed
#     (tests/lib/stubbed-launcher.nix): a missing SHARE_<NAME>, one that is
#     not a directory, and one overlapping the launcher's own state are
#     refused before any daemon starts; otherwise each share gets its own
#     virtiofsd in the launch's slice, --readonly unless writable, QEMU is
#     pointed at its socket, the contract and instance.json list it, and on
#     exit its daemon is stopped and its socket gone.
{ pkgs, lib, mkRunner, mkNixosConfig }:

let
  system = pkgs.stdenv.hostPlatform.system;
  sharesModule = {
    claude-vm.shares = {
      audit-out = { mountPoint = "/audit-out"; readOnly = false; };
      skill = { mountPoint = "/skill"; };
    };
  };
  runner = mkRunner { inherit system; modules = [ sharesModule ]; };
  guest = runner.nixosConfig.config;
  share = tag: lib.findFirst (s: s.tag == tag) null guest.microvm.shares;
  lastRw = mp: lib.last ([ "rw" ] ++ lib.filter (o: lib.elem o [ "ro" "rw" "defaults" ]) (guest.fileSystems.${mp}.options or [ ]));

  refusedAt = m: !(builtins.tryEval (builtins.seq (mkNixosConfig { inherit system; modules = [ m ]; }).config.system.build.toplevel.drvPath true)).success;

  structural = [
    {
      name = "each share is a virtiofs share tagged share-<name> at its mount point";
      ok = (share "share-audit-out").mountPoint or "" == "/audit-out" && (share "share-skill").mountPoint or "" == "/skill"
        && (share "share-skill").proto == "virtiofs";
    }
    {
      name = "a share is read-only by default and mounted ro; a writable one is mounted rw";
      ok = (share "share-skill").readOnly && lastRw "/skill" == "ro"
        && !(share "share-audit-out").readOnly && lastRw "/audit-out" != "ro";
    }
    {
      name = "a share name that is not 1-16 of a-z, 0-9 and - is refused";
      ok = refusedAt { claude-vm.shares."Bad_Name".mountPoint = "/x"; };
    }
    {
      name = "a mount point over /work, agent home or the instance share is refused";
      ok = refusedAt { claude-vm.shares.a.mountPoint = "/work/x"; }
        && refusedAt { claude-vm.shares.a.mountPoint = "/home"; }
        && refusedAt { claude-vm.shares.a.mountPoint = "/run/microvm"; };
    }
  ];

  harness = import ./lib/stubbed-launcher.nix { inherit pkgs runner; };
in
pkgs.runCommand "extra-shares" { nativeBuildInputs = [ pkgs.socat pkgs.sqlite pkgs.jq ]; } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${lib.concatMapStrings (c: if c.ok then ''ok ${lib.escapeShellArg c.name}
  '' else ''bad ${lib.escapeShellArg c.name}
  '') structural}

  ${harness.preamble}

  export XDG_DATA_HOME=$TMPDIR/data XDG_RUNTIME_DIR=$TMPDIR/rt HOME=$TMPDIR/home WORK_DIR=$TMPDIR/proj NO_PAUSE=1
  unset AGENT_HOME
  mkdir -p $XDG_DATA_HOME/claude-microvm $XDG_RUNTIME_DIR $HOME $WORK_DIR $TMPDIR/out $TMPDIR/skill
  export HOST_DB=$TMPDIR/host-db.sqlite
  sqlite3 $HOST_DB "CREATE TABLE ValidPaths (path TEXT);"

  refused () { # name message, then env
    n=$1 msg=$2; shift 2
    launch "$n" "$@"
    if [ "$(cat $TMPDIR/$n/rc)" != 0 ] && grep -q -- "$msg" $TMPDIR/$n/out && [ -z "$(find $TMPDIR/$n -name '*.args')" ]; then
      ok "refused before any daemon: $*"
    else bad "not refused as expected: $* (rc $(cat $TMPDIR/$n/rc))"; cat $TMPDIR/$n/out >&2; fi
  }
  refused missing "set SHARE_AUDIT_OUT=<host dir>" SHARE_SKILL=$TMPDIR/skill
  refused notdir "SHARE_SKILL=$TMPDIR/nope is not a directory" SHARE_AUDIT_OUT=$TMPDIR/out SHARE_SKILL=$TMPDIR/nope
  mkdir -p $XDG_DATA_HOME/claude-microvm/sub
  refused in-state "is inside $XDG_DATA_HOME/claude-microvm, this launcher's state" SHARE_AUDIT_OUT=$XDG_DATA_HOME/claude-microvm/sub SHARE_SKILL=$TMPDIR/skill
  refused over-state "contains $XDG_DATA_HOME/claude-microvm, this launcher's state" SHARE_AUDIT_OUT=$TMPDIR/out SHARE_SKILL=$TMPDIR

  launch ok SHARE_AUDIT_OUT=$TMPDIR/out SHARE_SKILL=$TMPDIR/skill
  L=$TMPDIR/ok; J=$L/instance.json; ID=$(jq -r .id $J 2>/dev/null || true)
  [ "$(cat $L/rc)" = 0 ] && [ -e $L/started ] && ok "with both given, the launch runs" || { bad "launch failed: rc $(cat $L/rc)"; cat $L/out >&2; }
  O=$L/claude_microvm-$ID-share-audit-out.args S=$L/claude_microvm-$ID-share-skill.args
  if grep -qx -- "--shared-dir=$TMPDIR/out" $O && ! grep -qx -- --readonly $O; then
    ok "the writable share's virtiofsd exports its host dir, without --readonly"
  else bad "audit-out virtiofsd args:"; cat $O >&2 2>/dev/null || echo "(none)" >&2; fi
  if grep -qx -- "--shared-dir=$TMPDIR/skill" $S && grep -qx -- --readonly $S; then
    ok "the read-only share's virtiofsd runs --readonly"
  else bad "skill virtiofsd args:"; cat $S >&2 2>/dev/null || echo "(none)" >&2; fi
  grep -qx -- "--slice=claude_microvm-$ID.slice" $L/claude_microvm-$ID-share-skill.opts \
    && ok "each share's daemon is in the launch's slice" || bad "share daemon not in the launch's slice"
  for n in audit-out skill; do
    sock=$XDG_RUNTIME_DIR/claude-microvm/vms/$ID/share-$n.sock
    grep -qF "$sock" $L/qemu.sh && grep -qx -- "--socket-path=$sock" $L/claude_microvm-$ID-share-$n.args \
      && ok "QEMU is pointed at share $n's socket in the instance dir" || bad "QEMU not wired to share $n's socket $sock"
  done
  grep -q 'virtiofs-share-' $L/qemu.sh && bad "a share socket was left relative in the QEMU script" || ok "no share socket is left relative in the QEMU script"
  if [ "$(jq -c '[.shares[] | [.name, .guest, .readOnly]]' $J)" = '[["audit-out","/audit-out",false],["skill","/skill",true]]' ] \
     && [ "$(jq -r '.shares[0].host' $J)" = "$TMPDIR/out" ]; then
    ok "instance.json lists the shares: name, host, guest path, read-only"
  else bad "instance.json shares: $(jq -c .shares $J)"; fi
  grep -qF -- "$TMPDIR/out → /audit-out, read-write" $L/out && grep -qF "the guest's writes land on the host" $L/out \
    && grep -qF -- "$TMPDIR/skill → /skill, read-only to the guest" $L/out \
    && ok "the contract lists each share, and says which one the guest can write" \
    || { bad "contract share rows:"; grep -A2 '^  share' $L/out >&2; }
  grep -qx "claude_microvm-$ID-share-audit-out" $L/stopped && grep -qx "claude_microvm-$ID-share-skill" $L/stopped \
    && ok "on exit both share daemons are stopped" || bad "share daemons not stopped: $(cat $L/stopped)"
  [ -z "$(find $XDG_RUNTIME_DIR -name '*.sock*')" ] && ok "and no socket is left" || bad "sockets left: $(find $XDG_RUNTIME_DIR -name '*.sock*')"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
