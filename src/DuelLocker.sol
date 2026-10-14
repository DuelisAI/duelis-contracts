// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ================================================================================================
//  site: https://duelis.tech   x: https://x.com/DuelisAI
//  DUELIS . $DUEL . BOUT SHEET No. 4 . THE VAULT
// ================================================================================================
//
//  ENTRANT
//      The permanent custody of the pool's liquidity. The seeder mints the launch LP NFT straight to
//      this contract in the launch transaction, and it stays here forever.
//
//  RULES . THE VAULT
//      1. collect(tokenId): anyone may call it. It removes ZERO liquidity from a position this contract
//         holds and sends the LP fees it earned, ETH and DUEL, to OWNER. Only fees ever leave.
//
//  FOULS (impossible, because the code does not exist)
//      withdrawing liquidity; transferring or approving the NFT; any arbitrary call; an owner
//      function; an upgrade. There is no other function.
// ------------------------------------------------------------------------------------------------

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface IPositionManagerVault {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory, uint256);
}

contract DuelLocker {
    IPositionManagerVault public constant POSITION_MANAGER =
        IPositionManagerVault(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant TAKE_PAIR = 0x11;

    address public immutable OWNER;

    event Collected(uint256 indexed tokenId);

    error BadWiring();

    constructor(address owner) {
        if (owner == address(0)) revert BadWiring();
        OWNER = owner;
    }

    /// @notice Send the LP fees of `tokenId` (held here) to OWNER. The liquidity never moves.
    function collect(uint256 tokenId) external {
        (PoolKey memory key,) = POSITION_MANAGER.getPoolAndPositionInfo(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, OWNER);
        POSITION_MANAGER.modifyLiquidities(
            abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), block.timestamp
        );
        emit Collected(tokenId);
    }
}
