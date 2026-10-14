# Duelis ($DUEL) contracts

Site: https://duelis.tech · X: https://x.com/DuelisAI

A token made by AI to fight AI: a Uniswap v4 hook on Ethereum mainnet in which six on-chain Guard networks price
bot-like trades and four Shadow networks paper-trade against them, evolving once a day. Launched through
Programmable's Custom Launch (https://programmable.market).

## Contracts

| File | Role |
|---|---|
| `src/DUEL.sol` | The token. 1,000,000,000 DUEL minted once to the seeder. Token age and ETH dividends that vest by age. No owner function, no further mint, no pause, no tax in the token. |
| `src/DuelHook.sol` | The hook (permission flags `0x10CC`). The fee, the Guards and Shadows, the daily duel, the purse. No owner function, no upgrade. |
| `src/DuelSeeder.sol` | The launch initializer. In the launch transaction it names the hook in the token, opens the ETH/DUEL pool at about 1 ETH FDV, puts the whole supply in as one position, mints the LP NFT straight to the locker, then makes the first buy (0.05 ETH, at least 40,000,000 DUEL, to the owner). Callable once. |
| `src/DuelLocker.sol` | Permanent custody of the LP NFT. Its only function, `collect(tokenId)`, removes zero liquidity and sends the LP fees to the owner. No withdrawal, no NFT transfer or approval, no arbitrary call, no owner function. |
| `src/EthereumNativeFeeVaultV3.sol` | Programmable's fee vault, unmodified from programmablehq/PROGRAMMABLE (production, `packages/launch/contracts/ethereum-native30-v3`). The hook deploys it in its constructor (`feeVault`); it holds the platform fee as ETH claims and `claimPlatform()` pays only `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`. |
| `src/AgentNet.sol`, `src/base/BaseHook.sol` | The small int8 networks; the hook base. |
| `lib/` | Exact Uniswap v4-core and v4-periphery sources the build uses, unmodified. |

## Fees (on the ETH side of each swap)

- Buys, and sells of tokens held 6 hours or more: 1%.
- Bot-like trades (sells of tokens under 6 hours old, same-block repeats, sandwich back-runs): the champion Guard sets
  1% to 5%. A same-block back-run pays at least its own price gain plus 1%, up to 5%.
- Programmable platform fee: 0.30% of every swap's gross native value, enforced by the hook on every buy and sell,
  the launch's first buy and the hook's own buybacks included: ceil(gross x 0.30%) per trade, allocated first, the
  same accounting as Programmable's EthereumNative30HookV3. It accrues to `feeVault` and is paid only to
  `0xD88539d3c4C460136a733A3Fd60cf6BF269079da`. A swap that names its ETH amount must fill completely (a
  partial fill reverts, as in the canonical kernel), and a swap that moves no ETH is refused. On a buyback the fee
  is ceil(gross x 0.30%) with gross = the ETH swapped + the fee itself.
- Hook fee split: 55% holders, 20% the winning corner, 20% buyback and burn, 5% keepers.
- The pool's own LP fee: 1%, paid to the owner through the locker. The liquidity itself is locked forever.
- In total every trade pays: the hook fee (1%, up to 5% for bot-like trades) + the pool fee (1%) + the platform fee
  (0.30%), each once.

Stated plainly: with the 5% ceiling, a large enough sandwich can still profit. Measured on a pool about 6 ETH deep,
sandwiches around buys of 0.02 to 0.2 ETH lost money and those around buys of 0.5 ETH or more made money; the
threshold grows with the pool's depth.

## Build

Solidity `0.8.26+commit.8a97fa7a`, `viaIR: true`, optimizer 2000 runs, EVM `cancun`, metadata `bytecodeHash: none`.
Remappings: `v4-core/=lib/v4-core/`, `v4-periphery/=lib/v4-periphery/`.

## Licences

Duelis sources are MIT. Files under `lib/` keep their own SPDX headers; `lib/v4-core/src/libraries/Position.sol` is
Uniswap's BUSL-1.1.
