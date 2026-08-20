import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { network } from "hardhat";
import { parseEther } from "viem";

describe("RitualPredict local workshop extension", async function () {
  const { viem } = await network.create();
  const publicClient = await viem.getPublicClient();
  const [creator, alice, bob] = await viem.getWalletClients();

  async function deploy() {
    return viem.deployContract("RitualPredict", [1000n]);
  }

  const params = {
    question: "Will ETH be at least $4,000?",
    oracleUrl: "https://example.com/price.json",
    jsonPath: ".price",
    target: 4000n,
    comparator: 1,
    bettingSeconds: 30n,
    resolveDelaySeconds: 15n,
  } as const;

  it("creates a market locally and stores an immutable resolution rule", async () => {
    const market = await deploy();
    await market.write.createMarket([params], { account: creator.account });
    const created = await market.read.getMarket([1n]);
    assert.equal(created.id, 1n);
    assert.equal(created.creator.toLowerCase(), creator.account.address.toLowerCase());
    assert.equal(created.question, params.question);
    assert.equal(created.target, params.target);
    assert.equal(created.comparator, params.comparator);
  });

  it("tracks YES/NO pools and exposes pool-implied odds", async () => {
    const market = await deploy();
    await market.write.createMarket([params], { account: creator.account });
    await market.write.bet([1n, true], { account: alice.account, value: parseEther("3") });
    await market.write.bet([1n, false], { account: bob.account, value: parseEther("1") });
    const [yesBps, noBps] = await market.read.impliedOdds([1n]);
    assert.equal(yesBps, 7500n);
    assert.equal(noBps, 2500n);
  });

  it("quotes the pari-mutuel payout before a bet is submitted", async () => {
    const market = await deploy();
    await market.write.createMarket([params], { account: creator.account });
    await market.write.bet([1n, true], { account: alice.account, value: parseEther("1") });
    await market.write.bet([1n, false], { account: bob.account, value: parseEther("2") });
    const quote = await market.read.potentialPayout([1n, alice.account.address, true, parseEther("1")]);
    assert.equal(quote, parseEther("4"));
  });

  it("previews all comparator rules deterministically", async () => {
    const market = await deploy();
    assert.equal(await market.read.previewOutcome([11n, 10n, 0]), 1);
    assert.equal(await market.read.previewOutcome([10n, 10n, 1]), 1);
    assert.equal(await market.read.previewOutcome([10n, 10n, 2]), 2);
    assert.equal(await market.read.previewOutcome([10n, 10n, 3]), 1);
  });

  it("rejects empty rules, too-short windows and zero-value bets", async () => {
    const market = await deploy();
    await assert.rejects(market.write.createMarket([{ ...params, question: "" }], { account: creator.account }));
    await assert.rejects(market.write.createMarket([{ ...params, bettingSeconds: 1n }], { account: creator.account }));
    await market.write.createMarket([params], { account: creator.account });
    await assert.rejects(market.write.bet([1n, true], { account: alice.account, value: 0n }));
  });

  it("closes betting according to block number rather than timestamp", async () => {
    const market = await deploy();
    await market.write.createMarket([params], { account: creator.account });
    const created = await market.read.getMarket([1n]);
    const closeBlock = created.closeBlock;
    while ((await publicClient.getBlockNumber()) < closeBlock) {
      await publicClient.request({ method: "hardhat_mine", params: ["0x1"] });
    }
    const closed = await market.read.getMarket([1n]);
    assert.equal(closed.state, 1);
    await assert.rejects(market.write.bet([1n, true], { account: alice.account, value: parseEther("1") }));
  });
});
