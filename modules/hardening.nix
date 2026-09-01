{ pkgs, lib, config, ... }:
let
  # tc classifiers and actions, blocked from on-demand autoload below.
  #
  # Only modules that still exist upstream are listed. cls_tcindex and cls_rsvp
  # were retired from the kernel (6.3 and later), so entries for them would be
  # inert. cls_route survived that cull — it is still built and still modular
  # (verified against /run/booted-system/kernel-modules/…/net/sched on 6.18.45),
  # so it belongs on the list.
  #
  # em_* (ematch) and act_meta_* are deliberately absent, but not because
  # entries would be inert: both are alias-loaded (ematch-kind-N, ife-meta-*)
  # and modprobe applies `install` after alias resolution, so listing them would
  # take effect. They are omitted because they are only reachable through
  # cls_basic / cls_flow and act_ife, which are blocked here already. If any of
  # those ever comes off the list, add the matching em_* / act_meta_*
  # entries.
  blockedTcFilters = [
    "cls_u32"
    "cls_fw"
    "cls_basic"
    "cls_flow"
    "cls_cgroup"
    "cls_flower"
    "cls_matchall"
    "cls_bpf"
    "cls_route"
    "act_pedit"
    "act_mirred"
    "act_police"
    "act_gact"
    "act_bpf"
    "act_connmark"
    "act_csum"
    "act_ct"
    "act_ctinfo"
    "act_ife"
    "act_mpls"
    "act_nat"
    "act_sample"
    "act_simple"
    "act_skbedit"
    "act_skbmod"
    "act_tunnel_key"
    "act_vlan"
    "act_gate"
  ];

  # Queueing disciplines, same treatment. Blocking the filters while leaving
  # every sch_* faultable would leave the larger half of net/sched open, and the
  # qdisc side has been at least as productive for local privilege escalation
  # as the action side — sch_qfq alone accounts for CVE-2023-4921 and
  # CVE-2023-31436.
  #
  # Only the exotic ones are listed. These are deliberately left loadable
  # because they are actually used:
  #
  #   sch_tbf               — the CNI `bandwidth` plugin's ingressRate path
  #   sch_ingress           — also provides clsact, which container networking
  #                           and any tc-BPF attachment needs; the stronger
  #                           reason it must stay loadable
  #   sch_fq_codel          — net.core.default_qdisc, loaded on every boot and
  #                           the only sched module live on a default guest
  #
  # All of them were present and modular on 6.18.45; none is reachable in
  # normal use of this VM.
  blockedTcQdiscs = [
    "sch_qfq"
    "sch_choke"
    "sch_teql"
    "sch_dualpi2"
    "sch_cbs"
    "sch_taprio"
    "sch_etf"
    "sch_plug"
    "sch_skbprio"
  ];

  blockedTcModules = blockedTcFilters ++ blockedTcQdiscs;
in
{
  options.claude-vm.hardening = {
    blockedKernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = blockedTcModules;
      description = ''
        Kernel modules whose on-demand autoload is refused, via an
        `install <mod> false` line in modprobe.d. This option is the authority:
        `boot.extraModprobeConfig` is generated from it, so overriding it here
        changes what is actually blocked.
      '';
    };

    requiredKernelModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "sch_tbf" "sch_ingress" "sch_fq_codel" ];
      description = ''
        The keep-list: net/sched modules that must stay loadable because
        something real needs them. sch_tbf and sch_ingress are required by the
        CNI `bandwidth` plugin; sch_fq_codel is loaded on every boot via
        net.core.default_qdisc. Listed so the contract is asserted by
        checks.module-hardening rather than only stated in a comment.
      '';
    };

    knownUnblockableModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "act_mpls" ];
      description = ''
        Modules on the blocked list whose `install` rule kmod ignores, so they
        remain loadable despite being listed. Tracked explicitly rather than
        quietly dropped from `blockedKernelModules`: the rule is inert but
        harmless, and becomes effective the moment the cause goes away.

        The cause is a kmod behaviour, not a mistake in the list: a module that
        carries a `softdep` never has its `install` command applied. `act_mpls`
        declares `softdep act_mpls post: mpls_gso` in its own modinfo, which
        depmod writes into modules.softdep. Reproduce on any 6.18 guest:

        ```
        $ modprobe --show-depends act_mpls        # install rule ignored
        insmod .../act_mpls.ko.xz
        insmod .../mpls_gso.ko.xz
        ```

        and confirm it is the softdep and not the module by inventing one for a
        module that *is* blocked — it then loads:

        ```
        $ printf 'install sch_qfq /bin/false\nsoftdep sch_qfq post: mpls_gso\n' > c/t.conf
        $ modprobe -C c --show-depends sch_qfq
        insmod .../sch_qfq.ko.xz
        ```

        There is no config-level fix. modprobe.d `softdep` lines *append* to
        modules.softdep rather than override it, so the kernel-supplied softdep
        cannot be cleared; `blacklist` does not help either, because act_api.c
        asks by literal name via request_module("act_%s") and blacklist only
        suppresses alias-based loads. Removing it would need a kernel rebuild
        with CONFIG_NET_ACT_MPLS off, which costs the binary cache.

        checks.module-hardening asserts this list escapes *and* that nothing
        else does, so a future kernel adding a softdep to another blocked module
        fails CI instead of silently widening the hole.
      '';
    };
  };

  config = {
    # Block on-demand autoload of tc classifiers, actions and the exotic
    # queueing disciplines.
    #
    # Unprivileged user namespaces stay enabled (see the hardening notes in the
    # README), so an unprivileged guest user holds namespaced CAP_NET_ADMIN and
    # can reach net/sched. Loading is what makes that reach useful: the kernel
    # pulls these in on first use via request_module(), so a guest that never
    # legitimately touches tc can still fault in a classifier or action and
    # attack it. Refusing the load closes the route as a category rather than
    # one CVE at a time.
    #
    # `install <mod> false` rather than boot.blacklistedKernelModules: the
    # latter emits nothing but `blacklist <name>` lines, which suppress
    # alias-based loading but not a request by real name. cls_api.c and
    # act_api.c ask through request_module("cls_%s") / ("act_%s") with the
    # literal name, which a blacklist line does not stop. Please don't
    # "simplify" this back.
    #
    # The command must be an absolute store path, not /bin/false: modprobe runs
    # it through /bin/sh -c, and the guest's /bin holds exactly one entry (sh).
    # /bin/false would exit 127 "command not found" -- the load is still refused,
    # but by accident rather than by design, and it logs a misleading error on
    # every attempt.
    #
    # Nothing in the default CNI chain (bridge + portmap + firewall) uses tc,
    # so this is inert for ENABLE_CRI as shipped. It is compatible with
    # container runtimes in a way security.lockKernelModules is not, since that
    # sets kernel.modules_disabled=1 and blocks the on-demand loads CNI does
    # need.
    #
    # If you add the `bandwidth` plugin to the chain, drop act_mirred and
    # cls_u32 from the list: its egressRate path attaches a u32 filter carrying
    # a mirred TCA_EGRESS_REDIR action to redirect into an ifb device (see
    # CreateEgressQdisc in plugins/meta/bandwidth/ifb_creator.go upstream). Its
    # ingressRate path only needs sch_tbf and is unaffected.
    boot.extraModprobeConfig =
      lib.concatMapStrings (m: "install ${m} ${pkgs.coreutils}/bin/false\n")
        config.claude-vm.hardening.blockedKernelModules;
  };
}
