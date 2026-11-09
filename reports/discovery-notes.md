# EIP-8037 Contract Footgun Discovery Notes

Date: 2026-11-07

The useful mental model is that execution gas is frame-bounded, while the state-gas reservoir is
transaction-wide and is passed to each child in full. `GAS` exposes only the first dimension.

## Confirmed in this repository

| Hypothesis | Status | Evidence |
| --- | --- | --- |
| A fixed-gas untrusted callback can spend more total gas than its allowance | Confirmed | 100k refund callback persists SSTOREs and deploys 24 KiB while state gas comes from the caller's reservoir |
| Code deposit is a strong cost amplifier | Confirmed | 37,784,880 account + code state gas fits inside the callback's ~102,300 execution budget |
| One operation can consume reservoir needed by a later operation | Confirmed | Later 30k-execution-gas fresh SSTORE succeeds with benign callback and fails after adaptive drain |
| `gasleft()` omits sender-paid state gas | Confirmed | Fresh SSTORE reports 12,113 while omitting 97,920 state gas |
| `gasleft()` can increase and checked deltas can revert | Confirmed | Cross-frame clear increases it by 97,164; subtraction panics with `0x11` |
| Behavior depends on caller-selected top-level `tx.gas` | Confirmed | Same checked meter reverts with no reservoir and succeeds with a reservoir |

## Highest-priority next probes

1. **ERC-4337 attribution and solvency.** Run a production EntryPoint with two user operations:
   one creates or clears state and the other consumes state gas. Compare charged `actualGasCost`
   against receipt-level payment and identify who absorbs the mismatch.
2. **Pure new-account spray.** A value-bearing CALL to each fresh address costs 183,600 state gas.
   Measure how many accounts a fixed-execution-gas callback can create and whether the stipend or
   access costs are the binding execution component.
3. **Maximum CREATE amplification.** Sweep runtime sizes and repeated CREATEs under a fixed callback
   gas allowance. The current 24 KiB example is a lower bound, not an optimized maximum.
4. **Production contract search.** Find deployed source using checked `startGas - gasleft()`, gas-
   sensitive branching, try/catch fallbacks with state creation, and per-inner-call reimbursement.
5. **Estimation instability.** Compare `eth_estimateGas` outcomes while varying the candidate
   top-level gas limit, because changing that limit changes reservoir availability and can change
   inner-call success rather than merely adding headroom.
6. **Refill cross-subsidy.** In a multi-user batch, have one operation clear transaction-local
   state created by another. Test whether accounting assigns the refill to the wrong user or lets
   an attacker manipulate fee settlement.

## Triage guidance

The upgrade does not make every gas-sensitive pattern a vulnerability. Prioritize cases where an
untrusted party can choose state growth or clearing and a different party pays, loses liveness, or
receives an incorrect reimbursement. Immutable contracts, shared smart-account batches, relayers,
bridges, and settlement routers are the most consequential search targets.

Primary specification: [EIP-8037](https://eips.ethereum.org/EIPS/eip-8037). The proposal itself
notes both non-monotonic `gas_left` and ERC-4337 attribution as security considerations.
