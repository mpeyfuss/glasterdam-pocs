// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.37;

import {console} from "forge-std-1.17.0/Test.sol";
import {ReservoirModeTest} from "../utils/ReservoirModeTest.sol";
import {GasleftMetering} from "../../src/gasleft-metering/GasleftMetering.sol";

contract GasleftMeteringTest is ReservoirModeTest {
    GasleftMetering internal meter;

    function setUp() public {
        meter = new GasleftMetering();
        _loadReservoirMode();
    }

    function test_NoReservoir_RefillMakesGasleftIncrease() public inMode(NONE) {
        (uint256 startGas, uint256 endGas, uint256 wrappedDelta) = meter.observeRefillAcrossCall();

        console.log("gasleft before child clear:", startGas);
        console.log("gasleft after child clear:", endGas);
        console.log("gasleft increase:", endGas - startGas);

        assertGt(endGas, startGas, "state-gas refill should exceed clear/call execution cost");
        assertEq(wrappedDelta, type(uint256).max - (endGas - startGas) + 1, "unchecked delta wraps");
    }

    function test_NoReservoir_CheckedMeterPanics() public inMode(NONE) {
        (bool ok, bytes memory returndata) =
            address(meter).call(abi.encodeCall(GasleftMetering.checkedMeterAcrossCall, ()));

        assertFalse(ok, "checked gas delta should underflow");
        assertEq(bytes4(returndata), bytes4(0x4e487b71), "Solidity panic selector");
        assertEq(uint256(bytes32(_slice32(returndata, 4))), 0x11, "arithmetic panic code");
    }

    function test_SmallReservoir_SameCheckedMeterSucceeds() public inMode(SMALL) {
        uint256 observedExecutionGas = meter.checkedMeterAcrossCall();

        console.log("checked meter result with reservoir:", observedExecutionGas);

        assertGt(observedExecutionGas, 0);
    }

    function test_LargeReservoir_SameCheckedMeterSucceeds() public inMode(LARGE) {
        uint256 observedExecutionGas = meter.checkedMeterAcrossCall();

        console.log("checked meter result with reservoir:", observedExecutionGas);

        assertGt(observedExecutionGas, 0);
    }

    function test_SmallReservoir_PersistentGrowthIsUnderreported() public inMode(SMALL) {
        uint256 observedExecutionGas = meter.meterPersistentGrowth();

        console.log("metered execution gas for fresh SSTORE:", observedExecutionGas);
        console.log("state gas omitted by meter:", uint256(97_920));

        assertLt(observedExecutionGas, 20_000, "GAS delta sees only execution gas");
        assertEq(meter.persistentValue(), 1);
    }

    function test_LargeReservoir_PersistentGrowthIsUnderreported() public inMode(LARGE) {
        uint256 observedExecutionGas = meter.meterPersistentGrowth();

        console.log("metered execution gas for fresh SSTORE:", observedExecutionGas);
        console.log("state gas omitted by meter:", uint256(97_920));

        assertLt(observedExecutionGas, 20_000, "GAS delta sees only execution gas");
        assertEq(meter.persistentValue(), 1);
    }

    /// @dev Avoid forge-std's vm-based byte helpers before reservoir-sensitive assertions.
    function _slice32(bytes memory data, uint256 offset) internal pure returns (bytes32 result) {
        if (data.length < offset + 32) return bytes32(0);
        assembly ("memory-safe") {
            result := mload(add(add(data, 0x20), offset))
        }
    }
}
