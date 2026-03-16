# --impure: required for NIXPKGS_ALLOW_UNFREE env var to take effect
NIX_FLAGS ?= --impure
export NIXPKGS_ALLOW_UNFREE := 1

WORK_DIR ?= $(shell pwd)

.PHONY: vm vm.run

vm:
	nix build $(NIX_FLAGS) .#vm

vm.run: vm
	WORK_DIR=$(WORK_DIR) ./result/bin/microvm-run
