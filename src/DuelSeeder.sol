// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ================================================================================================
//  site: https://duelis.tech   x: https://x.com/DuelisAI
//  DUELIS . $DUEL . BOUT SHEET No. 3 . THE BELL
// ================================================================================================
//
//  ENTRANT
//      The launch initializer. It holds the whole DUEL supply from the token's construction and does
//      one thing, once, in the launch transaction: launch(token, hook, minOut), with the first buy's
//      ETH attached.
//
//  RULES . THE BELL (launch, callable once, only by the address that deployed this contract)
//      1. The token names the hook (DUEL.bindHook).
//      2. The ETH/DUEL pool is initialized at OPEN_TICK: about 1,000,000,000 DUEL per ETH, a fully
//         diluted value of about 1 ETH. The hook refuses a pool opened by anyone but this contract.
//      3. The whole supply goes in as one Uniswap position, DUEL only, from the lowest usable tick
//         up to the opening price, through Uniswap's PositionManager. No ETH goes in. The LP NFT is
//         minted straight to LOCKER (Bout Sheet No. 4), which can never withdraw it: OWNER receives
//         only its LP fees.
//      4. The first buy: all the ETH sent with launch() buys DUEL in the same transaction, the DUEL
//         to OWNER, reverting unless it is at least minOut. It pays the hook's fees like any buy.
//      5. The rounding dust the position cannot hold is sent to OWNER.
//
//  FOULS (refused)
//      a second launch; a caller other than the deployer; a token whose seeder is not this contract;
//      a first buy under minOut.
//
//  OFF THE CARD
//      Nothing stays here after the bell: no tokens, no ETH, no owner function. Every deadline is the
//      launch block itself, so review and signing windows never expire anything baked in.
// ------------------------------------------------------------------------------------------------

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

interface IDUELSeed {
    function bindHook(address hook) external;
    function BINDER() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IPermit2Seed {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerSeed {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

contract DuelSeeder is IUnlockCallback {
    IPoolManager public constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManagerSeed public constant POSITION_MANAGER =
        IPositionManagerSeed(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2Seed public constant PERMIT2 = IPermit2Seed(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;

    address public immutable DEPLOYER;
    address public immutable OWNER;
    address public immutable LOCKER;
    uint24 public immutable LP_FEE;
    int24 public immutable SPACING;
    int24 public immutable OPEN_TICK;

    bool public launched;
    uint256 public lpTokenId;
    uint256 public firstBuyEth;
    uint256 public firstBuyOut;

    event Bell(address indexed token, address indexed hook, uint256 lpTokenId, uint256 liquidity, uint256 dust);
    event FirstBuy(uint256 ethIn, uint256 duelOut, uint256 minOut);

    error NotDeployer();
    error AlreadyLaunched();
    error BadWiring();
    error FirstBuyShort(uint256 out, uint256 minOut);

    constructor(address owner, address locker, uint24 lpFee, int24 spacing, int24 openTick) {
        if (owner == address(0) || locker == address(0) || spacing < 1 || openTick % spacing != 0) revert BadWiring();
        DEPLOYER = msg.sender;
        OWNER = owner;
        LOCKER = locker;
        LP_FEE = lpFee;
        SPACING = spacing;
        OPEN_TICK = openTick;
    }

    function launch(IDUELSeed token, address hook, uint256 minOut) external payable {
        if (msg.sender != DEPLOYER) revert NotDeployer();
        if (launched) revert AlreadyLaunched();
        if (token.BINDER() != address(this)) revert BadWiring();
        launched = true;

        token.bindHook(hook);
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), LP_FEE, SPACING, IHooks(hook));
        uint160 open = TickMath.getSqrtPriceAtTick(OPEN_TICK);
        POOL_MANAGER.initialize(key, open);

        uint256 supply = token.balanceOf(address(this));
        int24 lo = TickMath.minUsableTick(SPACING);
        uint128 liq = LiquidityAmounts.getLiquidityForAmount1(TickMath.getSqrtPriceAtTick(lo), open, supply);
        token.approve(address(PERMIT2), supply);
        PERMIT2.approve(address(token), address(POSITION_MANAGER), uint160(supply), uint48(block.timestamp));
        uint256 id = POSITION_MANAGER.nextTokenId();
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lo, OPEN_TICK, uint256(liq), uint128(0), uint128(supply), LOCKER, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        POSITION_MANAGER.modifyLiquidities(abi.encode(abi.encodePacked(MINT_POSITION, SETTLE_PAIR), params), block.timestamp);
        lpTokenId = id;

        uint256 dust = token.balanceOf(address(this));
        if (dust != 0) token.transfer(OWNER, dust);
        emit Bell(address(token), hook, id, liq, dust);

        if (msg.value != 0) {
            (uint256 spent, uint256 out) = abi.decode(POOL_MANAGER.unlock(abi.encode(key, msg.value)), (uint256, uint256));
            if (out < minOut) revert FirstBuyShort(out, minOut);
            firstBuyEth = spent;
            firstBuyOut = out;
            if (spent < msg.value) {
                (bool ok,) = OWNER.call{value: msg.value - spent}("");
                if (!ok) revert BadWiring();
            }
            emit FirstBuy(spent, out, minOut);
        }
    }

    /// @dev The first buy, inside the PoolManager's lock: exact input, the DUEL straight to OWNER.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert BadWiring();
        (PoolKey memory key, uint256 eth) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta d = POOL_MANAGER.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(eth), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ""
        );
        uint256 spent = uint256(uint128(-d.amount0()));
        uint256 out = uint256(uint128(d.amount1()));
        POOL_MANAGER.settle{value: spent}();
        POOL_MANAGER.take(key.currency1, OWNER, out);
        return abi.encode(spent, out);
    }
}
