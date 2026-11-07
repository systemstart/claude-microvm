# --impure: required for NIXPKGS_ALLOW_UNFREE env var to take effect
NIX_FLAGS ?= --impure
export NIXPKGS_ALLOW_UNFREE := 1
export AGENTS_ARGS

WORK_DIR ?= $(shell pwd)

.PHONY: claude claude.run gemini gemini.run codex codex.run pi pi.run vms stop release-tag

claude:
	nix build $(NIX_FLAGS) .#claude

claude.run: claude
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run

gemini:
	nix build $(NIX_FLAGS) .#gemini

gemini.run: gemini
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run

codex:
	nix build $(NIX_FLAGS) .#codex

codex.run: codex
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run

pi:
	nix build $(NIX_FLAGS) .#pi

pi.run: pi
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run

# Running launches, of every flavor, and stopping one by its power button
# (scripts/microvm-stop.sh; README "Stopping a VM from outside"):
#   make vms                       list them: ID, start, flavor, terminal, project
#   make stop ID=<id>              power one off; without ID, the only one running
#   make stop ID=<id> FORCE=1      stop QEMU at once, with no shutdown in the guest
vms:
	@nix run $(NIX_FLAGS) .#microvm-stop -- --list

stop:
	@nix run $(NIX_FLAGS) .#microvm-stop -- $(if $(FORCE),--force) $(ID)

# The annotated tag's body becomes the release notes (see .github/workflows/release.yml),
# so it is written here, before the tag is pushed — not patched into the release after.
#   make release-tag                        changelog from Conventional Commit subjects
#   make release-tag EDIT=1                 same, but review it in $EDITOR first
#   make release-tag NOTES=notes.md         takes the body from a file
#   make release-tag MESSAGE="..."          takes the body from the command line
#
# The tag is signed with -s. tag.forcesignannotated does NOT achieve this: git
# gives an explicit --annotate/-a precedence over that config, so `git tag -a`
# produced unsigned tags (v0.13.0 to v0.15.0) however the config was set.
release-tag:
	@set -e; \
	VERSION="$(VERSION)"; \
	[ -n "$$VERSION" ] || VERSION="$$(gsemver bump)"; \
	if [ -n "$(NOTES)" ]; then \
	  BODY="$(NOTES)"; \
	else \
	  BODY="$$(mktemp)"; \
	  trap 'rm -f "$$BODY"' EXIT; \
	  if [ -n "$(MESSAGE)" ]; then \
	    printf '%s\n' "$(MESSAGE)" > "$$BODY"; \
	  else \
	    ./scripts/changelog.sh > "$$BODY"; \
	    [ -z "$(EDIT)" ] || $${EDITOR:-vi} "$$BODY"; \
	  fi; \
	fi; \
	if ! grep -q '[^[:space:]]' "$$BODY" 2>/dev/null; then \
	  echo "error: release notes are empty — tag not created" >&2; exit 1; \
	fi; \
	{ echo "Release v$$VERSION"; echo; cat "$$BODY"; } \
	  | git tag -s "v$$VERSION" --cleanup=verbatim -F -; \
	git push origin "v$$VERSION"
