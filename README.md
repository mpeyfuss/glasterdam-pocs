# Glamsterdam PoCs

Proof-of-concepts exercising the Glamsterdam upgrade (Gloas consensus + Amsterdam execution).
Built on Foundry. Every test runs on an EVM executing Amsterdam rules by default.

## Setup

Requires Foundry v1.9.0+ (Amsterdam support in forge/anvil) and solc 0.8.35+ (`amsterdam` EVM target).

```shell
make install          # soldeer dependencies
make test-std         # default (large reservoir) mode
make reservoir-modes  # every reservoir mode (see below)
```

`foundry.toml` sets `evm_version = "amsterdam"` and `experimental = true`. solc still marks the
`amsterdam` target as experimental, so it refuses to compile it without that flag.

## Layout

One directory per PoC:

```
src/<poc-name>/            # contracts under test
test/<poc-name>/*.t.sol    # tests demonstrating the behavior
test/utils/                # shared test bases (ReservoirModeTest)
```

## Commands

| Command | What it does |
| --- | --- |
| `make poc POC=<name>` | Run one PoC's tests (`-vvv`), default mode |
| `make reservoir-modes [POC=<name>]` | Run under each reservoir size: none / small / large |
| `make test-baseline [POC=<name>]` | Run on Osaka (pre-fork) to compare; Amsterdam assertions will fail, so read the logs |
| `make test-std` / `test-quick` / `test-fuzz` | Full suite at default / 256 / 10k fuzz runs |
| `make anvil` | Local node with `--hardfork amsterdam --enable-tx-gas-limit` |
| `make fmt` / `fmt-check` | Format / check formatting |

## Gas model (EIP-8037)

Amsterdam splits gas into **regular (execution) gas** and **state gas**. Regular gas is capped at
2^24 by EIP-7825. Any gas in the transaction's limit above that cap becomes the **state gas
reservoir**. State growth (new storage slots, new accounts, code deposit) is paid from the
reservoir first. When the reservoir runs out, the rest **spills into regular gas**.

| | `gasleft()` cost, fresh SSTORE 0→1 | overwrite 1→2 |
| --- | --- | --- |
| osaka | 22,112 | 5,013 |
| amsterdam, tx gas limit ≤ 2^24 (no reservoir) | 110,032 | 12,113 |
| amsterdam, reservoir covers it | 12,112 | 12,113 |

What we've observed (forge 1.9.0 / revm):
- `gasleft()` only shows regular gas.
- A call's gas limit (`call{gas: X}`) only bounds the callee's *regular* gas. The callee draws
  state gas from the shared tx-wide reservoir.
- A value-bearing `call{gas: 100_000}` was observed with a maximum callee budget of 102,300
  regular gas because the EVM adds the 2,300 gas call stipend.
- State gas spent inside a reverted call frame is returned to the reservoir.

### Reservoir modes

The reservoir size equals the tx gas limit minus 2^24. forge sets the tx gas limit per run, so a
mode is chosen per invocation (`RESERVOIR_MODE` + `FOUNDRY_GAS_LIMIT`). Tests inherit
`test/utils/ReservoirModeTest.sol` and tag each test with `inMode(NONE|SMALL|LARGE)`; tests for
other modes show as skipped.

| mode | tx gas limit | reservoir |
| --- | --- | --- |
| none | 2^24 | 0 |
| small | 17,000,000 | 222,784 (~2 new slots) |
| large (default) | 2^30 | ~1.06B |

## ⚠️ forge 1.9.0 caveats (these silently invalidate reservoir tests)

1. **The EIP-7825 cap is off by default** in forge and anvil, and without it there's no
   reservoir at all. This repo enables it (`enable_tx_gas_limit = true`).
2. **Any cheatcode call wipes the remaining reservoir** for the rest of that transaction, so
   all later state gas is billed to regular gas. Even `vm.label` does it. Forge's reported test
   gas is also inflated by the full reservoir size. `setUp` and each test body are separate
   transactions, so:
   - keep `vm.*` out of test bodies until after the last measurement;
   - in `setUp`, call cheatcodes **last** (`_loadReservoirMode()` must be the last statement);
   - test contracts already hold plenty of ETH, so you don't need `vm.deal`.
3. **`dynamic_test_linking` turns `new X()` in tests into the `vm.deployCode` cheatcode**,
   which triggers (2). It's disabled in `foundry.toml`.
4. **A test body is one transaction for reservoir purposes** (even with `isolate`). State
   created earlier in the body has already used reservoir, so set up prerequisites in `setUp`.
5. `setUp` runs under the mode's gas limit too. In `none` mode, keep its deploys within 2^24
   (each deploy costs ~1-2M of state gas).

`ForkSanityTest` fails if the fork or the reservoir model is wrong for the current mode.

## PoCs

### `reservoir-griefing`

An auction refunds the outbid bidder with an optimistic push (`call{gas: 100_000}`) and falls
back to a pull payment if the push fails. The next bidder outbids, then creates one more storage
slot in the same transaction.

| previous bidder (refund receiver) | none | small | large |
| --- | --- | --- | --- |
| `EventReceiver`: emits event | push ✅ | push ✅ | push ✅ |
| `OverwriteReceiver`: updates existing slot | push ✅ | push ✅ | push ✅ |
| `FreshStateReceiver`: creates 2 slots | pull (first fresh write OOGs) | push ✅, bidder's next slot spills (83k) | push ✅ |
| `GreedyDrainer`: creates slots until out of gas | pull | pull (reservoir refunded) | push ✅, **7 junk slots billed to bidder** |
| `AdaptiveDrainer`: creates slots while they fit in the reservoir | push ✅, 0 slots | push ✅, **2 slots, reservoir drained, bidder's next slot spills (83k)** | push ✅, **5 junk slots billed to bidder** |

The full analysis is in [Reservoir griefing in optimistic auction refunds](reports/reservoir-griefing.md).

Takeaways:
- With no reservoir, a fresh SSTORE cannot fit in the refund call and the auction defers the
  refund. Updating one existing slot or emitting the tested event succeeds.
- Whether the push succeeds depends on the **outbidder's tx gas limit**, which the receiver
  doesn't control.
- With a reservoir, the requested 100k call limit no longer bounds the receiver's total cost to
  the payer. The SSTORE PoC bills roughly 0.5–0.8M state gas to the payer, but it is not a
  worst-case upper bound.
- A receiver can drain the reservoir *without reverting* (`AdaptiveDrainer`), so the payer's own
  later state growth spills into regular gas.
- The push-to-pull fallback still preserves auction liveness when the transaction has enough gas.
  The demonstrated reservoir impact is economic griefing and downstream gas displacement, not
  an unconditional ability to block an outbid.
