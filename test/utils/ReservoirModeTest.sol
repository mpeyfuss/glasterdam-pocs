// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {Test} from "forge-std-1.17.0/Test.sol";

/// @notice Base for tests whose behavior depends on the EIP-8037 state gas reservoir.
///
/// The reservoir is `txGasLimit - 2^24`. Forge's tx gas limit (`gas_limit`) is a per-run
/// setting, so each mode is a separate forge invocation with `RESERVOIR_MODE` set.
/// `make reservoir-modes` runs all three; a plain `forge test` is the `large` mode.
///
///   none  : gas_limit = 2^24          -> no reservoir, state gas billed to regular gas
///   small : gas_limit = 17_000_000    -> reservoir 222_784 (~2 new slots)
///   large : gas_limit = 2^30          -> reservoir ~1.06B
///
/// Tests for other modes are reported as skipped.
///
/// FORGE CAVEATS (forge 1.9.0, see README):
///  - Any cheatcode call (`vm.*`) wipes the remaining reservoir for the rest of that
///    transaction (setUp and each test are separate transactions). Keep cheatcodes out of
///    test bodies until after the last measurement. In setUp, call them last.
///  - Every test body is ONE transaction, so state created earlier in the body has
///    already used reservoir. Do prerequisite state setup in setUp.
///  - setUp also runs under the mode's gas limit; in `none` mode its state growth
///    (deploys cost ~1-2M state gas each) must fit within 2^24.
abstract contract ReservoirModeTest is Test {
    bytes32 internal constant NONE = keccak256("none");
    bytes32 internal constant SMALL = keccak256("small");
    bytes32 internal constant LARGE = keccak256("large");

    uint256 internal constant SMALL_RESERVOIR = 17_000_000 - (1 << 24);

    bytes32 internal _mode;

    /// @dev Call as the LAST statement of setUp (it uses a cheatcode).
    function _loadReservoirMode() internal {
        _mode = keccak256(bytes(vm.envOr("RESERVOIR_MODE", string("large"))));
    }

    /// @dev Body runs only in `mode`; otherwise the test is reported as skipped.
    ///      The skip cheatcode only executes on the non-matching path.
    modifier inMode(bytes32 mode) {
        if (_mode != mode) {
            vm.skip(true);
            return;
        }
        _;
    }
}
