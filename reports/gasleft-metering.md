# Non-monotonic and Incomplete `gasleft()` Metering

Date: 2026-11-07

## Executive summary

EIP-8037 breaks two assumptions behind application-level gas accounting:

1. `gasleft()` no longer exposes every unit of gas paid by the transaction sender. It returns
   execution gas and excludes the transaction-wide state-gas reservoir.
2. `gasleft()` is no longer monotonic. When temporary state growth is undone, a state-gas refill
   can make a frame hold more execution gas after a subcall than it held before the subcall.

Consequently, a checked `startGas - gasleft()` meter is neither safe nor complete. It can panic
when no reservoir exists and undercharge when a reservoir pays for persistent state growth. The
same contract call can therefore revert or succeed based only on the top-level transaction gas
limit and its resulting reservoir.

## PoC design

`GasleftMetering.checkedMeterAcrossCall()` performs this sequence:

1. Create a temporary storage slot. With no reservoir, its 97,920 state gas spills into the
   current frame's execution gas and is tracked as state-gas debt.
2. Record `startGas = gasleft()`.
3. Call back into the same contract. The child frame clears the temporary slot.
4. On the child-to-parent merge, the refill repays the parent's state-gas debt.
5. Compute `startGas - gasleft()` using Solidity's default checked arithmetic.

The refill is larger than the execution cost of the call and clear, so step 5 underflows.

The persistent-growth case wraps a fresh SSTORE with the same `gasleft()` delta while a reservoir
is present. The sender pays both dimensions, but the contract observes only execution gas.

## Observed results

The tests ran on Foundry 1.9.0 / revm with the Amsterdam EVM target:

| Case | Result |
| --- | --- |
| No reservoir, raw observation | `gasleft()` increased by 97,164 |
| No reservoir, checked subtraction | reverted with Solidity panic `0x11` |
| Small or large reservoir, same checked meter | succeeded and reported 756 gas |
| Reservoir, persistent fresh SSTORE | reported 12,113 gas and omitted 97,920 state gas |

The unchecked form wraps the negative delta to a value near `type(uint256).max`, so replacing the
checked subtraction with `unchecked` avoids the revert but can create catastrophic overcharging,
overflow in later arithmetic, or nonsensical accounting.

## Impact

Affected patterns include:

- relayer or smart-account reimbursement based on `startGas - gasleft()`;
- batch executors that enforce per-operation gas limits or charge users from observed deltas;
- fee settlement that assumes the sum of inner `gasleft()` deltas equals transaction gas paid;
- instrumentation and invariant checks that assume `gasleft()` only decreases.

The reservoir-present failure mode is especially important for ERC-4337-style bundles. Every user
operation shares the top-level reservoir, but `GAS` cannot identify which operation consumed or
refilled state gas. EIP-8037 explicitly calls out this attribution problem in its security
considerations.

## Mitigation direction

There is no EVM opcode in the current proposal that exposes a frame-local state-gas balance or
total multidimensional consumption. Contracts should not use a `gasleft()` delta as an exact
sender-cost measurement under EIP-8037.

Short-term defenses are application-specific:

- treat `gasleft()` only as execution-gas telemetry, never total cost;
- avoid checked subtraction across code that can undo transaction-local state growth;
- do not “fix” the panic with unchecked arithmetic without explicitly handling `endGas > startGas`;
- price state-creating actions explicitly from known operation semantics, or settle them outside
  contract execution from receipt/client data;
- isolate mutually untrusted operations into separate top-level transactions when exact cost
  attribution is a security or solvency requirement.

None of these recovers exact generic per-call state-gas attribution for already-deployed code.

## Scope

The PoC demonstrates an SSTORE refill within one contract across an external self-call and a
persistent fresh SSTORE funded by the reservoir. It does not yet integrate a production EntryPoint,
test state-gas cross-subsidies between distinct user operations, or survey deployed contracts for
checked `gasleft()` subtraction.

Specification reference: [EIP-8037](https://eips.ethereum.org/EIPS/eip-8037), especially the
transaction accounting, `gas_left can increase`, and ERC-4337 sections.
