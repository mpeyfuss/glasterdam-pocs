// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

/// @notice Minimal English auction using the common anti-griefing refund pattern:
///         optimistically push the outbid refund with a fixed gas limit, fall back
///         to a pull payment if the push fails.
contract PushPullAuction {
    uint256 public constant REFUND_GAS = 100_000;

    address public highestBidder;
    uint256 public highestBid;
    mapping(address => uint256) public pendingWithdrawals;

    event RefundPushed(address indexed to, uint256 amount);
    event RefundDeferred(address indexed to, uint256 amount);

    error BidTooLow();
    error NothingToWithdraw();
    error WithdrawFailed();

    function bid() external payable {
        if (msg.value <= highestBid) revert BidTooLow();

        address prevBidder = highestBidder;
        uint256 prevBid = highestBid;

        highestBidder = msg.sender;
        highestBid = msg.value;

        if (prevBidder != address(0)) {
            bool ok;
            uint256 refundGas = REFUND_GAS;
            // Do not copy return data. A high-level low-level call can otherwise allocate and
            // copy attacker-controlled return data in this frame, creating a separate return-bomb
            // griefing path that is unrelated to the state-gas reservoir behavior under test.
            assembly ("memory-safe") {
                ok := call(refundGas, prevBidder, prevBid, 0, 0, 0, 0)
            }
            if (ok) {
                emit RefundPushed(prevBidder, prevBid);
            } else {
                pendingWithdrawals[prevBidder] += prevBid;
                emit RefundDeferred(prevBidder, prevBid);
            }
        }
    }

    function withdraw() external {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }
}
