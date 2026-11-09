# What the guest can reach on the host, pinned on the generated QEMU command
# line of every flavor. The VM boundary is only as narrow as the devices it
# is given, and those come from microvm.nix defaults that can change under a
# lock bump without anyone touching this repo.
#
# The network stays user-mode (slirp, inside the QEMU process): no tap,
# bridge, vhost-net, vhost-vdpa or vhost-vsock, all of which hand
# guest-controlled packets and their offload metadata to the host kernel's
# network stack. vhost-user-fs is expected: virtiofsd is a sandboxed
# userspace daemon, not a kernel driver.
#
# QMP stays a unix socket, once: the launcher moves it into the launch's
# instance directory, and microvm-stop presses the power button through it.
{ pkgs, lib, runners, launcher }:

pkgs.runCommand "host-surface" { } ''
  fail=0
  ok ()  { echo "ok: $1"; }
  bad () { echo "FAIL: $1" >&2; fail=1; }

  ${lib.concatStrings (lib.mapAttrsToList (name: runner: ''
    run=${runner}/bin/microvm-run
    cmd=$(grep -- '-netdev' "$run")

    if [ "$(grep -o -- '-netdev ' <<<"$cmd" | wc -l)" -eq 1 ] \
       && grep -qF -- "-netdev 'user,id=usernet'" <<<"$cmd"; then
      ok "${name}: one netdev, user-mode"
    else
      bad "${name}: expected exactly one -netdev, 'user,id=usernet'"
    fi
    if hits=$(grep -oE -- "-netdev '?(tap|bridge|vhost-user|vhost-vdpa|vde|l2tpv3|socket|stream|dgram|af-xdp|vmnet)[^ ]*|vhost=on|vhost-net|vhost-vdpa|vhost-vsock|vfio" <<<"$cmd"); then
      bad "${name}: a device that reaches the host kernel: $(echo $hits)"
    else
      ok "${name}: no tap/bridge/vhost-net/vdpa/vsock/vfio"
    fi
    if [ "$(grep -o -- '-qmp ' <<<"$cmd" | wc -l)" -eq 1 ] \
       && grep -q -- '-qmp unix:' <<<"$cmd"; then
      ok "${name}: one QMP socket, unix"
    else
      bad "${name}: expected exactly one -qmp, a unix socket the launcher relocates"
    fi
    # The launcher tightens seccomp by rewriting exactly this text.
    if [ "$(grep -o -- '-sandbox on ' <<<"$cmd" | wc -l)" -eq 1 ]; then
      ok "${name}: '-sandbox on ' present once for the launcher to tighten"
    else
      bad "${name}: '-sandbox on ' not found exactly once; the seccomp rewrite would miss"
    fi
  '') runners)}

  if grep -qF -- 's|-sandbox on |-sandbox on,obsolete=deny,resourcecontrol=deny |' ${launcher}/bin/microvm-run; then
    ok "launcher tightens -sandbox"
  else
    bad "launcher no longer tightens -sandbox"
  fi
  # elevateprivileges (=deny or =children) blocks setsid, which libslirp's
  # guestfwd child calls before exec: the inherited filter kills socat and
  # every connection through the sealed netdev is reset. Found on a real
  # launch; nothing else in CI exercises guestfwd.
  if grep -qE -- '-sandbox on[^ |]*elevateprivileges' ${launcher}/bin/microvm-run; then
    bad "launcher sets elevateprivileges: the sealed netdev's socat would be killed"
  else
    ok "no elevateprivileges (guestfwd's child calls setsid)"
  fi

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
