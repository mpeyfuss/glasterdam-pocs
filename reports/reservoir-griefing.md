# Reservoir Griefing in Optimistic Auction Refunds

Date: 2026-11-07

## Executive summary

An auction that attempts an ETH refund with `call{gas: 100_000}` and falls back to a pull
payment still prevents a malicious refund receiver from unconditionally blocking an outbid.
An OOG or revert in the receiver is contained by the low-level call, and the auction credits a
pending withdrawal instead.

EIP-8037 weakens a separate property: the call's execution-gas allowance no longer bounds the
receiver's total cost to the transaction sender. When the top-level transaction gas limit is
above the EIP-7825 execution cap of `2^24`, the excess becomes a transaction-wide state-gas
reservoir. A refund receiver can create persistent state using that reservoir while consuming
only the execution component from its capped call.

The demonstrated impact is conditional economic griefing, not an unconditional auction denial
of service. It is most relevant when an auction call is made inside a high-gas smart-account,
relayer, or batch transaction. Ordinary direct bids are normally far below `2^24` and therefore
have no reservoir.

## System under review

The PoC models an English auction with these refund semantics:

1. Update the highest bidder and bid.
2. Push the previous bid to the former highest bidder using a requested 100,000 gas allowance.
3. If the push fails, credit the former bidder in `pendingWithdrawals`.

The auction uses checks-effects-interactions ordering for its bid state, catches failure from the
refund call, and uses a separate withdrawal function. The receiver remains untrusted and can
execute arbitrary code within the gas available to its call frame. The PoC performs the refund
with an assembly `CALL` whose output buffer has zero length, so attacker-controlled return data is
not copied into the auction's memory. This isolates reservoir behavior from the separate return-
bomb risk of copying unbounded return data after a low-level call.

## Gas model

EIP-8037 separates transaction gas into execution gas and state gas. Execution gas is capped at
`2^24` by EIP-7825. For a transaction above that cap, the excess is placed in a shared state-gas
reservoir. State-creation charges draw from the reservoir first and spill into execution gas when
the reservoir is exhausted.

The reservoir is passed in full to child call frames. The 63/64 forwarding rule and Solidity's
`call{gas: X}` option limit execution gas, not the shared reservoir. The `GAS` opcode, exposed as
`gasleft()`, also reports only execution gas. See the
[EIP-8037 transaction accounting specification](https://eips.ethereum.org/EIPS/eip-8037#transaction-level-gas-accounting-reservoir-model).

The value-bearing refund call requests 100,000 gas. In the tested Foundry implementation, a
fully consumed call receives 102,300 execution gas because the EVM adds the 2,300 gas call
stipend.

## Results

The tests use three top-level transaction gas limits:

| Mode | Transaction gas limit | State-gas reservoir |
| --- | ---: | ---: |
| None | 16,777,216 | 0 |
| Small | 17,000,000 | 222,784 |
| Large | 1,073,741,824 | approximately 1.06 billion |

Observed receiver behavior:

| Receiver | No reservoir | Small reservoir | Large reservoir |
| --- | --- | --- | --- |
| Emit one event | Push succeeds | Push succeeds | Push succeeds |
| Update one existing nonzero slot | Push succeeds | Push succeeds | Push succeeds |
| Create two fresh slots | Push fails; pull credited | Push succeeds | Push succeeds |
| Greedily create fresh slots | Push fails and writes roll back | Push fails and reservoir is restored | Push succeeds with seven persistent slots |
| Adaptively create fresh slots | Push succeeds with no new slots | Push succeeds with two slots and depletes the small reservoir | Push succeeds with five slots |

A fresh storage write measured approximately 12,112 execution gas plus 97,920 state gas. With no
reservoir, the combined approximately 110,032 gas cannot fit in the refund call. With a reservoir,
the execution component fits and the state component is paid by the outbidder's transaction.

The adaptive receiver also changed the outbidder's next fresh storage write from approximately
12,112 execution gas to 83,088 execution gas by depleting the small reservoir. The write still
succeeded; the current PoC demonstrates gas displacement, not a complete transaction OOG.

## Security assessment

### Auction liveness is preserved

A malicious receiver cannot block an outbid solely by reverting or exhausting the refund call.
The low-level call returns `false`, and the auction records a pull payment. State-gas consumed by
a reverted child frame is restored with the frame rollback under EIP-8037.

The fallback path can still OOG if the transaction does not leave enough execution gas after the
failed refund call. In the no-reservoir test, the failed-push bid path consumed approximately
263,000 regular gas. This is the existing risk of underprovisioning a transaction for both the
capped external call and its fallback bookkeeping; it is not introduced by the reservoir.

With unchanged state, a correct `eth_estimateGas` simulation using the submitted gas limit should
include this path. Fixed gas limits, stale estimates, state changes between estimation and
inclusion, and relayers that budget only for the successful push can still cause the full bid to
revert.

### The callback cost bound is weakened

In a reservoir-bearing transaction, the requested 100,000 gas allowance bounds execution but not
total sender-paid gas. The SSTORE receivers persisted roughly 0.5 to 0.8 million state gas in the
large-reservoir tests. This cost is borne by the outbidder even though the created state belongs
to the refund receiver.

The SSTORE result proves that economic griefing is possible but does not establish a worst-case
upper bound. EIP-8037 also moves new-account and code-deposit costs into the state-gas dimension.
Contract creation and code deposit may have a higher state-gas-to-execution-gas ratio and require
separate measurement before the maximum exposure can be stated.

### Full transaction reversion is conditional

Reservoir depletion can make later state creation spill into execution gas. A complete transaction
can OOG if it performs state creation after the refund and has insufficient execution gas for that
spill. This condition is plausible in a near-limit batch or smart-account transaction, but it is
not demonstrated by the current direct-auction tests.

The auction's own successful-push path performs no fresh state creation after the external call;
it only emits an event. A direct EOA bid therefore has no demonstrated reservoir-induced OOG path
after a successful refund. Whenever `tx.gas` is above `2^24`, the transaction also starts with the
maximum EIP-7825 execution budget, leaving substantial margin for a normal standalone bid.

### Smart accounts and batches have higher exposure

Smart-account and relayer transactions can naturally carry a reservoir because many operations
share one top-level transaction. One refund receiver can consume reservoir needed by later calls.
EIP-8037 explicitly notes that `gasleft()` cannot attribute state-gas usage within ERC-4337
bundles, so per-operation accounting based only on execution-gas deltas is insufficient.

## Risk characterization

| Context | Liveness risk | Economic griefing risk |
| --- | --- | --- |
| Direct bid with a current, correct estimate | Low | Low; normally no reservoir |
| Direct bid with a fixed or stale gas limit | Conditional OOG in fallback | Existing capped-call griefing |
| High-gas smart-account or relayer transaction | Conditional downstream OOG | Elevated |
| Large batch with later state creation | Conditional downstream OOG | Elevated |

This behavior does not restore the classic auction vulnerability in which a receiver rejects ETH
and permanently prevents all later bids. It changes the price and gas-composition risk of calling
an untrusted refund receiver.

## Scope and limitations

The results were reproduced with Foundry 1.9.0 and Solidity 0.8.37 using the Amsterdam EVM target.
The test suite contains workarounds for known Foundry behavior that can clear the reservoir after
a cheatcode call. EIP-8037 was in Last Call rather than Final status at the time of review, so gas
constants and client behavior should be revalidated against the finalized fork implementation.

The PoC covers event emission, an existing-slot update, fresh SSTOREs, revert rollback, and
adaptive reservoir depletion. It does not yet measure contract creation, code deposit, account
creation, ERC-4337 integration, or a full top-level transaction OOG caused by downstream state
creation.
