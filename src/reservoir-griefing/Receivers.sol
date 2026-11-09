// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {PushPullAuction} from "./PushPullAuction.sol";

/// @notice Shared bidding logic so each receiver can be an auction participant.
abstract contract Bidder {
    /// @dev Lets griefers skip their griefing when receiving their own pull payment.
    bool internal transient _withdrawing;

    function placeBid(PushPullAuction auction) external payable {
        auction.bid{value: msg.value}();
    }

    function withdrawFrom(PushPullAuction auction) external {
        _withdrawing = true;
        auction.withdraw();
        _withdrawing = false;
    }
}

/// @notice Benign: only emits an event on receipt (e.g. most smart wallets).
contract EventReceiver is Bidder {
    event Received(address indexed from, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}

/// @notice Benign: updates an existing nonzero slot on receipt (no new state).
contract OverwriteReceiver is Bidder {
    uint256 public totalReceived = 1; // pre-initialized so receipt is nonzero -> nonzero

    receive() external payable {
        totalReceived += msg.value;
    }
}

/// @notice Benign: creates new state on receipt (appends a receipt record).
contract FreshStateReceiver is Bidder {
    uint256[] public receipts;

    receive() external payable {
        receipts.push(msg.value);
    }

    function receiptCount() external view returns (uint256) {
        return receipts.length;
    }
}

/// @notice Griefer: creates as much new state as its regular-gas budget allows.
///         State gas comes from the payer's tx reservoir, outside the requested 1e5
///         execution-gas allowance. A value-bearing CALL also adds a 2,300 gas stipend.
contract GreedyDrainer is Bidder {
    /// @dev Pre-initialized (count + 1) so updating it is nonzero -> nonzero: no state gas.
    uint256 internal _slotsPlusOne = 1;
    mapping(uint256 => uint256) internal _junk;

    receive() external payable {
        if (_withdrawing) return;
        uint256 i = _slotsPlusOne;
        while (gasleft() > 15_000) {
            _junk[++i] = 1;
        }
        _slotsPlusOne = i;
    }

    function slotsWritten() external view returns (uint256) {
        return _slotsPlusOne - 1;
    }
}

/// @notice Griefer: drains a small reservoir as far as possible *without* reverting.
///         Each new slot is written in a nested call; a write that would spill
///         into regular gas OOGs that nested call (its state gas is refunded to the
///         reservoir) and the loop stops, leaving the receive itself successful. A
///         reservoir larger than this callback can consume is only partially depleted.
contract AdaptiveDrainer is Bidder {
    /// @dev Pre-initialized (count + 1) so the final bookkeeping write is nonzero -> nonzero.
    ///      A zero -> nonzero write here would need state gas *after* the reservoir is
    ///      drained, spill ~98k into regular gas, and OOG the drainer's own receive().
    uint256 internal _slotsPlusOne = 1;
    mapping(uint256 => uint256) internal _junk;

    /// @dev Regular gas kept back from each nested call so receive() can always finish.
    ///      Amsterdam reprices regular gas too (e.g. a nonzero->nonzero SSTORE is ~12k).
    uint256 internal constant HEADROOM = 30_000;

    receive() external payable {
        if (_withdrawing) return;
        uint256 i = 0;
        while (gasleft() > HEADROOM + 10_000) {
            try this.writeOne{gas: gasleft() - HEADROOM}(i + 1) {
                ++i;
            } catch {
                break;
            }
        }
        _slotsPlusOne += i;
    }

    function writeOne(uint256 key) external {
        require(msg.sender == address(this));
        _junk[uint256(keccak256(abi.encode(_slotsPlusOne, key)))] = 1;
    }

    function slotsWritten() external view returns (uint256) {
        return _slotsPlusOne - 1;
    }
}

/// @notice Griefer: uses a small amount of execution gas to deposit 24 KiB of runtime code.
/// @dev The initcode returns zero-filled memory as runtime bytecode. EIP-8037 charges code
///      deposit to state gas at CPSB (1,530 gas/byte), while the callback's requested gas
///      limits only execution. `_deployed` starts nonzero so recording the created address
///      overwrites existing state rather than creating another slot.
contract CodeDepositDrainer is Bidder {
    uint256 internal constant RUNTIME_SIZE = 24_576;

    address internal _deployed = address(1);

    receive() external payable {
        if (_withdrawing) return;

        address created;
        assembly ("memory-safe") {
            // PUSH2 0x6000; PUSH1 0; RETURN => 24 KiB of zero-filled runtime code.
            mstore(0, hex"6160006000f30000000000000000000000000000000000000000000000000000")
            created := create(0, 0, 6)
        }
        require(created != address(0));
        _deployed = created;
    }

    function deployed() external view returns (address) {
        return _deployed;
    }
}
