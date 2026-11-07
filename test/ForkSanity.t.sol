// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {ReservoirModeTest} from "./utils/ReservoirModeTest.sol";

contract Slots {
    uint256 internal _fresh;
    uint256 internal _existing;

    function prime() external {
        _existing = 1;
    }

    /// @dev Both slots are cold within this call; only the first one creates new state.
    function measure() external returns (uint256 freshCost, uint256 overwriteCost) {
        uint256 g = gasleft();
        _fresh = 1;
        freshCost = g - gasleft();

        g = gasleft();
        _existing = 2;
        overwriteCost = g - gasleft();
    }
}

/// @notice Guards against PoCs silently running in the wrong gas model, e.g. a
///         pre-Glamsterdam EVM or a config without the EIP-8037 state gas reservoir.
/// @dev Observed `gasleft()` deltas for a cold SSTORE (fresh 0->1 vs overwrite 1->2):
///        osaka                   22,112 vs  5,013   (state creation billed to regular gas)
///        amsterdam, cap off     110,032 vs 12,113   (no reservoir; state gas billed to regular gas)
///        amsterdam, no reservoir 110,032 vs 12,113  (tx gas limit <= 2^24)
///        amsterdam, reservoir    12,112 vs 12,113   (state gas drawn from the reservoir)
contract ForkSanityTest is ReservoirModeTest {
    uint256 internal constant EIP7825_TX_GAS_CAP = 1 << 24;

    Slots internal slots;

    function setUp() public {
        slots = new Slots();
        slots.prime();
        _loadReservoirMode();
    }

    function test_RegularGasCappedByEip7825() public view {
        assertLe(gasleft(), EIP7825_TX_GAS_CAP, "regular gas not capped: enable_tx_gas_limit is off");
    }

    function test_AmsterdamStateGas_NoReservoir() public inMode(NONE) {
        (uint256 freshCost, uint256 overwriteCost) = slots.measure();
        assertGt(freshCost - overwriteCost, 90_000, "fresh SSTORE should carry ~98k state gas in regular gas");
    }

    function test_AmsterdamStateGas_FromReservoir_Small() public inMode(SMALL) {
        _assertStateGasFromReservoir();
    }

    function test_AmsterdamStateGas_FromReservoir_Large() public inMode(LARGE) {
        _assertStateGasFromReservoir();
    }

    function _assertStateGasFromReservoir() internal {
        (uint256 freshCost, uint256 overwriteCost) = slots.measure();
        assertApproxEqAbs(
            freshCost, overwriteCost, 1_000, "state creation charged to regular gas: not amsterdam w/ reservoir"
        );
    }
}
