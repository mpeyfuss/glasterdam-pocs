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

########################################
# Build
########################################
clean:
	forge fmt && forge clean

build:
	forge build --sizes

clean-build: clean build

########################################
# Test
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