# Ritual Predict — Bootcamp 2 Proof of Building

A self-resolving binary prediction market on Ritual Chain. This repository is a **direct fork of the official Bootcamp 2 workshop** and keeps the required `ritual-chain-workshop-2` repository name and fork lineage.

## What I built

I completed the unfinished workshop paths in `RitualPredict.sol` and extended the reference implementation with frontend-friendly market analytics and a dedicated local test suite.

### Core implementation completed

- `createMarket` validates the resolution rule, converts human durations into block deadlines, stores immutable market parameters and schedules autonomous resolution.
- `onScheduledResolve` authorizes the Ritual Scheduler, selects a TEE executor, reads the oracle, applies the configured comparator and finalizes the market.
- `_readOracle` uses Ritual's HTTP precompile and jq precompile, with explicit handling for executor, HTTP, envelope and parsing failures.
- `_pickExecutor` uses the TEE Service Registry instead of hardcoding an executor.
- `_scheduleResolution` books three resolution attempts, 200 blocks apart, and successful/terminal markets cancel the remaining schedule.
- Oracle failure is never interpreted as a NO outcome. After the final failed attempt the market becomes invalid and bettors can reclaim their original stake.

### My extensions

1. **Implied market odds** — `impliedOdds(marketId)` returns YES/NO pool probabilities in basis points. A 3 RITUAL YES pool and 1 RITUAL NO pool reads as 75% / 25%.
2. **Pre-bet payout quotes** — `potentialPayout(...)` lets a frontend show the user's hypothetical pari-mutuel payout before submitting a transaction.
3. **Resolution-rule preview** — `previewOutcome(...)` makes GT/GTE/LT/LTE behavior directly inspectable and easy to test.
4. **Local Hardhat path** — Ritual system contracts do not exist on chain id 31337, so local market creation uses a deterministic placeholder schedule id while preserving the real Scheduler path on Ritual Chain.
5. **Behavior-focused tests** — `hardhat/test/RitualPredict.ts` covers market creation, immutable rule storage, YES/NO pools, implied odds, payout quoting, all four comparator rules, invalid input, zero-value bets and block-number betting deadlines.

## How the market resolves

```text
createMarket()
      |
      v
Ritual Scheduler books 3 calls
      |
      v
resolveBlock reached
      |
      v
TEE Service Registry -> HTTP-capable executor
      |
      v
HTTP precompile (0x0801) -> configured oracle URL
      |
      v
jq precompile (0x0803) -> uint256 observed value
      |
      v
observed value vs target + comparator
      |
      +---- YES/NO has liquidity ---> Resolved -> winners claim
      |
      +---- winning side empty ------> Invalid -> everyone refunds
      |
      +---- oracle read fails -------> retry (max 3) -> Invalid/refund
```

There is no privileged human resolver and no backend cron job deciding the result.

## Key design decisions

**Block-number deadlines.** Betting closes at `closeBlock` and the Scheduler wakes the contract at `resolveBlock`, so the two lifecycle rules use the same clock.

**Immutable resolution rules.** `oracleUrl`, `jsonPath`, `target`, `comparator` and resolution blocks are fixed when the market is created. `ResolutionRuleSet` leaves an auditable creation-time record.

**Failure is distinct from NO.** A missing TEE executor, reverted HTTP precompile, malformed async response, non-200 response, empty body or jq failure consumes a resolution attempt rather than deciding the prediction incorrectly.

**Pull-based settlement.** Winners claim their own proportional share using `stake × totalPool / winningPool`; the contract never loops over all bettors. Invalid markets use the same pull pattern for refunds.

## Run locally

```bash
cd hardhat
pnpm install
npx hardhat compile
npx hardhat test test/RitualPredict.ts
```

To run a persistent local node:

```bash
npx hardhat node
```

The local test path deliberately avoids pretending that Ritual's Scheduler/TEE/HTTP system contracts exist on Hardhat. The actual autonomous resolution path remains enabled on Ritual Chain.

## Ritual Chain setup

```bash
cd hardhat
cp .env.example .env
```

Add the required wallet configuration from `.env.example`, fund it with testnet RITUAL, measure/check block time with the supplied script, deploy, and fund the contract's RitualWallet execution balance before creating live markets.

## Files changed for Proof of Building

- `hardhat/contracts/RitualPredict.sol` — completed contract + odds/payout/preview extensions + local development path.
- `hardhat/test/RitualPredict.ts` — dedicated prediction-market tests.
- `README.md` — implementation notes, architecture, extensions and reproduction instructions.

## What I learned

The important part of a self-resolving prediction market is not merely fetching a number. Resolution needs a deterministic lifecycle and a safe failure model. In particular, an unavailable oracle cannot be treated as a false prediction. Ritual's Scheduler + TEE execution + HTTP/jq precompiles let the resolution rule live with the market itself while retries and refunds provide a clean terminal state when external data cannot be obtained.

## References

- Ritual Chain documentation: https://docs.ritualfoundation.org
- Ritual dApp skills: https://github.com/ritual-foundation/ritual-dapp-skills
- Ritual explorer: https://explorer.ritualfoundation.org
- Ritual faucet: https://faucet.ritualfoundation.org
- Upstream workshop: https://github.com/cozfuttu/ritual-chain-workshop-2
