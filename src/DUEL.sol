// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// ================================================================================================
//  site: https://duelis.tech   x: https://x.com/DuelisAI
//  DUELIS . $DUEL . BOUT SHEET No. 1 . THE PURSE
// ================================================================================================
//
//  ENTRANT
//      Duelis ($DUEL): 1,000,000,000 units, minted once to the seeder (DuelSeeder), which places all of
//      them in the pool in the launch transaction. The seeder names the hook once (bindHook) before
//      that; nothing can change it after. No owner function, no mint after construction, no pause, no
//      fee in the token itself.
//
//  RULES
//      Every balance carries an age: the balance-weighted time its tokens were acquired. Tokens that
//      leave the pool (a buy) are age zero. Tokens sent wallet to wallet carry their age with them,
//      so a fresh address cannot make young tokens look old.
//
//      The hook sends holders' ETH here (notify). It accrues per token held, over the eligible supply:
//      every balance except the pool manager, the hook, this contract and the burn address. What a
//      holder can keep vests with the age of their tokens, linearly to AGE_FULL (14 days). When
//      tokens leave a balance, the unvested part of that balance's accrued ETH, in proportion to the
//      tokens leaving, is handed back to the remaining holders. claim() pays the vested part and hands
//      back the rest.
//
//      While the eligible supply is under MIN_DENOM (1% of supply), ETH is shared as if MIN_DENOM were
//      held, and the part belonging to the missing supply waits in `carry` for later holders. The
//      first buyer after launch cannot take the launch fees alone.
//
//  SCORING (what is checked)
//      test/DUEL.t.sol: supply only falls; ETH paid out never exceeds ETH notified; age travels;
//      a wallet cannot claim more than its vested share.
//
//  FOULS (refused)
//      transfer of more than a balance; transferFrom past an allowance.
//
//  OFF THE CARD
//      Accrual rounds down for holders (debts round up), so a few wei per account stay in the
//      contract. Rewards are ETH only. A contract wallet holds its own age like any address; the hook
//      reads the age of the wallet that signs the trade (tx.origin), not of a contract in between.
// ------------------------------------------------------------------------------------------------

contract DUEL {
    string public constant name = "Duelis";
    string public constant symbol = "DUEL";
    uint8 public constant decimals = 18;
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    uint256 public constant AGE_FULL = 14 days;
    uint256 public constant MIN_DENOM = SUPPLY / 100;
    uint256 internal constant ACC = 1e36;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public HOOK; // named once by BINDER, in the launch transaction
    address public immutable POOL_MANAGER;
    address public immutable BINDER; // the seeder: the only address that may name the hook, once

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice balance-weighted acquisition time of each address's tokens
    mapping(address => uint64) public acquiredAt;

    struct Acct {
        uint256 debt; // accPerToken x balance at the last settlement, rounded up
        uint256 credit; // ETH accrued and not yet claimed
    }

    mapping(address => Acct) public accts;
    uint256 public accPerToken;
    uint256 public eligibleSupply;
    uint256 public carry; // ETH waiting for eligible supply
    uint256 public notified; // ETH received for holders, all time
    uint256 public paid; // ETH paid to holders, all time

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Notified(uint256 eth, uint256 accPerToken);
    event Claimed(address indexed holder, uint256 paid, uint256 handedBack);

    error Insufficient();
    error PayFailed();
    error NotBinder();

    /// @param poolManager Uniswap's PoolManager
    /// @param seeder      receives the whole supply and names the hook once
    constructor(address poolManager, address seeder) {
        POOL_MANAGER = poolManager;
        BINDER = seeder;
        totalSupply = SUPPLY;
        balanceOf[seeder] = SUPPLY;
        acquiredAt[seeder] = uint64(block.timestamp);
        eligibleSupply = SUPPLY;
        emit Transfer(address(0), seeder, SUPPLY);
    }

    /// @notice The hook, named once by the seeder in the launch transaction. The hook and this token cannot name
    ///         each other in their constructors: each address is derived from the other's creation code.
    function bindHook(address hook) external {
        if (msg.sender != BINDER || HOOK != address(0) || hook == address(0)) revert NotBinder();
        HOOK = hook;
    }

    // ───────────────────────────────────────────────────────────── ERC-20

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            if (a < value) revert Insufficient();
            unchecked {
                allowance[from][msg.sender] = a - value;
            }
        }
        _move(from, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    /// @notice Burn your own tokens. Supply falls.
    function burn(uint256 value) external {
        address from = msg.sender;
        uint256 b = balanceOf[from];
        if (b < value) revert Insufficient();
        bool el = _eligible(from);
        if (el) _settle(from);
        uint256 back = el ? _handBack(from, value, b) : 0;
        unchecked {
            balanceOf[from] = b - value;
            totalSupply -= value;
        }
        if (el) {
            eligibleSupply -= value;
            _checkpoint(from);
        }
        if (back != 0) _share(back);
        emit Transfer(from, address(0), value);
    }

    // ───────────────────────────────────────────────────────────── holders' ETH

    /// @notice Add ETH for holders. The hook calls this; anyone may.
    function notify() external payable {
        notified += msg.value;
        _share(msg.value);
    }

    /// @notice Pay the vested part of your accrued ETH; the unvested part goes back to the other holders.
    function claim() external returns (uint256 pay) {
        address a = msg.sender;
        if (_eligible(a)) _settle(a);
        Acct storage s = accts[a];
        uint256 c = s.credit;
        if (c == 0) return 0;
        pay = (c * vested(a)) / 1e18;
        uint256 back = c - pay;
        s.credit = 0;
        if (_eligible(a)) _checkpoint(a);
        if (back != 0) _share(back);
        paid += pay;
        emit Claimed(a, pay, back);
        if (pay != 0) {
            (bool ok,) = a.call{value: pay}("");
            if (!ok) revert PayFailed();
        }
    }

    /// @notice Seconds since the balance-weighted acquisition of `a`'s tokens; zero for an empty balance.
    function ageOf(address a) public view returns (uint256) {
        if (balanceOf[a] == 0) return 0;
        return block.timestamp - acquiredAt[a];
    }

    /// @notice The share of accrued ETH `a` could keep now, 1e18 = all.
    function vested(address a) public view returns (uint256) {
        uint256 age = ageOf(a);
        return age >= AGE_FULL ? 1e18 : (age * 1e18) / AGE_FULL;
    }

    /// @notice Accrued ETH (before vesting) and the part `a` could claim right now.
    function pending(address a) external view returns (uint256 accrued, uint256 claimable) {
        accrued = accts[a].credit;
        if (_eligible(a)) {
            uint256 earned = (balanceOf[a] * accPerToken) / ACC;
            uint256 d = accts[a].debt;
            if (earned > d) accrued += earned - d;
        }
        claimable = (accrued * vested(a)) / 1e18;
    }

    // ───────────────────────────────────────────────────────────── internals

    function _eligible(address a) internal view returns (bool) {
        return a != POOL_MANAGER && a != HOOK && a != address(this) && a != DEAD && a != address(0);
    }

    function _move(address from, address to, uint256 value) internal {
        uint256 bf = balanceOf[from];
        if (bf < value) revert Insufficient();
        bool ef = _eligible(from);
        bool et = _eligible(to);
        if (ef) _settle(from);
        if (et) _settle(to);
        uint256 back = ef && from != to ? _handBack(from, value, bf) : 0;

        // age: tokens out of the pool are new; wallet-to-wallet tokens keep the sender's age
        uint256 bt = balanceOf[to];
        if (from != to && value != 0) {
            uint256 src = from == POOL_MANAGER ? block.timestamp : (bf == 0 ? block.timestamp : acquiredAt[from]);
            uint256 cur = bt == 0 ? src : acquiredAt[to];
            acquiredAt[to] = uint64((bt * cur + value * src) / (bt + value));
        }
        unchecked {
            balanceOf[from] = bf - value;
        }
        balanceOf[to] += value;
        if (ef && !et) eligibleSupply -= value;
        else if (!ef && et) eligibleSupply += value;
        if (ef) _checkpoint(from);
        if (et) _checkpoint(to);
        if (back != 0) _share(back);
        emit Transfer(from, to, value);
    }

    /// @dev Moves earned ETH into credit; call before a balance changes.
    function _settle(address a) internal {
        Acct storage s = accts[a];
        uint256 earned = (balanceOf[a] * accPerToken) / ACC;
        if (earned > s.debt) s.credit += earned - s.debt;
        s.debt = earned; // re-set exactly in _checkpoint after the balance change
    }

    /// @dev Rounds the debt up so the sum of claims never passes what was notified.
    function _checkpoint(address a) internal {
        uint256 x = balanceOf[a] * accPerToken;
        accts[a].debt = x / ACC + (x % ACC == 0 ? 0 : 1);
    }

    /// @dev The unvested part of `a`'s credit that leaves with `value` of its `bal` tokens.
    function _handBack(address a, uint256 value, uint256 bal) internal returns (uint256 back) {
        Acct storage s = accts[a];
        uint256 c = s.credit;
        if (c == 0 || bal == 0) return 0;
        uint256 leaving = (c * value) / bal;
        back = (leaving * (1e18 - vested(a))) / 1e18;
        s.credit = c - back;
    }

    /// @dev Spread `eth` (plus carry) over the eligible supply, as if at least MIN_DENOM were held.
    function _share(uint256 eth) internal {
        uint256 total = eth + carry;
        uint256 el = eligibleSupply;
        if (el == 0) {
            carry = total;
            return;
        }
        uint256 denom = el > MIN_DENOM ? el : MIN_DENOM;
        uint256 inc = (total * ACC) / denom;
        uint256 assigned = (inc * el) / ACC;
        accPerToken += inc;
        carry = total - assigned;
        emit Notified(eth, accPerToken);
    }

    receive() external payable {
        notified += msg.value;
        _share(msg.value);
    }
}
