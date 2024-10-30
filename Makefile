NETWORK ?= development
AZERO_ENV ?= dev
DOCKER_RELAYER_NAME ?= most-relayer
DOCKER_RELAYER_COPY_ADDRESSES ?= copy
DOCKER_RELAYER_COMPILE_CONTRACTS ?= compile
COMPILE_ETH_CONTRACTS_WHEN_DEPLOYING ?= compile
COMPILE_AZERO_CONTRACTS_WHEN_DEPLOYING ?= compile
COMPILE_ETH_CONTRACTS_WHEN_SETUP ?= compile
COMPILE_AZERO_CONTRACTS_WHEN_SETUP ?= compile
DOCKER_SIGNER_NAME ?= most-signer
L2 ?= false

export CONTRACT_VERSION ?=`git rev-parse HEAD`

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: clean-azero
clean-azero: # Remove azero node data
clean-azero:
	cd devnet-azero && rm -rf \
		5*/chains/a0dnet1/db \
		5*/chains/a0dnet1/network \
		5*/backup-stash \
		5*/chainspec.json
	rm -rf azero/artifacts/*
	echo "Done azero clean"

.PHONY: clean-eth
clean-eth: # Remove eth node data
clean-eth:
	cd devnet-eth && ./clean.sh && echo "Done devnet-eth clean"
	cd eth && npx hardhat clean && rm -r cache && rm -rf .openzeppelin && echo "Done eth clean"

.PHONY: clean
clean: # Remove all node data
clean: stop-local-bridgenet clean-eth clean-azero

.PHONY: full-clean
full-clean: # Remove all build and node data
full-clean: stop-local-bridgenet
	git clean -fdX

.PHONY: bootstrap-azero
bootstrap-azero: # Bootstrap the node data
bootstrap-azero:
	cd devnet-azero && \
	cp azero_chainspec.json 5D34dL5prEUaGNQtPPZ3yN5Y6BnkfXunKXXz6fo7ZJbLwRRH/chainspec.json

.PHONY: devnet-azero
devnet-azero: # Run azero devnet
devnet-azero: bootstrap-azero
	docker compose -f ./devnet-azero/devnet-azero-compose.yml up -d

.PHONY: devnet-azero-logs
devnet-azero-logs: # show azero devnet node logs
devnet-azero-logs:
	docker container logs aleph_bridgenode --follow

.PHONY: devnet-eth
devnet-eth: # Run eth devnet
devnet-eth:
	docker compose -f ./devnet-eth/devnet-eth-compose.yml up -d

.PHONY: devnet-eth-logs
devnet-eth-logs: # show ethereum devnet node logs
devnet-eth-logs:
	docker container logs geth --follow

.PHONY: redis-instance
redis-instance: # Run a redis instance
redis-instance:
	docker compose -f ./relayer/scripts/redis-compose.yml up -d

.PHONY: local-bridgenet
local-bridgenet: # Run both devnets + a redis instance
local-bridgenet: devnet-azero devnet-eth redis-instance

.PHONY: stop-local-bridgenet
stop-local-bridgenet:
stop-local-bridgenet: stop-relayers
	docker compose -f ./devnet-azero/devnet-azero-compose.yml down -v && \
	docker compose -f ./devnet-eth/devnet-eth-compose.yml down -v && \
	docker compose -f ./relayer/scripts/redis-compose.yml down -v

.PHONY: eth-deps
eth-deps: # Install eth dependencies
eth-deps:
	cd eth && npm install

.PHONY: watch-eth
watch-eth: # watcher on the eth contracts
watch-eth: eth-deps
	cd eth && npm run watch

.PHONY: compile-eth
compile-eth: # Compile eth contracts
compile-eth: eth-deps
	cd eth && npx hardhat compile

.PHONY: deploy-eth
deploy-eth: # Deploy eth contracts
ifeq ($(COMPILE_ETH_CONTRACTS_WHEN_DEPLOYING),compile)
deploy-eth: compile-eth
endif
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/0_deploy_bridge_contracts.js

.PHONY: deploy-eth-transfer-limit
deploy-eth-transfer-limit: # Deploy TransferLimit eth contract
ifeq ($(COMPILE_ETH_CONTRACTS_WHEN_DEPLOYING),compile)
deploy-eth-transfer-limit: compile-eth
endif
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/deploy_transfer_limit.js

.PHONY: upload-eth
upload-eth: # Upload the MOST contract to a live ethereum network (testnet or mainnet) for an upgrade
upload-eth: compile-eth
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/upload_bridge.js

.PHONY: deploy-live
deploy-live: # Deploy azero and eth contracts on a live network (testnet or mainnet)
deploy-live: deploy-azero-docker setup-azero-docker deploy-eth setup-eth

.PHONY: verify-eth
verify-eth: # Post verified eth sources of a contract to etherscan
verify-eth:
	cd eth && \
	npx hardhat verify --network $(NETWORK) $(CONTRACT)

.PHONY: setup-eth
setup-eth: # Setup eth contracts
ifeq ($(COMPILE_ETH_CONTRACTS_WHEN_SETUP),compile)
setup-eth: compile-eth
endif
	cd eth && \
	npx hardhat run --network $(NETWORK) scripts/1_setup_bridge_contracts.js

.PHONY: decode-eth
decode-eth: # Decode eth contract call
decode-eth: eth-deps
	cd eth && node scripts/decode.js

.PHONY: most-builder
most-builder: # Build an image in which contracts can be built
most-builder:
	docker build -t most-builder -f docker/most_builder.dockerfile .

.PHONY: compile-azero-docker
compile-azero-docker: # Compile azero contracts in docker
compile-azero-docker: azero-deps most-builder
	docker run --rm --network host \
		--volume "$(shell pwd)":/code \
		--workdir /code \
		--name most-builder \
		most-builder \
		make compile-azero

.PHONY: print-azero-codehashes
print-azero-codehashes: # Print codehashes of azero contracts compiled in docker
print-azero-codehashes: compile-azero-docker
	@echo
	@echo "-------------------"
	@echo "CONTRACT CODEHASHES"
	@echo "-------------------"
	@echo

	@cd azero && for file in artifacts/*.json; do \
		echo "$$file"; \
		cat "$$file" | jq '.source .hash'; \
	done

.PHONY: deploy-azero-docker
deploy-azero-docker: # Deploy azero contracts compiling in docker
ifeq ($(COMPILE_AZERO_CONTRACTS_WHEN_DEPLOYING),compile)
deploy-azero-docker: azero-deps compile-azero-docker typechain-azero
endif
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run deploy

.PHONY: setup-azero-docker
setup-azero-docker: # Setup azero contracts compiling in docker
ifeq ($(COMPILE_AZERO_CONTRACTS_WHEN_SETUP),compile)
setup-azero-docker: azero-deps compile-azero-docker
endif
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run setup

.PHONY: azero-deps
azero-deps: # Install azero dependencies
azero-deps:
	cd azero && npm install

.PHONY: watch-azero
watch-azero: # watch azero contracts and generate artifacts
watch-azero: azero-deps
	cd azero && npm run watch

.PHONY: compile-azero-single-contract
compile-azero-single-contract: # compile azero contract and generate artifacts
compile-azero-single-contract: azero-deps
	cd azero/contracts/$(CONTRACT_DIR) && cargo contract build --release
	cp azero/contracts/$(CONTRACT_DIR)/target/ink/$(CONTRACT_NAME).* azero/artifacts/

.PHONY: compile-azero
compile-azero: # compile azero contracts and generate artifacts
compile-azero: azero-deps
	mkdir -p azero/artifacts
	make compile-azero-single-contract CONTRACT_DIR=advisory CONTRACT_NAME=advisory
	make compile-azero-single-contract CONTRACT_DIR=most CONTRACT_NAME=most
	make compile-azero-single-contract CONTRACT_DIR=most-l2 CONTRACT_NAME=most_l2
	make compile-azero-single-contract CONTRACT_DIR=token CONTRACT_NAME=token
	make compile-azero-single-contract CONTRACT_DIR=gas-price-oracle/contract CONTRACT_NAME=oracle
	cd azero && cp external_artifacts/wrapped_azero.contract artifacts/
	cd azero && cp external_artifacts/wrapped_azero.json artifacts/
	cd azero && cp external_artifacts/wrapped_azero.wasm artifacts/14

.PHONY: typechain-azero
typechain-azero: # Generate typechain typings for azero contracts
typechain-azero:
	cd azero && npm run typechain

.PHONY: deploy-azero
deploy-azero: # Deploy azero contracts
ifeq ($(COMPILE_AZERO_CONTRACTS_WHEN_DEPLOYING),compile)
deploy-azero: compile-azero typechain-azero
endif
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run deploy

.PHONY: upload-azero
upload-azero: # Upload azero contract code without instantiating (useful for upgrades)
upload-azero: compile-azero-docker typechain-azero
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run upload

.PHONY: setup-azero
setup-azero: # Setup azero contracts
ifeq ($(COMPILE_AZERO_CONTRACTS_WHEN_SETUP),compile)
setup-azero: compile-azero typechain-azero
endif
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run setup

.PHONY: deploy
deploy: # Deploy all contracts
deploy: deploy-eth deploy-azero setup-eth setup-azero

.PHONY: deploy-docker
deploy-docker: # Deploy all contracts, use docker compilation for azero
deploy-docker: deploy-eth deploy-azero-docker setup-eth setup-azero-docker

.PHONY: watch-relayer
watch-relayer:
	cd relayer && cargo watch -s 'cargo clippy' -c

.PHONY: watch-relayer-l2
watch-relayer-l2:
	cd relayer && cargo watch -s 'cargo clippy --all-targets --all-features' -c

.PHONY: run-relayer
run-relayer: # Run a single relayer
run-relayer:
	cd relayer && ./scripts/run_relayer.sh

.PHONY: run-relayers
run-relayers: # Run three relayers
run-relayers: build-docker-relayer
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml up -d

.PHONY: stop-relayers
stop-relayers:
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml down -v

.PHONY: bridge
bridge: # Run the bridge
bridge: local-bridgenet deploy run-relayers devnet-relayers-logs

.PHONY: azero-ethereum-transfer
azero-ethereum-transfer: # Request a transfer of 1 unit of wETH from AlephZero to Ethereum
azero-ethereum-transfer:
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run bridge-weth

.PHONY: ethereum-azero-transfer
ethereum-azero-transfer: # Request a transfer of 1 unit of wETH from Ethereum to AlephZero
ethereum-azero-transfer:
	cd eth && npx hardhat run --network $(NETWORK) scripts/bridge_weth.js

.PHONY: devnet-relayers-logs
devnet-relayers-logs: # Show the logs of the devnet relayers
devnet-relayers-logs:
	docker compose -f ./relayer/scripts/devnet-relayers-compose.yml logs -f

.PHONY: test-solidity
test-solidity: # Run solidity tests
test-solidity: eth-deps
	cd eth && npx hardhat test ./test/Most.js ./test/WrappedEther.js ./test/WrappedToken.js ./test/MostL2.js ./test/TransferLimit.js

.PHONY: test-ink
test-ink: # Run ink tests
test-ink: test-ink-unit test-ink-e2e

.PHONY: test-ink-e2e
test-ink-e2e: # Run ink e2e tests
test-ink-e2e: bootstrap-azero
	export CONTRACTS_NODE="../../scripts/azero_contracts_node.sh" && \
	cd azero/contracts/tests && \
	cargo test e2e -- --test-threads=1 --nocapture

.PHONY: test-ink-unit
test-ink-unit: # Run ink unit tests
test-ink-unit:
	cd azero/contracts/most && cargo test
	cd azero/contracts/most-l2 && cargo test
	cd azero/contracts/token && cargo test
	cd azero/contracts/gas-price-oracle/contract && cargo test

.PHONY: test-relayer
test-relayer: # Run relayer tests
test-relayer: compile-azero-docker compile-eth
	cd relayer && cargo test

.PHONY: test-relayer-l2
test-relayer-l2: # Run relayer tests
test-relayer-l2: compile-azero-docker compile-eth
	cd relayer && cargo test --features l2

.PHONY: e2e-test
e2e-test: # Run specific e2e test. Requires: `TEST_CASE=test_module::test_name`.
e2e-test:
	cd e2e-tests && \
		cargo test test::$(TEST_CASE) -- --color always --exact --nocapture --test-threads=1

.PHONY: e2e-tests
e2e-tests: # Run cross-chain transfer e2e tests. All tests must be run without interruption, the order is important. Requires the bridge and both chains to be running locally, e.g. these can be set up by executing `make bridge`.
e2e-tests:
	TEST_CASE=eth_to_azero::weth_to_weth make e2e-test
	TEST_CASE=azero_to_eth::weth_to_weth make e2e-test
	TEST_CASE=eth_to_azero::usdt_to_usdt make e2e-test
	TEST_CASE=azero_to_eth::usdt_to_usdt make e2e-test
	TEST_CASE=azero_to_eth::wazero_to_wazero make e2e-test
	TEST_CASE=eth_to_azero::wazero_to_wazero make e2e-test
	TEST_CASE=eth_to_azero::eth_to_weth make e2e-test
	TEST_CASE=azero_to_eth::weth_to_eth make e2e-test
	TEST_CASE=azero_to_eth::azero_to_wazero make e2e-test
	TEST_CASE=eth_to_azero::wazero_to_azero make e2e-test

.PHONY: drink-tests
drink-tests: # Run drink tests
drink-tests:
	cd azero && npm run drink-tests

.PHONY: check-js-format
check-js-format: # Check js formatting
check-js-format:
	cd eth && npx prettier --check test

.PHONY: solidity-lint
solidity-lint: # Lint solidity contracts
solidity-lint: eth-deps
	cd eth && npx solhint 'contracts/**/*.sol'

.PHONY: relayer-lint
relayer-lint: # Lint relayer
relayer-lint: compile-azero-docker compile-eth
	cd relayer && cargo clippy --all-targets --all-features -- --no-deps -D warnings

.PHONY: ink-lint
ink-lint: # Lint ink contracts
ink-lint:
	cd azero/contracts/most && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/most-l2 && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/token && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/psp22-traits && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/tests && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/gas-price-oracle/contract && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/gas-price-oracle/trait && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions
	cd azero/contracts/ownable2step && cargo clippy -- --no-deps -D warnings -A unexpected-cfgs -A non-local-definitions

.PHONY: contracts-lint
contracts-lint: # Lint contracts
contracts-lint: solidity-lint ink-lint

.PHONY: solidity-format
solidity-format: # Format solidity contracts
solidity-format: eth-deps
	cd eth && npx prettier --write --plugin=prettier-plugin-solidity 'contracts/**/*.sol'

.PHONY: rust-format-check
rust-format-check: # Check rust code formatting
rust-format-check:
	cd relayer && cargo fmt -- --check
	cd azero/contracts/most && cargo fmt -- --check
	cd azero/contracts/most-l2 && cargo fmt -- --check
	cd azero/contracts/token && cargo fmt -- --check
	cd azero/contracts/psp22-traits && cargo fmt -- --check
	cd azero/contracts/tests && cargo fmt -- --check
	cd azero/contracts/gas-price-oracle/contract && cargo fmt -- --check
	cd azero/contracts/gas-price-oracle/trait && cargo fmt -- --check
	cd azero/contracts/ownable2step && cargo fmt -- --check
	cd e2e-tests && cargo fmt -- --check

.PHONY: rust-format
rust-format: # Format rust code
rust-format:
	cd relayer && cargo fmt
	cd azero/contracts/most && cargo fmt
	cd azero/contracts/most-l2 && cargo fmt
	cd azero/contracts/token && cargo fmt
	cd azero/contracts/psp22-traits && cargo fmt
	cd azero/contracts/tests && cargo fmt
	cd azero/contracts/gas-price-oracle/contract && cargo fmt
	cd azero/contracts/gas-price-oracle/trait && cargo fmt
	cd azero/contracts/ownable2step && cargo fmt
	cd e2e-tests && cargo fmt

.PHONY: js-format-check
js-format-check: # Check js formatting
js-format-check:
	cd eth && npx prettier --check test
	cd eth && npx prettier --check scripts
	cd eth && npx prettier --check hardhat.config.js
	cd azero && npx prettier --check scripts

.PHONY: js-format
js-format: # Format js code
js-format:
	cd eth && npx prettier --write test
	cd eth && npx prettier --write scripts
	cd eth && npx prettier --write hardhat.config.js
	cd azero && npx prettier --write scripts

.PHONY: format-check
format-check: # Check code formatting
format-check: rust-format-check js-format-check

.PHONY: format
format: # Format code
format: rust-format js-format solidity-format

.PHONY: build-relayer
build-relayer: # Build relayer
	cd relayer && cargo build --release

.PHONY: build-relayer-l2
build-relayer-l2: # Build relayer with l2 feature
	cd relayer && cargo build --release --features l2


.PHONY: build-docker-relayer
build-docker-relayer: # Build relayer docker image
ifeq ($(DOCKER_RELAYER_COMPILE_CONTRACTS),compile)
build-docker-relayer: compile-azero compile-eth
endif
ifeq ($(L2),true)
build-docker-relayer: build-relayer-l2
else
build-docker-relayer: build-relayer
endif

ifeq ($(DOCKER_RELAYER_COPY_ADDRESSES),copy)
	cp azero/addresses.json relayer/azero_addresses.json
	cp eth/addresses.json relayer/eth_addresses.json
endif
	cp azero/artifacts/most.json relayer/most.json
	cp azero/artifacts/advisory.json relayer/advisory.json
	cd relayer && docker build -t $(DOCKER_RELAYER_NAME) --build-arg COPY_ADDRESSES=$(DOCKER_RELAYER_COPY_ADDRESSES) .
	rm -f relayer/azero_addresses.json relayer/eth_addresses.json  relayer/most.json relayer/advisory.json

contract_spec.json: # Generate a a file describing deployed contracts based on addresses.json files
contract_spec.json: azero/addresses.json eth/addresses.json
	VERSION=${CONTRACT_VERSION} node scripts/contract_spec.js > contract_spec.json

.PHONY: build-docker-signer
build-docker-signer: # Build signer docker image
build-docker-signer:
	cd relayer && cargo build -p signer --release
	cp relayer/target/release/signer relayer/signer_docker
	cd relayer/signer_docker && docker build -t $(DOCKER_SIGNER_NAME) .

.PHONY: get-latest-eth-block
get-latest-eth-block: # Get latest eth block
get-latest-eth-block: eth-deps
	cd eth && npx hardhat run --network $(NETWORK) scripts/get_latest_block.js

.PHONY: get-latest-azero-block
get-latest-azero-block: # Get latest eth block
get-latest-azero-block: azero-deps
	cd azero && AZERO_ENV=$(AZERO_ENV) npm run get-latest-block