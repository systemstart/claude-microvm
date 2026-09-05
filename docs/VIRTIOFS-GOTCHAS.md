# virtiofs share gotchas in this microVM

`/work` and `/home/agent` come from the host over virtiofs, served by a rootless
`virtiofsd` per share that the launcher starts as a transient `systemd --user`
unit. Symptom first, so an error paste finds the section.

## Everything on the share fails with ENFILE

### Symptom

Every operation on `/work` or `/home/agent` fails with `Too many open files`
(ENFILE) — reads, writes, `git status`, all of it — while `/` and `/nix/store`
are fine. Inside the guest nothing looks wrong: `/proc/sys/fs/file-nr` is low,
no process holds an unusual number of descriptors, and the limits on every
guest process are untouched.

It follows something that walked a lot of files: an unbounded `find`, a test
run over a large module tree, a tool that stats every file in every repository.

### Cause

The exhaustion is on the **host**, not in the guest. virtiofsd keeps one
`O_PATH` file descriptor per inode the guest has looked up, and releases it only
when the guest evicts that dentry and sends a FUSE `FORGET`. A big tree walk
therefore parks hundreds of thousands of descriptors in the daemon, and when it
reaches its `RLIMIT_NOFILE` — 524288 on a typical systemd host — every
subsequent lookup fails.

Two properties make it worse than a normal resource limit:

- **It does not clear on its own.** A guest with free memory has no reason to
  reclaim dentries, so no `FORGET` is ever sent and the descriptors are never
  returned.
- **Retrying deepens it.** Every retry is another lookup. A polling loop that
  "waits for the share to come back" is the one thing guaranteed to keep it
  down.

### Recovery

Stop whatever is walking the share first — including your own retry loop — then:

```sh
vm-share-relieve
```

It drops the guest's dentry and inode caches, which forces the `FORGET` messages
that hand the descriptors back. It needs root and re-execs itself through a
narrow sudo rule, so the agent user can run it directly. The cost is a cold
cache for a moment; the alternative is a VM restart.

Forcing memory pressure by allocating a large block works too, for the same
reason, but it is a blunter version of the same thing.

### Prevention

Guest side, and this is where it belongs:

- Depth-limit `find` and prune the fat directories — `node_modules`, `vendor`,
  language module caches, rendered or vendored trees.
- Prefer explicit path lists over discovery in anything that iterates repos.
- Keep bulk scratch off the share entirely.

## Two host-side "fixes" that do not apply here

Both come up whenever this is discussed. Neither works in this project's
configuration, and both were measured against the pinned virtiofsd (1.14.0)
rather than assumed:

- **`--inode-file-handles=prefer`.** File handles would remove the descriptor
  ceiling outright, which is why it is the obvious fix — but it is already the
  default in 1.14.0, *and* it cannot work here. `open_by_handle_at` requires
  `CAP_DAC_READ_SEARCH` in the initial user namespace, which a rootless daemon
  does not have; virtiofsd says so at startup and silently degrades to
  descriptors:

  ```
  WARN virtiofsd::passthrough] Failed to open file handle for the root node:
       Operation not permitted (os error 1)
  ```

  Getting file handles would mean running virtiofsd as root with
  `--modcaps=+dac_read_search`, trading the containment that makes this
  launcher's shares safe for a resource ceiling. Not worth it.

- **Raising `--rlimit-nofile`.** virtiofsd already targets
  `min(1000000, /proc/sys/fs/nr_open)` and, when that exceeds the hard limit,
  falls back to the hard limit by itself:

  ```
  WARN virtiofsd::limits] Failure when trying to set the limit to 1000000, the
       hard limit (524288) of open file descriptors is used instead.
  ```

  So the launcher passing a value changes nothing at best. At worst it breaks
  startup: an explicit value above the hard limit is a hard error, not a
  fallback, and virtiofsd exits.

  ```
  ERROR virtiofsd] Error increasing number of open files: Failed to increase
        the limit: Os { code: 1, kind: PermissionDenied }
  ```

  Raising the *hard* limit is not available to a `systemd --user` unit beyond
  the user manager's own, so the ceiling is what it is. Bounding demand in the
  guest is the lever that exists.
