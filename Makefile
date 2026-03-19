# --impure: required for NIXPKGS_ALLOW_UNFREE env var to take effect
NIX_FLAGS ?= --impure
export NIXPKGS_ALLOW_UNFREE := 1

WORK_DIR ?= $(shell pwd)

.PHONY: vm vm.run tag

vm:
	nix build $(NIX_FLAGS) .#vm

vm.run: vm
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run

tag:
	$(eval VERSION ?= $(shell gsemver bump))
	git tag -a "v$(VERSION)" -m "Release v$(VERSION)"
	git push origin "v$(VERSION)"
