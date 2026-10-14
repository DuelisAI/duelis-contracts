// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ================================================================================================
//  site: https://duelis.tech   x: https://x.com/DuelisAI
//  DUELIS . $DUEL . BOUT SHEET No. 2 . THE RING
// ================================================================================================
//
//  ENTRANT
//      The Uniswap v4 hook of the ETH/DUEL pool. It holds two corners of small on-chain networks:
//      six Guards, who set the fee on every swap, and four Shadows, paper-trading bots who look for
//      what the Guards fail to tax. No owner function, no upgrade, no oracle, no server.
//
//  RULES . THE FEE (on the ETH side of every swap, on top of the pool's own LP fee)
//      Buys pay FLOOR (1%). Sells of tokens at least HOLDER_AGE (6 hours) old pay FLOOR. Those two
//      are fixed in code and no Guard can change them.
//      Everything else goes to the champion Guard, which charges FLOOR to CAP (1% to 5%):
//        . sells of tokens younger than 6 hours (flips),
//        . a second trade by the same wallet in one block,
//        . the sandwich shape: the same wallet traded earlier in this block, someone else traded
//          since, and it now trades the other way (a back-run). A back-run also pays, by a fixed rule,
//          at least the price gain since its own first trade in the block plus FLOOR, up to 5%. A
//          sandwich whose price gain stays under that ceiling cannot profit; one that moves the price
//          further can keep the excess. Measured (test/SandwichGrid.t.sol) on a pool about 6 ETH deep:
//          victims of 0.02 to 0.2 ETH leave the sandwich at a loss; 0.5 ETH and more can be profited
//          from. The threshold grows with the pool's depth.
//      The wallet is the one that signs the transaction (tx.origin), and the age is its tokens' age,
//      read from the token. Inputs: token age, same block, sandwich shape, trade rate, size against
//      pool depth, direction, volatility, launch phase.
//
//  RULES . THE DUEL (once per epoch of one day, every step permissionless)
//      1. scoreShadows(): each Shadow replays the epoch's recorded price path and recorded buys as
//         sandwich victims, and is scored on its paper profit against the champion's fees.
//      2. scoreGuard(g), for each Guard: fees it would charge on recorded flips and back-runs, less
//         LAMBDA x fees it would charge on recorded short holders, less the best Shadow's paper
//         profit against it.
//      3. evolve(): on each side the weakest is replaced by a mutated copy of the strongest; the best
//         Guard becomes champion. The epoch's winning side is the Guards if no Shadow made a paper
//         profit against the champion, else the Shadows.
//
//  RULES . THE PLATFORM
//      Launched through Programmable (programmable.market). Every swap of this pool pays PLATFORM_FEE
//      (3,000 ppm = 0.30%) of its gross native value to Programmable, enforced here, once: the same
//      accounting as Programmable's EthereumNative30HookV3 (gross native value including the hook fees,
//      rounded UP per trade, platform allocated first). It is minted as ETH claims to feeVault, an
//      unmodified EthereumNativeFeeVaultV3 this hook deploys in its constructor, and recorded there;
//      anyone may call feeVault.claimPlatform(), which pays only 0xD885...79da. The hook's own buyback
//      swaps, which Uniswap never routes through hook callbacks, pay it too. It is not part of the
//      split below.
//
//  RULES . THE PURSE
//      The hook fee is split: 55% to holders (sent to the token, which vests it by token age), 20% to
//      the side pot, 20% to buyback-and-burn, 5% to keepers who run the duel. A buyer on the Duelis
//      site names a side in hookData; their weight is the ETH they bought with. Selling during the
//      epoch drops the weight. The winning side shares the epoch's pot; an empty winning side rolls
//      the pot to the next epoch.
//
//  SCORING (measured) . see test/Gas.t.sol and econ_duelis.js
//
//  FOULS (refused)
//      a pool other than ETH/DUEL at this LP fee and spacing; a pool opened by anyone but the seeder;
//      a pool opened before the token names this hook; a second pool; duel steps out of order or before the epoch ends.
//
//  OFF THE CARD
//      The Uniswap app cannot route this pool (return-delta hook). The Shadow side's protective value
//      over learning from real trades alone was not shown by the model (ANALYSIS.md). The owner keeps
//      the LP NFT and its LP fee, and can remove the liquidity. Smart-contract wallets look "fresh":
//      their tokens sit in the contract, not with the signer.
// ------------------------------------------------------------------------------------------------

import {BaseHook} from "./base/BaseHook.sol";
import {AgentNet} from "./AgentNet.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {EthereumNativeFeeVaultV3} from "./EthereumNativeFeeVaultV3.sol";

interface IDUEL {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function ageOf(address) external view returns (uint256);
    function burn(uint256) external;
    function notify() external payable;
    function HOOK() external view returns (address);
}

contract DuelHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    // ───────────────────────────────────────────────────────── constants
    uint256 internal constant PIPS = 1_000_000;
    int256 internal constant UNIT = 1e6;
    uint256 internal constant Q96 = 1 << 96;
    Currency internal constant ETH = Currency.wrap(address(0));

    uint256 public constant FLOOR = 10_000; // 1% hook fee for holders
    uint256 public constant CAP = 50_000; // 5% ceiling for flips and other bot-like trades
    uint256 public constant HOLDER_AGE = 6 hours; // sells of tokens at least this old always pay FLOOR
    uint256 public constant FLIP_AGE = 30 minutes; // ex-post label: a sell of younger tokens is a flip
    uint256 public constant EPOCH = 1 days;
    uint256 public constant G = 6; // Guards
    uint256 public constant S = 4; // Shadows
    uint256 public constant PATH = 24; // recorded price points per epoch
    uint256 public constant SAMPLES = 16; // recorded consulted swaps per epoch
    uint256 public constant VICTIMS = 8; // recorded ordinary buys per epoch (sandwich targets for Shadows)
    int256 public constant LAMBDA = 5; // weight of fees charged to short holders in a Guard's score
    uint256 public constant TO_HOLDERS = 5_500; // of 10,000
    uint256 public constant TO_SIDE = 2_000;
    uint256 public constant TO_BURN = 2_000; // keepers get the remainder (500)
    uint256 public constant STEP_PAY = 0.002 ether; // a duel step's keeper pay, at most a quarter of the keeper book
    int24 public constant BUYBACK_BAND = 50; // a buyback never pushes the price more than 0.5% past spot
    uint256 public constant BUYBACK_GAP = 1 hours;
    uint256 public constant BACKRUN_MAX = 50_000; // a back-run pays at most 5% too
    uint256 public constant SHADOW_SIZE = 0.05 ether; // paper notional per Shadow path trade, scaled by depth below
    address public constant PLATFORM = 0xD88539d3c4C460136a733A3Fd60cf6BF269079da; // Programmable's fee recipient

    uint8 internal constant PAY = 1;
    uint8 internal constant BUYBACK = 2;
    uint8 internal constant NOTIFY = 3;

    // ───────────────────────────────────────────────────────── wiring
    IDUEL public immutable TOKEN;
    address public immutable OWNER;
    address public immutable SEEDER; // the only address that may open the pool
    uint256 public constant PLATFORM_FEE = 3_000; // ppm of each swap's gross native value to PLATFORM
    EthereumNativeFeeVaultV3 public feeVault; // holds and pays the platform fee, to PLATFORM only; set once, in the constructor
    uint24 public immutable LP_FEE;
    int24 public immutable SPACING;

    bool public live;
    PoolId public poolId;
    uint64 public launchTime;

    // ───────────────────────────────────────────────────────── observation
    int24 public lastTick;
    uint64 public lastObsBlock;
    uint256 public volE6; // EMA of |tick change| per observed block, 100 ticks = 1e6

    uint64 public seqBlock;
    uint32 public seq;

    struct Seen {
        uint64 blk; // last block this wallet traded
        uint32 seq; // its position in that block
        bool buy; // its direction then
        uint16 rate; // trades within 300 blocks of each other
        uint64 rateBlk;
        int24 tick; // spot when it last traded
    }

    mapping(address => Seen) public seen;

    // ───────────────────────────────────────────────────────── the corners
    bytes32[3][G] internal guards;
    bytes32[3][S] internal shadows;
    uint8 public champ;

    // ───────────────────────────────────────────────────────── the epoch's record
    uint256 public epoch; // index, 0 at launch
    uint256 public epochEnd;

    struct Pt {
        int24 tick;
        uint64 time;
        uint128 depth; // ETH virtual reserve, wei
    }

    Pt[PATH] internal path;
    uint8 public pathLen;
    uint64 public nextPathTime;

    struct Sample {
        bytes32 x; // eight int32 features
        uint96 ethSide;
        uint40 age;
        bool buy;
        bool sandwich;
        bool same;
    }

    Sample[SAMPLES] internal samples;
    uint32 public sampleCount;

    struct Victim {
        uint128 ethSide;
        uint128 depth;
    }

    Victim[VICTIMS] internal victims;
    uint32 public victimCount;

    // scoring state for the current epoch
    int256[S] public shadowPnl; // against the champion
    uint256[S] internal shadowPlan; // bit i: a toggle (enter/exit) at path point i; bits 128+j: sandwich victim j
    bool public shadowsScored;
    int256[G] public guardScore;
    uint256 public guardsScoredMask;

    // ───────────────────────────────────────────────────────── books (ETH as ERC-6909 claims on the PoolManager)
    uint256 public holderBook;
    uint256 public sideBook; // this epoch's pot, growing
    uint256 public burnBook;
    uint256 public keeperBook;
    uint256 public lastBuyback;
    uint256 public feesAll;
    uint256 public burned;
    uint256 public platformAll; // platform fee accrued to feeVault, all time

    // the side game
    mapping(uint256 => uint256[3]) public sideTotal; // [epoch][1 Guards, 2 Shadows]
    mapping(uint256 => mapping(address => uint256)) public backing; // side << 248 | eth
    mapping(uint256 => uint256) public sidePot; // settled pot per epoch
    mapping(uint256 => uint8) public winner; // 1 Guards, 2 Shadows

    // ───────────────────────────────────────────────────────── events / errors
    event Launched(PoolId indexed id, int24 openTick);
    event Fee(address indexed trader, bool buy, uint256 ethSide, uint256 rate, uint256 fee);
    event Backed(uint256 indexed epoch, address indexed who, uint8 side, uint256 eth);
    event ShadowsScored(uint256 indexed epoch, int256 best);
    event GuardScored(uint256 indexed epoch, uint256 guard, int256 score);
    event Evolved(uint256 indexed epoch, uint8 champion, uint8 winner, uint256 pot);
    event SideClaimed(uint256 indexed epoch, address indexed who, uint256 eth);
    event BoughtBack(uint256 eth, uint256 duel);
    event Flushed(uint256 eth);

    error BadWiring();
    error WrongPool();
    error NotSeeder();
    error AlreadyLive();
    error NotLive();
    error TooSoon();
    error OutOfOrder();
    error Nothing();
    error PartialFill(uint256 expected, uint256 actual);

    constructor(
        IPoolManager pm,
        address owner,
        IDUEL token,
        address seeder,
        uint24 lpFee,
        int24 spacing,
        uint256 platformFee
    ) BaseHook(pm) {
        if (owner == address(0) || address(token) == address(0) || seeder == address(0)) revert BadWiring();
        if (lpFee > 1_000_000 || (lpFee & 0x800000) != 0 || spacing < 1 || spacing > 16_383) revert BadWiring();
        if (platformFee != PLATFORM_FEE) revert BadWiring();
        TOKEN = token;
        OWNER = owner;
        SEEDER = seeder;
        feeVault = new EthereumNativeFeeVaultV3(pm, owner);
        LP_FEE = lpFee;
        SPACING = spacing;
        // the starting corners: Guard 0 is the hand-designed seed; the others are mutations of it.
        // Shadows start as small random networks.
        bytes32[3] memory seedW = seedGuard();
        guards[0] = seedW;
        for (uint256 i = 1; i < G; ++i) guards[i] = _mutate(seedW, uint256(keccak256(abi.encode("DUELIS.guard", i))));
        for (uint256 i; i < S; ++i) shadows[i] = _random(uint256(keccak256(abi.encode("DUELIS.shadow", i))));
    }

    /// @notice The hand-designed starting Guard: hidden 0 reads token freshness, hidden 1 the sandwich shape,
    ///         hidden 2 the same-block repeat, hidden 3 the launch phase; output bias -0.5 so an ordinary young
    ///         sell sits near FLOOR and freshness, back-runs and repeats push it up.
    function seedGuard() public pure returns (bytes32[3] memory w) {
        bytes memory b = new bytes(96);
        b[0 * 8 + 0] = bytes1(uint8(127)); // h0 <- x0 (freshness)
        b[1 * 8 + 2] = bytes1(uint8(127)); // h1 <- x2 (sandwich)
        b[2 * 8 + 1] = bytes1(uint8(127)); // h2 <- x1 (same block)
        b[3 * 8 + 7] = bytes1(uint8(127)); // h3 <- x7 (launch)
        b[81 + 0] = bytes1(uint8(90));
        b[81 + 1] = bytes1(uint8(127));
        b[81 + 2] = bytes1(uint8(60));
        b[81 + 3] = bytes1(uint8(60));
        b[90] = bytes1(uint8(int8(-64)));
        assembly ("memory-safe") {
            mstore(w, mload(add(b, 0x20)))
            mstore(add(w, 0x20), mload(add(b, 0x40)))
            mstore(add(w, 0x40), mload(add(b, 0x60)))
        }
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(ETH, Currency.wrap(address(TOKEN)), LP_FEE, SPACING, IHooks(address(this)));
    }

    function guardWeights(uint256 i) external view returns (bytes32[3] memory) {
        return guards[i];
    }

    function shadowWeights(uint256 i) external view returns (bytes32[3] memory) {
        return shadows[i];
    }

    function pathAt(uint256 i) external view returns (Pt memory) {
        return path[i];
    }

    function sampleAt(uint256 i) external view returns (Sample memory) {
        return samples[i];
    }

    function victimAt(uint256 i) external view returns (Victim memory) {
        return victims[i];
    }

    // ═══════════════════════════════════════════════════════════════ opening

    function afterInitialize(address sender, PoolKey calldata key, uint160, int24 openTick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (live) revert AlreadyLive();
        if (
            Currency.unwrap(key.currency0) != address(0) || Currency.unwrap(key.currency1) != address(TOKEN)
                || key.fee != LP_FEE || key.tickSpacing != SPACING
        ) revert WrongPool();
        if (sender != SEEDER) revert NotSeeder();
        if (TOKEN.HOOK() != address(this)) revert BadWiring();
        live = true;
        poolId = key.toId();
        launchTime = uint64(block.timestamp);
        lastTick = openTick;
        lastObsBlock = uint64(block.number);
        epochEnd = block.timestamp + EPOCH;
        nextPathTime = uint64(block.timestamp);
        emit Launched(poolId, openTick);
        return this.afterInitialize.selector;
    }

    // ═══════════════════════════════════════════════════════════════ the fee

    function beforeSwap(address sender, PoolKey calldata, SwapParams calldata p, bytes calldata hookData)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (sender == address(this)) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        (uint160 sp, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 depth = _depth(sp);
        _observe(tick, depth);
        bool buy = p.zeroForOne;
        bool ethSpecified = (p.amountSpecified < 0) == buy; // exact-in buy, or exact-out sell
        uint256 amt = p.amountSpecified < 0 ? uint256(-p.amountSpecified) : uint256(p.amountSpecified);
        uint256 ethSide = ethSpecified ? amt : _toEth(amt, sp);
        uint256 rate = _rate(buy, ethSide, depth, tick);
        assembly ("memory-safe") {
            tstore(0xD0E1, rate)
        }
        _side(buy, p.amountSpecified < 0, amt, hookData);
        if (!ethSpecified) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        uint256 fee = _take(buy, amt, rate, p.amountSpecified > 0);
        // the pool must move exactly this much ETH, or afterSwap reverts: no partial fill pays a full fill's fees
        uint256 expect = p.amountSpecified < 0 ? amt - fee : amt + fee;
        assembly ("memory-safe") {
            tstore(0xD0E2, expect)
        }
        return (this.beforeSwap.selector, toBeforeSwapDelta(int128(int256(fee)), 0), 0);
    }

    function afterSwap(address sender, PoolKey calldata, SwapParams calldata p, BalanceDelta d, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (sender == address(this)) return (this.afterSwap.selector, 0);
        uint256 rate;
        uint256 expect;
        assembly ("memory-safe") {
            rate := tload(0xD0E1)
            expect := tload(0xD0E2)
        }
        int128 e0 = d.amount0();
        uint256 eth = e0 < 0 ? uint256(int256(-e0)) : uint256(int256(e0));
        if (eth == 0 || d.amount1() == 0) revert Nothing(); // no trade
        if ((p.amountSpecified < 0) == p.zeroForOne) {
            // ETH was named: the fees were taken before the swap on the full amount, so only a full fill may stand
            if (eth != expect) revert PartialFill(expect, eth);
            return (this.afterSwap.selector, 0);
        }
        return (this.afterSwap.selector, int128(int256(_take(p.zeroForOne, eth, rate, p.amountSpecified > 0))));
    }

    /// @dev The hook fee at `rate` and the platform fee on the same gross native value, as Programmable's kernel
    ///      assesses it: `eth` is gross (exact input) or net of all fees (`net`, exact output, grossed up, rounded
    ///      up); the platform fee is ceil(gross x 0.30%), allocated first. Returns the total taken from the swap.
    function _take(bool buy, uint256 eth, uint256 rate, bool net) internal returns (uint256 total) {
        uint256 gross = net ? FullMath.mulDivRoundingUp(eth, PIPS, PIPS - rate - PLATFORM_FEE) : eth;
        uint256 pf = FullMath.mulDivRoundingUp(gross, PLATFORM_FEE, PIPS);
        uint256 fee = net ? gross - eth - pf : (gross * rate) / PIPS;
        total = fee + pf;
        if (fee != 0) {
            _book(fee);
            poolManager.mint(address(this), ETH.toId(), fee);
            emit Fee(tx.origin, buy, gross, rate, fee);
        }
        if (pf != 0) {
            poolManager.mint(address(feeVault), ETH.toId(), pf);
            _platform(pf);
        }
    }

    /// @dev Records `pf` wei of platform fee already held by feeVault as ETH claims.
    function _platform(uint256 pf) internal {
        platformAll += pf;
        feeVault.recordFees(pf, 0);
    }

    /// @notice The fee a trade would pay now, without recording it: for the site and for keepers.
    function quoteRate(address who, bool buy, uint256 ethSide) external view returns (uint256 rate, bool consulted) {
        (uint160 sp,,,) = poolManager.getSlot0(poolId);
        Seen memory s = seen[who];
        uint32 q = seqBlock == block.number ? seq : 0;
        bool same = s.blk == block.number;
        bool sandwich = same && s.seq < q && s.buy != buy;
        uint256 age = buy ? 0 : TOKEN.ageOf(who);
        if (!same && !sandwich && (buy || age >= HOLDER_AGE)) return (FLOOR, false);
        uint256 rt = block.number - s.rateBlk < 300 ? uint256(s.rate) + 1 : 1;
        int256[8] memory x = _features(buy, age, same, sandwich, rt, ethSide, _depth(sp));
        rate = _feeOf(guards[champ], x);
        if (sandwich) {
            (, int24 nowTick,,) = poolManager.getSlot0(poolId);
            uint256 fr = backrunRate(buy, s.tick, nowTick);
            if (fr > rate) rate = fr;
        }
        return (rate, true);
    }

    /// @dev Decide the rate, update the wallet's trail and the epoch's samples.
    function _rate(bool buy, uint256 ethSide, uint256 depth, int24 tick) internal returns (uint256 rate) {
        address who = tx.origin;
        if (seqBlock != block.number) {
            seqBlock = uint64(block.number);
            seq = 0;
        }
        Seen storage s = seen[who];
        bool same = s.blk == block.number;
        bool sandwich = same && s.seq < seq && s.buy != buy;
        uint256 rt = block.number - s.rateBlk < 300 ? uint256(s.rate) + 1 : 1;
        int24 firstTick = same ? s.tick : tick;
        seq += 1;
        s.blk = uint64(block.number);
        s.seq = seq;
        s.buy = buy;
        s.rate = uint16(rt > 10_000 ? 10_000 : rt);
        s.rateBlk = uint64(block.number);
        s.tick = firstTick;

        uint256 age = buy ? 0 : TOKEN.ageOf(who);
        if (!same && !sandwich && (buy || age >= HOLDER_AGE)) {
            if (buy) _victim(ethSide, depth);
            return FLOOR;
        }
        int256[8] memory x = _features(buy, age, same, sandwich, rt, ethSide, depth);
        rate = _feeOf(guards[champ], x);
        if (sandwich) {
            uint256 floorRate = backrunRate(buy, firstTick, tick);
            if (floorRate > rate) rate = floorRate;
        }
        _sample(x, ethSide, age, buy, sandwich, same);
    }

    /// @notice The fixed minimum for a back-run: the price gain since the wallet's first trade in the block, in
    ///         millionths, plus FLOOR, capped at BACKRUN_MAX. A sell back-run gains when DUEL got dearer (the tick
    ///         fell); a buy back-run gains when DUEL got cheaper (the tick rose).
    function backrunRate(bool buy, int24 firstTick, int24 nowTick) public pure returns (uint256) {
        bool gained = buy ? nowTick > firstTick : nowTick < firstTick;
        if (!gained) return FLOOR;
        uint160 a = TickMath.getSqrtPriceAtTick(buy ? nowTick : firstTick);
        uint160 b = TickMath.getSqrtPriceAtTick(buy ? firstTick : nowTick);
        // (a / b)^2 - 1, in millionths: a > b
        uint256 r = FullMath.mulDiv(FullMath.mulDiv(PIPS, a, b), a, b) - PIPS;
        uint256 v = r + FLOOR;
        return v > BACKRUN_MAX ? BACKRUN_MAX : v;
    }

    function _features(bool buy, uint256 age, bool same, bool sandwich, uint256 rt, uint256 ethSide, uint256 depth)
        internal
        view
        returns (int256[8] memory x)
    {
        x[0] = buy ? int256(0) : ageFeature(age);
        x[1] = same ? UNIT : int256(0);
        x[2] = sandwich ? UNIT : int256(0);
        x[3] = int256((rt > 10 ? 10 : rt) * uint256(UNIT) / 10);
        uint256 sz = depth == 0 ? uint256(UNIT) : (ethSide * 20 * uint256(UNIT)) / depth;
        x[4] = int256(sz > uint256(UNIT) ? uint256(UNIT) : sz);
        x[5] = buy ? UNIT : -UNIT;
        x[6] = int256(volE6 > uint256(UNIT) ? uint256(UNIT) : volE6);
        uint256 since = block.timestamp - launchTime;
        x[7] = since < 1 days ? int256(uint256(UNIT) - (since * uint256(UNIT)) / 1 days) : int256(0);
    }

    /// @notice Freshness of tokens aged `age` seconds: +1e6 when brand new, falling with log2 of the age in
    ///         blocks (12 s), -1e6 from about 27 hours on.
    function ageFeature(uint256 age) public pure returns (int256) {
        uint256 b = age / 12 + 1;
        uint256 l;
        while (b > 1 && l < 13) {
            b >>= 1;
            ++l;
        }
        return UNIT - (2 * UNIT * int256(l)) / 13;
    }

    function _feeOf(bytes32[3] memory w, int256[8] memory x) internal pure returns (uint256) {
        int256 o = AgentNet.forward3(w[0], w[1], w[2], x);
        if (o <= 0) return FLOOR;
        return FLOOR + (uint256(o) * (CAP - FLOOR)) / uint256(UNIT);
    }

    function _depth(uint160 sp) internal view returns (uint256) {
        uint128 L = poolManager.getLiquidity(poolId);
        if (sp == 0) return 0;
        return FullMath.mulDiv(L, Q96, sp);
    }

    function _toEth(uint256 tokens, uint160 sp) internal pure returns (uint256) {
        if (sp == 0) return 0;
        return FullMath.mulDiv(FullMath.mulDiv(tokens, Q96, sp), Q96, sp);
    }

    function _observe(int24 tick, uint256 depth) internal {
        if (block.number != lastObsBlock) {
            int256 dt = int256(tick) - int256(lastTick);
            uint256 move = uint256(dt < 0 ? -dt : dt) * 1e4; // 100 ticks = 1e6
            volE6 = (volE6 * 98 + move * 2) / 100;
            lastTick = tick;
            lastObsBlock = uint64(block.number);
        }
        if (block.timestamp >= nextPathTime && pathLen < PATH) {
            path[pathLen] = Pt(tick, uint64(block.timestamp), uint128(depth));
            pathLen += 1;
            nextPathTime = uint64(block.timestamp + EPOCH / PATH);
        }
    }

    function _sample(int256[8] memory x, uint256 ethSide, uint256 age, bool buy, bool sandwich, bool same) internal {
        uint32 n = ++sampleCount;
        uint256 idx;
        if (n <= SAMPLES) {
            idx = n - 1;
        } else {
            uint256 r = uint256(keccak256(abi.encode(block.prevrandao, n, epoch))) % n;
            if (r >= SAMPLES) return;
            idx = r;
        }
        samples[idx] = Sample(_pack(x), uint96(ethSide), uint40(age > type(uint40).max ? type(uint40).max : age), buy, sandwich, same);
    }

    function _victim(uint256 ethSide, uint256 depth) internal {
        uint32 n = ++victimCount;
        uint256 idx;
        if (n <= VICTIMS) {
            idx = n - 1;
        } else {
            uint256 r = uint256(keccak256(abi.encode(block.prevrandao, n, epoch, "v"))) % n;
            if (r >= VICTIMS) return;
            idx = r;
        }
        victims[idx] = Victim(uint128(ethSide), uint128(depth));
    }

    function _pack(int256[8] memory x) internal pure returns (bytes32 w) {
        for (uint256 i; i < 8; ++i) w |= bytes32(uint256(uint32(int32(x[i]))) << (i * 32));
    }

    function _unpack(bytes32 w) internal pure returns (int256[8] memory x) {
        for (uint256 i; i < 8; ++i) x[i] = int256(int32(uint32(uint256(w) >> (i * 32))));
    }

    function _book(uint256 fee) internal {
        uint256 h = (fee * TO_HOLDERS) / 10_000;
        uint256 sd = (fee * TO_SIDE) / 10_000;
        uint256 b = (fee * TO_BURN) / 10_000;
        holderBook += h;
        sideBook += sd;
        burnBook += b;
        keeperBook += fee - h - sd - b;
        feesAll += fee;
    }

    /// @dev Side backing rides inside an exact-in buy (hookData = abi.encode(uint8 side)); any sell drops the
    ///      seller's weight for the running epoch.
    function _side(bool buy, bool exactIn, uint256 amt, bytes calldata hookData) internal {
        address who = tx.origin;
        if (buy) {
            if (!exactIn || hookData.length < 32) return;
            uint256 side = uint256(bytes32(hookData[:32]));
            if (side != 1 && side != 2) return;
            uint256 cur = backing[epoch][who];
            uint256 have = cur >> 248;
            if (have != 0 && have != side) return; // one side per wallet per epoch
            uint256 eth = (cur & ((1 << 248) - 1)) + amt;
            backing[epoch][who] = (side << 248) | eth;
            sideTotal[epoch][side] += amt;
            emit Backed(epoch, who, uint8(side), amt);
        } else {
            uint256 cur = backing[epoch][who];
            if (cur == 0) return;
            sideTotal[epoch][cur >> 248] -= cur & ((1 << 248) - 1);
            backing[epoch][who] = 0;
        }
    }

    // ═══════════════════════════════════════════════════════════════ the duel

    /// @notice Step 1 after the epoch ends: every Shadow plays the recorded epoch against the champion.
    function scoreShadows() external {
        if (!live || block.timestamp < epochEnd) revert TooSoon();
        if (shadowsScored) revert OutOfOrder();
        bytes32[3] memory cw = guards[champ];
        int256 best = type(int256).min;
        for (uint256 i; i < S; ++i) {
            uint256 plan = _plan(shadows[i]);
            shadowPlan[i] = plan;
            int256 v = _paper(plan, cw);
            shadowPnl[i] = v;
            if (v > best) best = v;
        }
        shadowsScored = true;
        emit ShadowsScored(epoch, best);
        _pay(msg.sender);
    }

    /// @notice Step 2, once per Guard: its score on the recorded epoch.
    function scoreGuard(uint256 g) external {
        if (!shadowsScored || g >= G || (guardsScoredMask >> g) & 1 == 1) revert OutOfOrder();
        bytes32[3] memory w = guards[g];
        int256 sc;
        for (uint256 i; i < SAMPLES && i < sampleCount; ++i) {
            Sample memory sm = samples[i];
            uint256 extra = (_feeOf(w, _unpack(sm.x)) - FLOOR) * uint256(sm.ethSide) / PIPS;
            bool flip = sm.sandwich || sm.same || (!sm.buy && sm.age < FLIP_AGE);
            if (flip) sc += int256(extra);
            else sc -= LAMBDA * int256(extra);
        }
        int256 worst;
        for (uint256 i; i < S; ++i) {
            int256 v = _paper(shadowPlan[i], w);
            if (v > worst) worst = v;
        }
        sc -= worst;
        guardScore[g] = sc;
        guardsScoredMask |= 1 << g;
        emit GuardScored(epoch, g, sc);
        _pay(msg.sender);
    }

    /// @notice Step 3: replace the weakest on each side with a mutated copy of the strongest, crown the champion,
    ///         settle the side pot, open the next epoch.
    function evolve() external {
        if (guardsScoredMask != (1 << G) - 1) revert OutOfOrder();
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), epoch)));
        // guards
        uint256 gb;
        uint256 gw;
        for (uint256 i = 1; i < G; ++i) {
            if (guardScore[i] > guardScore[gb]) gb = i;
            if (guardScore[i] < guardScore[gw]) gw = i;
        }
        // shadows (scored against the champion of this epoch)
        uint256 sb;
        uint256 sw;
        int256 bestShadow = shadowPnl[0];
        for (uint256 i = 1; i < S; ++i) {
            if (shadowPnl[i] > shadowPnl[sb]) sb = i;
            if (shadowPnl[i] < shadowPnl[sw]) sw = i;
            if (shadowPnl[i] > bestShadow) bestShadow = shadowPnl[i];
        }
        uint8 win = bestShadow > 0 ? 2 : 1;
        if (gw != gb) guards[gw] = _mutate(guards[gb], seed);
        if (sw != sb) shadows[sw] = _mutate(shadows[sb], seed >> 1);
        champ = uint8(gb);

        // the side pot
        uint256 e = epoch;
        uint256 pot = sideBook;
        sideBook = 0;
        if (sideTotal[e][win] == 0) {
            sideBook = pot; // nobody on the winning side: roll over
            pot = 0;
        }
        sidePot[e] = pot;
        winner[e] = win;
        emit Evolved(e, champ, win, pot);

        // next epoch
        epoch = e + 1;
        epochEnd = block.timestamp + EPOCH;
        pathLen = 0;
        nextPathTime = uint64(block.timestamp);
        sampleCount = 0;
        victimCount = 0;
        shadowsScored = false;
        guardsScoredMask = 0;
        _pay(msg.sender);
    }

    /// @notice Claim your share of a settled epoch's side pot.
    function claimSide(uint256 e) external returns (uint256 amt) {
        uint8 win = winner[e];
        if (win == 0) revert TooSoon();
        uint256 cur = backing[e][msg.sender];
        if (cur >> 248 != win) revert Nothing();
        backing[e][msg.sender] = 0;
        amt = (sidePot[e] * (cur & ((1 << 248) - 1))) / sideTotal[e][win];
        if (amt == 0) revert Nothing();
        poolManager.unlock(abi.encode(PAY, abi.encode(msg.sender, amt)));
        emit SideClaimed(e, msg.sender, amt);
    }

    /// @dev A Shadow's decisions on the recorded epoch: bit i = toggle in/out of a position at path point i;
    ///      bit 128 + j = sandwich recorded victim j. Decisions do not depend on any Guard, so they are taken once.
    function _plan(bytes32[3] memory w) internal view returns (uint256 plan) {
        uint256 n = pathLen;
        bool pos;
        uint64 entered;
        int256 vol = int256(volE6 > uint256(UNIT) ? uint256(UNIT) : volE6);
        for (uint256 i = 1; i < n; ++i) {
            Pt memory pt = path[i];
            int256 mom = (int256(path[i - 1].tick) - int256(pt.tick)) * 1e4; // price of DUEL up when tick falls
            if (mom > UNIT) mom = UNIT;
            if (mom < -UNIT) mom = -UNIT;
            uint256 held = pos ? pt.time - entered : 0;
            int256[8] memory x;
            x[0] = mom;
            x[1] = pos ? UNIT : -UNIT;
            x[2] = int256((held > 6 hours ? 6 hours : held) * uint256(UNIT) / 6 hours);
            x[3] = vol;
            x[7] = int256(i * uint256(UNIT) / PATH);
            int256 a = AgentNet.forward3(w[0], w[1], w[2], x);
            if (!pos && a > UNIT / 4) {
                pos = true;
                entered = pt.time;
                plan |= 1 << i;
            } else if (pos && a < -UNIT / 4) {
                pos = false;
                plan |= 1 << i;
            }
        }
        uint256 m = victimCount < VICTIMS ? victimCount : VICTIMS;
        for (uint256 j; j < m; ++j) {
            Victim memory v = victims[j];
            if (v.depth == 0) continue;
            int256[8] memory x;
            uint256 sz = (uint256(v.ethSide) * 20 * uint256(UNIT)) / v.depth;
            x[4] = int256(sz > uint256(UNIT) ? uint256(UNIT) : sz);
            x[5] = UNIT;
            x[6] = vol;
            if (AgentNet.forward3(w[0], w[1], w[2], x) > UNIT / 4) plan |= 1 << (128 + j);
        }
    }

    /// @dev Paper profit, in wei, of a Shadow's plan against Guard `gw`. Path trades: SHADOW_SIZE notional each,
    ///      buy at FLOOR, sell at the Guard's young-token fee (or FLOOR from 6 hours), plus the LP fee each way.
    ///      Sandwiches: constant-product legs at the recorded depth, the back-run priced by the Guard.
    function _paper(uint256 plan, bytes32[3] memory gw) internal view returns (int256 pnl) {
        uint256 n = pathLen;
        bool pos;
        uint256 entry;
        for (uint256 i = 1; i < n; ++i) {
            if ((plan >> i) & 1 == 0) continue;
            if (!pos) {
                pos = true;
                entry = i;
            } else {
                pos = false;
                pnl += _pathTrade(path[entry], path[i], gw);
            }
        }
        uint256 m = victimCount < VICTIMS ? victimCount : VICTIMS;
        for (uint256 j; j < m; ++j) {
            if ((plan >> (128 + j)) & 1 == 0) continue;
            pnl += _sandwich(victims[j], gw);
        }
    }

    function _pathTrade(Pt memory a, Pt memory b, bytes32[3] memory gw) internal view returns (int256) {
        uint256 age = b.time - a.time;
        uint256 sellFee = FLOOR;
        if (age < HOLDER_AGE) {
            int256[8] memory x = _features(false, age, false, false, 1, SHADOW_SIZE, b.depth);
            x[7] = 0;
            sellFee = _feeOf(gw, x);
        }
        uint160 sa = TickMath.getSqrtPriceAtTick(a.tick);
        uint160 sb = TickMath.getSqrtPriceAtTick(b.tick);
        // ETH back per ETH in, before fees: (sqrtA / sqrtB)^2
        uint256 r = FullMath.mulDiv(FullMath.mulDiv(SHADOW_SIZE, sa, sb), sa, sb);
        r = (r * (PIPS - FLOOR - LP_FEE)) / PIPS;
        r = (r * (PIPS - sellFee - LP_FEE)) / PIPS;
        return int256(r) - int256(SHADOW_SIZE);
    }

    function _sandwich(Victim memory v, bytes32[3] memory gw) internal view returns (int256) {
        uint256 E = v.depth;
        uint256 T = v.depth; // tokens counted in ETH at the opening price of the block: only ratios matter
        uint256 f = v.ethSide; // front-run the size of the victim
        uint256 inF = (f * (PIPS - FLOOR - LP_FEE)) / PIPS;
        uint256 outF = T - (E * T) / (E + inF);
        E += inF;
        T -= outF;
        uint256 inV = (uint256(v.ethSide) * (PIPS - FLOOR - LP_FEE)) / PIPS;
        uint256 outV = T - (E * T) / (E + inV);
        E += inV;
        T -= outV;
        uint256 gross = E - (E * T) / (T + outF);
        int256[8] memory x = _features(false, 0, true, true, 2, gross, E);
        x[7] = 0;
        uint256 fee = _feeOf(gw, x);
        // the fixed back-run minimum: the price gain since the front-run began (price per token went from 1 to E/T)
        uint256 gain = (E * PIPS) / T;
        uint256 fr = gain > PIPS ? gain - PIPS + FLOOR : FLOOR;
        if (fr > BACKRUN_MAX) fr = BACKRUN_MAX;
        if (fr > fee) fee = fr;
        uint256 keep = fee + LP_FEE >= PIPS ? 0 : PIPS - fee - LP_FEE;
        uint256 net = (gross * keep) / PIPS;
        return int256(net) - int256(f);
    }

    function _mutate(bytes32[3] memory w, uint256 seed) internal pure returns (bytes32[3] memory c) {
        c = w;
        for (uint256 k; k < 91; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            if (r % 12 != 0) continue;
            uint256 word = k / 32;
            uint256 sh = (31 - (k % 32)) * 8;
            int256 v = int256(int8(uint8(uint256(c[word]) >> sh)));
            v += int256((r >> 8) % 49) - 24;
            if (v > 127) v = 127;
            if (v < -128) v = -128;
            uint256 cleared = uint256(c[word]) & ~(uint256(0xff) << sh);
            c[word] = bytes32(cleared | (uint256(uint8(int8(v))) << sh));
        }
    }

    function _random(uint256 seed) internal pure returns (bytes32[3] memory c) {
        for (uint256 k; k < 91; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            int256 v = int256(r % 97) - 48;
            uint256 word = k / 32;
            uint256 sh = (31 - (k % 32)) * 8;
            c[word] = bytes32(uint256(c[word]) | (uint256(uint8(int8(v))) << sh));
        }
    }

    function _pay(address to) internal {
        uint256 r = STEP_PAY;
        uint256 cap = keeperBook / 4;
        if (r > cap) r = cap;
        if (r == 0) return;
        keeperBook -= r;
        poolManager.unlock(abi.encode(PAY, abi.encode(to, r)));
    }

    // ═══════════════════════════════════════════════════════════════ money out

    /// @notice Send the holders' book to the token, where it accrues per token and vests by age. Anyone may call.
    function flush() external {
        uint256 amt = holderBook;
        if (amt == 0) revert Nothing();
        holderBook = 0;
        poolManager.unlock(abi.encode(NOTIFY, abi.encode(amt)));
        emit Flushed(amt);
    }

    /// @notice Spend the burn book on DUEL from the pool and burn it. At most once an hour, at most 1% of the pool's
    ///         ETH depth per call, never pushing the price more than 0.5% past spot. Anyone may call.
    function buyback() external {
        if (block.timestamp < lastBuyback + BUYBACK_GAP) revert TooSoon();
        (uint160 sp, int24 spot,,) = poolManager.getSlot0(poolId);
        uint256 spend = (burnBook * (PIPS - PLATFORM_FEE)) / PIPS; // gross (spend + its fee) stays within the book
        spend = spend > 2 ? spend - 2 : 0; // the fee rounds up: two wei of room
        uint256 cap = _depth(sp) / 100;
        if (spend > cap) spend = cap;
        if (spend == 0) revert Nothing();
        lastBuyback = block.timestamp;
        uint256 spent = abi.decode(
            poolManager.unlock(abi.encode(BUYBACK, abi.encode(spend, TickMath.getSqrtPriceAtTick(spot - BUYBACK_BAND)))),
            (uint256)
        );
        burnBook -= spent;
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (uint8 op, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (op == PAY) {
            (address to, uint256 amount) = abi.decode(args, (address, uint256));
            poolManager.burn(address(this), ETH.toId(), amount);
            poolManager.take(ETH, to, amount);
            return "";
        }
        if (op == NOTIFY) {
            uint256 amount = abi.decode(args, (uint256));
            poolManager.burn(address(this), ETH.toId(), amount);
            poolManager.take(ETH, address(this), amount);
            TOKEN.notify{value: amount}();
            return "";
        }
        if (op == BUYBACK) {
            (uint256 spend, uint160 limit) = abi.decode(args, (uint256, uint160));
            BalanceDelta dd = poolManager.swap(poolKey(), SwapParams(true, -int256(spend), limit), "");
            uint256 spent = uint256(-int256(dd.amount0()));
            poolManager.burn(address(this), ETH.toId(), spent);
            // the hook's own swap skips the hook callbacks, so its platform fee is paid here, from the burn book:
            // gross = spent + pf with pf = ceil(gross x 0.30%), the fixed point of that equation (two steps reach it)
            uint256 pf = FullMath.mulDivRoundingUp(spent, PLATFORM_FEE, PIPS - PLATFORM_FEE);
            for (uint256 i; i < 3; ++i) {
                uint256 n = FullMath.mulDivRoundingUp(spent + pf, PLATFORM_FEE, PIPS);
                if (n == pf) break;
                pf = n;
            }
            poolManager.transfer(address(feeVault), ETH.toId(), pf);
            _platform(pf);
            spent += pf;
            uint256 got = uint256(int256(dd.amount1()));
            poolManager.take(Currency.wrap(address(TOKEN)), address(this), got);
            TOKEN.burn(got);
            burned += got;
            emit BoughtBack(spent, got);
            return abi.encode(spent);
        }
        revert();
    }

    receive() external payable {}
}
