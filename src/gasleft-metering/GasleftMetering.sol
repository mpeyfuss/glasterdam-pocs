// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

/// @notice Minimal examples of application-level accounting based on `gasleft()` deltas.
/// @dev Under EIP-8037, GAS observes execution gas only. State-gas refills can also make
///      the observed execution-gas balance increase.
contract GasleftMetering {
    uint256 internal _scratch;
    uint256 internal _persistent;

    error OnlySelf();

    /// @notice A representative checked gas meter used by relayers and batch executors.
    /// @dev In a no-reservoir transaction, `_scratch = 1` borrows state gas from execution
    ///      gas. `clearScratch` refills that gas across the call boundary. The refill can
    ///      exceed the call's execution cost, making `gasleft()` greater than `startGas` and
    ///      causing Solidity's checked subtraction to panic.
    function checkedMeterAcrossCall() external returns (uint256 executionGasUsed) {
        _scratch = 1;
        uint256 startGas = gasleft();

        this.clearScratch();

        executionGasUsed = startGas - gasleft();
    }

    /// @notice The same flow with raw observations and unchecked arithmetic.
    /// @return startGas GAS immediately after creating the temporary slot.
    /// @return endGas GAS after a child frame clears the slot and returns.
    /// @return wrappedDelta `startGas - endGas` under unchecked arithmetic.
    function observeRefillAcrossCall() external returns (uint256 startGas, uint256 endGas, uint256 wrappedDelta) {
        _scratch = 1;
        startGas = gasleft();

        this.clearScratch();

        endGas = gasleft();
        unchecked {
            wrappedDelta = startGas - endGas;
        }
    }

    /// @notice A meter around persistent state growth.
    /// @dev With a reservoir, the returned delta excludes the state-gas component even
    ///      though the transaction sender pays it.
    function meterPersistentGrowth() external returns (uint256 executionGasUsed) {
        uint256 startGas = gasleft();
        _persistent = 1;
        executionGasUsed = startGas - gasleft();
    }

    /// @dev The external self-call gives the clear its own frame. The refill is first held
    ///      in that child frame's reservoir, then repays the parent's state-gas debt when
    ///      the frame is merged back into the parent.
    function clearScratch() external {
        if (msg.sender != address(this)) revert OnlySelf();
        _scratch = 0;
    }

    function persistentValue() external view returns (uint256) {
        return _persistent;
    }
}
