// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice imd/acc Stacker: pulls `amount` IMD from msg.sender (approved) and stakes it as sIMD
/// for `to`, under project = msg.sender (event `Stacked(project, trader, imd, shares)`). It also
/// returns the shares minted; PLEA ignores the return value. Sepolia: imd/acc launch #1294
/// (0x0457276d7b036818b3eddc1a4a3fceda61e9314d).
interface IStacker {
    function credit(address to, uint256 amount) external;
    /// @notice The sIMD vault the Stacker deposits into.
    function SIMD() external view returns (address);
}
