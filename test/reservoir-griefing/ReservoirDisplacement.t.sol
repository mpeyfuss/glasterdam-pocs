// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ReservoirModeTest} from "../utils/ReservoirModeTest.sol";
import {PushPullAuction} from "../../src/reservoir-griefing/PushPullAuction.sol";
import {Bidder, EventReceiver, AdaptiveDrainer} from "../../src/reservoir-griefing/Receivers.sol";

/// @notice A later operation in the same batch that needs to create state.
contract DownstreamStateGrowth {
    uint256 public value;

    function grow() external {
        value = 1;
    }
}

/// @notice Models a smart account or batch that separately budgets execution gas for each action.
contract CappedBatchBidder {
    function bidThenGrow(PushPullAuction auction, DownstreamStateGrowth downstream, uint256 downstreamExecutionGas)
        external
        payable
        returns (bool downstreamSucceeded)
    {
        auction.bid{value: msg.value}();
        (downstreamSucceeded,) =
            address(downstream).call{gas: downstreamExecutionGas}(abi.encodeCall(downstream.grow, ()));
    }
}

abstract contract ReservoirDisplacementScenario is ReservoirModeTest {
    uint256 internal constant OPENING_BID = 1 ether;
    uint256 internal constant OUTBID = 2 ether;
    uint256 internal constant DOWNSTREAM_EXECUTION_GAS = 30_000;

    PushPullAuction internal auction;
    CappedBatchBidder internal batch;
    DownstreamStateGrowth internal downstream;
    address payable internal receiver;

    function _deployReceiver() internal virtual returns (address payable);

    function setUp() public {
        // These tests only target the deliberately small reservoir. Reading the mode first
        // avoids deploying this extra scenario under the no-reservoir setup gas ceiling.
        // setUp and the test body are separate transactions, so this cheatcode does not
        // disturb the reservoir used by the actual test.
        _loadReservoirMode();
        if (_mode != SMALL) return;

        auction = new PushPullAuction();
        batch = new CappedBatchBidder();
        downstream = new DownstreamStateGrowth();
        receiver = _deployReceiver();
        Bidder(receiver).placeBid{value: OPENING_BID}(auction);
    }

    function _runBatch() internal returns (bool downstreamSucceeded) {
        downstreamSucceeded = batch.bidThenGrow{value: OUTBID}(auction, downstream, DOWNSTREAM_EXECUTION_GAS);
    }
}

contract IntactReservoirTest is ReservoirDisplacementScenario {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new EventReceiver()));
    }

    function test_SmallReservoir_CappedDownstreamStateGrowthSucceeds() public inMode(SMALL) {
        bool downstreamSucceeded = _runBatch();

        assertTrue(downstreamSucceeded, "intact reservoir pays the later call's state gas");
        assertEq(downstream.value(), 1);
    }
}

contract DrainedReservoirTest is ReservoirDisplacementScenario {
    function _deployReceiver() internal override returns (address payable) {
        return payable(address(new AdaptiveDrainer()));
    }

    function test_SmallReservoir_CallbackBreaksCappedDownstreamStateGrowth() public inMode(SMALL) {
        bool downstreamSucceeded = _runBatch();

        assertFalse(downstreamSucceeded, "state-gas spill exceeds the later call's execution budget");
        assertEq(downstream.value(), 0);
        assertEq(AdaptiveDrainer(receiver).slotsWritten(), 2, "callback consumed the shared reservoir first");
    }
}
