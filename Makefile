# --impure: required for NIXPKGS_ALLOW_UNFREE env var to take effect
NIX_FLAGS ?= --impure
export NIXPKGS_ALLOW_UNFREE := 1

WORK_DIR ?= $(shell pwd)

.PHONY: claude claude.run gemini gemini.run codex codex.run release-tag

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

release-tag:
	$(eval VERSION ?= $(shell gsemver bump))
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	git push origin "v$(VERSION)"
