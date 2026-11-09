// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {console} from "forge-std-1.17.0/Test.sol";
import {ReservoirModeTest} from "../utils/ReservoirModeTest.sol";
import {PushPullAuction} from "../../src/reservoir-griefing/PushPullAuction.sol";
import {
    Bidder,
    EventReceiver,
    OverwriteReceiver,
    FreshStateReceiver,
    GreedyDrainer,
    AdaptiveDrainer,
    CodeDepositDrainer
} from "../../src/reservoir-griefing/Receivers.sol";

/// @notice The honest outbidding bidder. Bids, then does one more piece of state
///         growth in the same tx, to observe what reservoir the refund push left behind.
contract NextBidder {
    uint256 internal _afterBid;

    function bidThenGrowState(PushPullAuction auction)
        external
        payable
        returns (uint256 bidRegularGas, uint256 postBidFreshSstoreRegularGas)
    {
        uint256 g = gasleft();
        auction.bid{value: msg.value}();
        bidRegularGas = g - gasleft();

        g = gasleft();
        _afterBid = 1;
        postBidFreshSstoreRegularGas = g - gasleft();
    }
}

/// @notice Scenario: `receiver` is the current highest bidder; `next` outbids it, which
///         requests 100k gas for the refund push, or defers it to a pull. Because the call
///         transfers value, the callee can receive the requested gas plus the 2,300 stipend.
abstract contract AuctionScenarioTest is ReservoirModeTest {
    // Regular gas a fresh SSTORE costs from `gasleft()`'s view, by where its state gas
    // came from. Bounds are loose so small regular-gas retuning doesn't break the PoC.
    uint256 internal constant STATE_GAS_FROM_RESERVOIR_MAX = 20_000; // observed 12,112
    uint256 internal constant STATE_GAS_FROM_REGULAR_MIN = 100_000; // observed 110,032

    uint256 internal constant OPENING_BID = 1 ether;
    uint256 internal constant OUTBID = 2 ether;

    PushPullAuction internal auction;
    NextBidder internal next;
    address payable internal receiver;

    function _deployReceiver() internal virtual returns (address payable);

    function setUp() public {
        auction = new PushPullAuction();
        next = new NextBidder();
        receiver = _deployReceiver();
        Bidder(receiver).placeBid{value: OPENING_BID}(auction);
        _loadReservoirMode();
    }

    /// @return pushed whether the refund was pushed (vs deferred to a pull payment)
    /// @return postBidFresh regular gas the bidder's next fresh SSTORE cost
    function _outbid() internal returns (bool pushed, uint256 postBidFresh) {
        uint256 receiverBalanceBefore = receiver.balance;
        uint256 bidGas;
        (bidGas, postBidFresh) = next.bidThenGrowState{value: OUTBID}(auction);

        uint256 pending = auction.pendingWithdrawals(receiver);
        pushed = pending == 0;
        // exactly one of push / pull happened, for the full amount
        assertEq(pushed ? receiver.balance - receiverBalanceBefore : pending, OPENING_BID, "refund accounting");

        console.log("refund pushed:", pushed);
        console.log("bid() regular gas:", bidGas);
        console.log("bidder's post-bid fresh SSTORE regular gas:", postBidFresh);
    }

    function _assertPullPaymentWorks() internal {
        uint256 before = receiver.balance;
        Bidder(receiver).withdrawFrom(auction);
        assertEq(receiver.balance - before, OPENING_BID, "pull payment");
    }
}

// -----------------------------------------------------------------------------
// Finding 1: under 2^24 (no reservoir), the tested event and existing-slot update
// are pushed successfully. A fresh SSTORE costs about 110k regular gas and cannot
// fit in the roughly 102.3k available to the value-bearing refund call.
// -----------------------------------------------------------------------------

contract EventReceiverTest is AuctionScenarioTest {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new EventReceiver()));
    }

    function test_NoReservoir_PushSucceeds() public inMode(NONE) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }

    function test_SmallReservoir_PushSucceeds() public inMode(SMALL) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }

    function test_LargeReservoir_PushSucceeds() public inMode(LARGE) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }
}

/// @dev "Stores state" splits in two: updating an existing slot has no state gas, so it
///      is pushed fine in every mode. Only *new* state is affected.
contract OverwriteReceiverTest is AuctionScenarioTest {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new OverwriteReceiver()));
    }

    function test_NoReservoir_PushSucceeds() public inMode(NONE) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }

    function test_SmallReservoir_PushSucceeds() public inMode(SMALL) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }

    function test_LargeReservoir_PushSucceeds() public inMode(LARGE) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
    }
}

/// @dev Outcome for a benign state-creating receiver depends on the *outbidder's* tx gas
///      limit, which the receiver doesn't control.
contract FreshStateReceiverTest is AuctionScenarioTest {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new FreshStateReceiver()));
    }

    function test_NoReservoir_PushFails_PullRequired() public inMode(NONE) {
        (bool pushed,) = _outbid();
        assertFalse(pushed);
        _assertPullPaymentWorks();
    }

    function test_SmallReservoir_PushOutcomeDependsOnRemainingReservoir() public inMode(SMALL) {
        (bool pushed,) = _outbid();
        // receipts.push = 2 new slots (length 0->1 and element) ~= 196k state gas, which
        // fits in the 222,784 reservoir.
        assertTrue(pushed);
    }

    function test_LargeReservoir_PushSucceeds() public inMode(LARGE) {
        (bool pushed,) = _outbid();
        assertTrue(pushed);
        assertEq(FreshStateReceiver(receiver).receiptCount(), 1);
    }
}

// -----------------------------------------------------------------------------
// Finding 2: above 2^24, a griefer can spend the outbidder's reservoir.
// -----------------------------------------------------------------------------

/// @dev Writes new slots until regular gas runs low. The requested 100k allowance bounds only
///      regular gas (~12k per new slot), so the receiver can bill several slots of state gas
///      (~98k each) to the outbidder's reservoir and keep the storage.
contract GreedyDrainerTest is AuctionScenarioTest {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new GreedyDrainer()));
    }

    function test_NoReservoir_PushFails_PullRequired() public inMode(NONE) {
        (bool pushed,) = _outbid();
        assertFalse(pushed);
        assertEq(GreedyDrainer(receiver).slotsWritten(), 0);
        _assertPullPaymentWorks();
    }

    /// Reservoir runs out mid-loop -> the next new slot spills ~110k into regular gas ->
    /// OOG -> the push reverts. Reverted state gas is RETURNED to the reservoir, so the
    /// bidder is not hurt beyond the 100k regular gas burned.
    function test_SmallReservoir_PushFails_ReservoirRefunded() public inMode(SMALL) {
        (bool pushed, uint256 postBidFresh) = _outbid();
        assertFalse(pushed);
        assertEq(GreedyDrainer(receiver).slotsWritten(), 0);
        // The pending-withdrawal credit used ~98k of the 222,784 reservoir; the ~125k
        // left still fully covers the bidder's next fresh SSTORE.
        assertLe(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
        _assertPullPaymentWorks();
    }

    function test_LargeReservoir_GrieferStoresStateOnBiddersDime() public inMode(LARGE) {
        (bool pushed, uint256 postBidFresh) = _outbid();
        assertTrue(pushed);
        uint256 slots = GreedyDrainer(receiver).slotsWritten();
        console.log("griefer new slots billed to bidder's reservoir:", slots);
        assertGe(slots, 5);
        assertLe(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
    }
}

/// @dev Drains the reservoir as far as possible WITHOUT reverting (the write that would
///      spill into regular gas fails in a nested call and is refunded). Tests whether a
///      griefer can strip the reservoir and force the bidder's later state growth onto
///      regular gas.
contract AdaptiveDrainerTest is AuctionScenarioTest {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new AdaptiveDrainer()));
    }

    function test_NoReservoir_PushSucceeds_NothingWritten() public inMode(NONE) {
        // Every nested write OOGs and is caught, so receive() returns successfully having
        // written nothing: the push "succeeds" without the receiver storing anything.
        (bool pushed,) = _outbid();
        assertTrue(pushed);
        assertEq(AdaptiveDrainer(receiver).slotsWritten(), 0);
    }

    function test_SmallReservoir_DrainsReservoir_BidderPaysRegularGas() public inMode(SMALL) {
        (bool pushed, uint256 postBidFresh) = _outbid();
        assertTrue(pushed);
        uint256 slots = AdaptiveDrainer(receiver).slotsWritten();
        console.log("griefer new slots billed to bidder's reservoir:", slots);
        assertEq(slots, SMALL_RESERVOIR / 97_920); // 2: as many whole slots as the reservoir holds
        // Reservoir left below one slot's worth: the bidder's own next state growth
        // partially spills into regular gas (observed 83,088 vs 12,112 unspilled).
        assertGt(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
    }

    function test_LargeReservoir_GrieferStoresStateOnBiddersDime() public inMode(LARGE) {
        (bool pushed, uint256 postBidFresh) = _outbid();
        assertTrue(pushed);
        uint256 slots = AdaptiveDrainer(receiver).slotsWritten();
        console.log("griefer new slots billed to bidder's reservoir:", slots);
        assertGe(slots, 5);
        // regular-gas budget, not reservoir, was the binding limit
        assertLe(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
    }
}

/// @dev Code deposit has a much larger state-to-execution gas ratio than SSTORE. A 24 KiB
///      deployment consumes 37,601,280 state gas for code alone while fitting inside the
///      refund callback's roughly 102,300 execution-gas budget.
contract CodeDepositDrainerTest is AuctionScenarioTest {
    uint256 internal constant RUNTIME_SIZE = 24_576;

    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new CodeDepositDrainer()));
    }

    function test_NoReservoir_DeploymentOOGs_PullRequired() public inMode(NONE) {
        (bool pushed,) = _outbid();

        assertFalse(pushed);
        assertEq(CodeDepositDrainer(receiver).deployed(), address(1));
        _assertPullPaymentWorks();
    }

    function test_SmallReservoir_DeploymentOOGs_ReservoirRefunded() public inMode(SMALL) {
        (bool pushed, uint256 postBidFresh) = _outbid();

        assertFalse(pushed);
        assertEq(CodeDepositDrainer(receiver).deployed(), address(1));
        assertLe(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
        _assertPullPaymentWorks();
    }

    function test_LargeReservoir_Deploys24KiBOnBiddersDime() public inMode(LARGE) {
        (bool pushed, uint256 postBidFresh) = _outbid();
        address deployed = CodeDepositDrainer(receiver).deployed();

        console.log("deployed runtime bytes billed to bidder's reservoir:", deployed.code.length);
        console.log("code-deposit state gas:", RUNTIME_SIZE * 1_530);

        assertTrue(pushed);
        assertEq(deployed.code.length, RUNTIME_SIZE);
        assertLe(postBidFresh, STATE_GAS_FROM_RESERVOIR_MAX);
    }
}
