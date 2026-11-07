# include .env file and export its env vars
# (-include to ignore error if it does not exist)
-include .env

########################################
# Dependencies
########################################
remove:
	rm -rf dependencies && rm soldeer.lock

install:
	forge soldeer install

update: remove install

########################################
# Format & Lint
########################################
fmt:
	forge fmt

fmt-check:
	forge fmt --check

########################################
# Build
########################################
clean:
	forge fmt && forge clean

build:
	forge build --sizes

clean-build: clean build

########################################
# Test (all run on the Amsterdam/Glamsterdam EVM)
########################################
test-quick: build
	forge test --fuzz-runs 256

test-std: build
	forge test

test-gas: build
	forge test --gas-report

test-cov: build
	forge coverage --no-match-coverage "(script|test)"

test-fuzz: build
	forge test --fuzz-runs 10000

# Run a single PoC: make poc POC=my-poc
poc:
	@test -n "$(POC)" || (echo "usage: make poc POC=<name>" && exit 1)
	forge test --match-path "test/$(POC)/*" -vvv

# Run under each EIP-8037 reservoir size (tx gas limit is a per-run forge setting).
# Optionally scope to one PoC: make reservoir-modes POC=reservoir-griefing
reservoir-modes:
	RESERVOIR_MODE=none  FOUNDRY_GAS_LIMIT=16777216   forge test $(if $(POC),--match-path "test/$(POC)/*" -vv,)
	RESERVOIR_MODE=small FOUNDRY_GAS_LIMIT=17000000   forge test $(if $(POC),--match-path "test/$(POC)/*" -vv,)
	RESERVOIR_MODE=large FOUNDRY_GAS_LIMIT=1073741824 forge test $(if $(POC),--match-path "test/$(POC)/*" -vv,)

# Same tests on the pre-fork (Osaka) EVM, to diff behavior against Glamsterdam.
# Amsterdam-specific assertions are expected to fail here; read the logs.
# Optionally scope to one PoC: make test-baseline POC=my-poc
test-baseline:
	FOUNDRY_PROFILE=osaka forge test --no-match-contract ForkSanityTest \
		$(if $(POC),--match-path "test/$(POC)/*" -vvv,)

########################################
# Local node
########################################
anvil:
	anvil --hardfork amsterdam --enable-tx-gas-limit

.PHONY: remove install update fmt fmt-check clean build clean-build \
	test-quick test-std test-gas test-cov test-fuzz poc reservoir-modes test-baseline anvil
