const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const { BigNumber } = ethers;

describe("Option Perp", function() {
  let signers;
  let owner;

  let usdc;
  let weth;
  let priceOracle;
  let volatilityOracle;
  let optionPricing;
  let quoteLpPositionMinter;
  let baseLpPositionMinter;
  let perpPositionMinter;
  let optionPositionMinter;
  let optionPerp;
  let b50;
  let bf5;

  const MAX_UINT =
    "115792089237316195423570985008687907853269984665640564039457584007913129639935";
  const oneWeek = 7 * 24 * 60 * 60;

  const toEther = val =>
    BigNumber.from(10)
      .pow(18)
      .mul(val);

  const toDecimals = (val, decimals) =>
    BigNumber.from(10)
      .pow(decimals)
      .mul(val);

  const getTime = () => Math.floor(new Date().getTime() / 1000);

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
    user3 = signers[4];
  });

  it("should deploy option perp", async function() {
    // USDC
    usdc = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8");
    // WETH
    weth = await ethers.getContractAt("contracts/interface/IERC20.sol:IERC20", "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1");
    // Price oracle
    const PriceOracle = await ethers.getContractFactory("MockPriceOracle");
    priceOracle = await PriceOracle.deploy();
    // Volatility oracle
    const VolatilityOracle = await ethers.getContractFactory(
      "MockVolatilityOracle"
    );
    volatilityOracle = await VolatilityOracle.deploy();
    // Option pricing
    const OptionPricing = await ethers.getContractFactory("MockOptionPricing");
    optionPricing = await OptionPricing.deploy();
    // LP position minter
    const LPPositionMinter = await ethers.getContractFactory(
      "LpPositionMinter"
    );
    quoteLpPositionMinter = await LPPositionMinter.deploy("USDC", "DOPEX-USDC-O-P-LP", 6);
    baseLpPositionMinter = await LPPositionMinter.deploy("ETH", "DOPEX-ETH-O-P-LP", 18);
    // Perp position minter
    const PerpPositionMinter = await ethers.getContractFactory(
      "PerpPositionMinter"
    );
    perpPositionMinter = await PerpPositionMinter.deploy();
    // Option position minter
    const OptionPositionMinter = await ethers.getContractFactory(
      "OptionPositionMinter"
    );
    optionPositionMinter = await OptionPositionMinter.deploy();
    // Option Perp
    const OptionPerp = await ethers.getContractFactory("OptionPerp");
    optionPerp = await OptionPerp.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064", // GMX
      "0xa028B56261Bb1A692C06D993c383c872B51AfB33", // GMX HELPER
      quoteLpPositionMinter.address,
      baseLpPositionMinter.address,
      perpPositionMinter.address,
      optionPositionMinter.address,
      getTime() + oneWeek
    );
    console.log("deployed option perp:", optionPerp.address);
    await quoteLpPositionMinter.setOptionPerpContract(optionPerp.address);
    await baseLpPositionMinter.setOptionPerpContract(optionPerp.address);
    await perpPositionMinter.setOptionPerpContract(optionPerp.address);
    await optionPositionMinter.setOptionPerpContract(optionPerp.address);

    // Transfer USDC and WETH to our address from another impersonated address
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"],
    });

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: ["0x9bf54297d9270730192a83EF583fF703599D9F18"],
    });

    b50 = await ethers.provider.getSigner(
      "0xB50F58D50e30dFdAAD01B1C6bcC4Ccb0DB55db13"
    );

    bf5 = await ethers.provider.getSigner(
      "0x9bf54297d9270730192a83EF583fF703599D9F18"
    );

    await weth.connect(b50).transfer(user1.address, ethers.utils.parseEther("200.0"));
    await usdc.connect(bf5).transfer(user1.address, "100000000000");

    await b50.sendTransaction({
      to: user1.address,
      value: ethers.utils.parseEther("100.0")
    });
  });

  it("should not be able to deposit quote without sufficient usd balance", async () => {
    const amount = 10000 * 10 ** 6;
    await usdc.approve(optionPerp.address, MAX_UINT);
    await expect(
      optionPerp.deposit(true, amount)
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should deposit quote successfully", async () => {
    await usdc.connect(bf5).transfer(owner.address, "100000000000");

    const amount = 10000 * 10 ** 6;
    await usdc.approve(optionPerp.address, MAX_UINT);
    await optionPerp.deposit(true, amount);

    const deposited = await quoteLpPositionMinter.balanceOf(owner.address);

    expect(deposited.toString()).equals(amount.toString());
  });

  it("should not be able to deposit base without sufficient weth balance", async () => {
    const amount = 10 * 10 ** 6;
    await weth.approve(optionPerp.address, MAX_UINT);
    await expect(
      optionPerp.deposit(false, amount)
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should deposit base successfully", async () => {
    await weth.connect(b50).transfer(owner.address, ethers.utils.parseEther("200.0"));

    const amount = (10 * 10 ** 18).toString();
    await weth.connect(owner).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(owner).deposit(false, amount);

    const deposited = await baseLpPositionMinter.balanceOf(owner.address);

    expect(deposited.toString()).equals(amount.toString());

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10000000000"
    );
  });

  it("should not be able to open position if liquidity is insufficient", async () => {
    await expect(
      optionPerp.connect(user1).openPosition(false, toDecimals(100000, 8), toDecimals(500, 6))
    ).to.be.revertedWith("Not enough liquidity to open position");
  });

  it("should not be able to open position if user doesn't have enough funds", async () => {
    await expect(
      optionPerp.connect(user2)
        .openPosition(false, toDecimals(1000, 8), toDecimals(500, 8))
    ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
  });

  it("should not be able to open a long position successfully if size is too big for LPs", async () => {
    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq('100000000000');

    await usdc.connect(user1).approve(optionPerp.address, "100000000000000000000");

    await expect(optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(100000, 8), toDecimals(50000, 6))
    ).to.be.revertedWith("Not enough liquidity to open position");
  });

  it("should open a long position successfully", async () => {
    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq('100000000000');

    await usdc.connect(user1).approve(optionPerp.address, "100000000000000000000");

    await optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(1000, 8), toDecimals(500, 6));

    expect((await perpPositionMinter.positionsOfOwner(user1.address))[0]).to.eq(0);

    const { size } = await optionPerp.perpPositions(0);
    expect(size).equal(toDecimals(1000, 8));
    expect(await usdc.balanceOf(user1.address)).equals(
      startBalance.sub(toDecimals(500, 6))
    );

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10000000000" // TOTAL DEPOSITS DONT CHANGE
    );
  });

  it("should be able to close a long position with a profit", async () => {
    await priceOracle.updateUnderlyingPrice("150000000000");

    const estimatedPnl = await optionPerp._getPositionPnl(0);
    expect(estimatedPnl).to.eq('500000000');

    let amountOutAfterClosing = await optionPerp.connect(user1).callStatic.closePosition(0, 0);
    expect(amountOutAfterClosing).to.eq('993748245');

    await network.provider.send("evm_setNextBlockTimestamp", [1671240414]);
    await network.provider.send("evm_mine");

    // After hours we pay more funding
    amountOutAfterClosing = await optionPerp.connect(user1).callStatic.closePosition(0, 0);
    expect(amountOutAfterClosing).to.gte('989963711');

    await optionPerp.connect(user1).closePosition(0, 0);

    const endBalance = (await usdc.balanceOf(user1.address));

    // Initial balance was 100k
    expect(endBalance).to.eq('100489963711');

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10000000000" // TOTAL DEPOSITS DONT CHANGE
    );
  });

  it("should open multiple position (short, long) successfully", async () => {
    await priceOracle.updateUnderlyingPrice("100000000000");

    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq('100489963711');

    console.log('Open long');

    await optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(1000, 8), toDecimals(500, 6));

    console.log('Open short');

    await optionPerp
      .connect(user1)
      .openPosition(true, toDecimals(3000, 8), toDecimals(910, 6));

    // We open a long of $1000 with $500 of collateral (lev 2x)
    // We open a short of $3000 with $910 of collateral (lev 3.29x)

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10000000000" // TOTAL DEPOSITS DONT CHANGE
    );
  });

  it("liquidation price is computed correctly", async () => {
    await network.provider.send("evm_setNextBlockTimestamp", [1671250414]);
    await network.provider.send("evm_mine");

    // ETH GOES +29.2%
    await priceOracle.updateUnderlyingPrice("128400000000");

    const longPnl = await optionPerp._getPositionPnl(1);
    const shortPnl = await optionPerp._getPositionPnl(2);

    const longLiquidationPrice = await optionPerp._getPositionLiquidationPrice(1);
    expect(longLiquidationPrice).to.eq(53264877300); // ETH at $532

    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(2);
    expect(shortLiquidationPrice).to.eq(128512864400); // ETH at $1285

    expect(longPnl).to.eq(284000000); // $284
    expect(shortPnl).to.eq(-852000000); // -$852

    const obtainedClosingLong = await optionPerp.connect(user1).callStatic.closePosition(1, 0);
    expect(obtainedClosingLong).to.eq(775947240); // $775

    const obtainedClosingShort = await optionPerp.connect(user1).callStatic.closePosition(2, 0); // $1 from liquidationPrice
    expect(obtainedClosingShort).to.eq(48406244); // $48
  });

  it("add collateral to improve liquidation price", async () => {
    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq('99079963711');

    // Deposit $500 more
    await optionPerp.connect(user1).addCollateral(2, toDecimals(500, 6))

    const balance = (await usdc.balanceOf(user1.address));
    expect(balance).to.eq('98579963711');

    // Liquidation price for our short goes from $1285 to $1442
    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(2);
    expect(shortLiquidationPrice).to.eq(144285760566);

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10000000000" // TOTAL DEPOSITS DONT CHANGE
    );
  });

  it("partial close short position", async () => {
    // We close half of our $3000 position with ETH at $1284, and we leave only 800$ as collateral
    // Pnl resets to 0
    await optionPerp.connect(user1).changePositionSize(2, toDecimals(1500, 8), toDecimals(800, 6), 0);

    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(3);
    expect(shortLiquidationPrice).to.eq(192927421496); // ETH at $1929

    const shortPositionValue = await optionPerp._getPositionValue(3);
    expect(shortPositionValue).to.eq(1499999988); // $1500 of position value remaining

    const pnl = await optionPerp._getPositionPnl(3);
    expect(pnl).to.eq(12);

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10847001691" // TOTAL DEPOSITS CHANGE AS LP ACQUIRE -PNL FUNDING AND FEES
    );
  });

  it("it is possible to reduce collateral", async () => {
    // We reduce collateral of our position (too much)
    await expect(optionPerp.connect(user1).reduceCollateral(3, toDecimals(900, 6))).to.be.revertedWith("Amount to withdraw is too big");

    // We reduce collateral of a reasonable amount ($200)
    await optionPerp.connect(user1).reduceCollateral(3, toDecimals(200, 6));

    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(3);
    expect(shortLiquidationPrice).to.eq(176663533164); // Liquidation price decreases to $1766

    let pnl = await optionPerp._getPositionPnl(3);
    expect(pnl).to.eq(12); // PnL does not change

    let shortPositionValue = await optionPerp._getPositionValue(3);
    expect(shortPositionValue).to.eq(1499999988); // Position value does not change

    await priceOracle.updateUnderlyingPrice("150000000000");

    pnl = await optionPerp._getPositionPnl(3);
    expect(pnl).to.eq(-252336435); // PnL goes to -$252

    shortPositionValue = await optionPerp._getPositionValue(3);
    expect(shortPositionValue).to.eq(1752336435); // Position value increases

    expect((await optionPerp.epochData(true)).totalDeposits).equals(
      "10847001691" // TOTAL DEPOSITS CHANGE AS LP ACQUIRE -PNL FUNDING AND FEES
    );
  });

  it("another user should be able to deposit", async () => {
    await priceOracle.updateUnderlyingPrice("160000000000");

    await usdc.connect(bf5).transfer(user2.address, "10000000000");

    const startBalance = (await usdc.balanceOf(user2.address));
    expect(startBalance).to.eq('10000000000');

    // Another user deposited 10k

    const amount = 10000 * 10 ** 6;
    await usdc.connect(user2).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(user2).deposit(true, amount);

    const lpTokenAmount = await quoteLpPositionMinter.balanceOf(user2.address);

    // After this user deposits there will be 10847 + 10000 = 20847
    // We'll have (amountIn * _getTotalSupply(isQuote)) / (epochData[currentEpoch][isQuote].totalDeposits - pnl) =
    // = (10000 * 10000) / (10847001691 - pnl) = adjusting decimals is 9758.952229 LP tokens
    // 600 is unrealized pnl of traders

    expect(lpTokenAmount.toString()).equals("9758952229");

    const totalSupply = await quoteLpPositionMinter.totalSupply();

    console.log(quoteLpPositionMinter.address);

    expect(totalSupply).to.eq("19758952229");

    // Test withdraw to see if we can get back our 10000 USDC burning 9758.95 LP tokens
    await optionPerp.connect(user2).withdraw(true, lpTokenAmount, 0);

    const endBalance = (await usdc.balanceOf(user2.address));
    expect(endBalance).to.eq('9999999999');
  });

  it("another user should be able to deposit and request withdraw, a bot should be able to fullfill it", async () => {
    const startBalance = (await usdc.balanceOf(user2.address));
    expect(startBalance).to.eq('9999999999');

    // Another user deposited 5k

    const amount = 5000 * 10 ** 6;
    await usdc.connect(user2).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(user2).deposit(true, amount);

    const lpTokenAmount = await quoteLpPositionMinter.balanceOf(user2.address);

    expect(lpTokenAmount.toString()).equals("4879476114");

    const totalSupply = await quoteLpPositionMinter.totalSupply();

    console.log(quoteLpPositionMinter.address);

    expect(totalSupply).to.eq("14879476114");

    const expectedAmountOut = await optionPerp.connect(user2).callStatic.withdraw(true, lpTokenAmount, 0);
    expect(expectedAmountOut).to.eq("4999999999");

    // We pay 10 USDC to bots
    const priorityFees = "10000000";

    // Create withdrawal request
    await optionPerp.connect(user2).openWithdrawalRequest(
      true, lpTokenAmount, expectedAmountOut.sub(priorityFees), priorityFees
    );

    // An external bot will try to trigger the withdraw asap
    await b50.sendTransaction({
      to: user3.address,
      value: ethers.utils.parseEther("100.0")
    });

    await optionPerp.connect(user3).completeWithdrawalRequest(1);

    const feesObtainedByBot = await usdc.balanceOf(user3.address);
    expect(feesObtainedByBot).to.eq("5000000"); // half of fees are withheld by LPs

    // 9990 as 10 is being paid to bot
    const amountObtainedByUser = await usdc.balanceOf(user2.address);
    expect(amountObtainedByUser).to.eq(9989999998);
  });

  it("position can be liquidated", async () => {
    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(3);
    expect(shortLiquidationPrice).to.eq(176679158245); // Liquidation price decreases to $1766
    
    await priceOracle.updateUnderlyingPrice("180000000000");

    const startBalance = (await usdc.balanceOf(user3.address));
    expect(startBalance).to.eq('5000000'); // 5 USDC

    // User 3 calls liquidate() on User 1 short position

    await optionPerp.connect(user3).liquidate(3);

    const endBalance = (await usdc.balanceOf(user3.address));
    expect(endBalance).to.eq('305000000'); // 300 USDC of liquidation fee
    
    const isPositionOpen = await optionPerp._isPositionOpen(3);
    expect(isPositionOpen).to.eq(false);
  });

  it("liquidated user can settle its option after epoch expires", async () => {
    let optionPosition = await optionPerp.optionPositions(0);
    expect(optionPosition['isSettled']).to.eq(false);
    expect(optionPosition['isPut']).to.eq(true);
    expect(optionPosition['amount']).to.eq("116822429");
    expect(optionPosition['strike']).to.eq("128400000000");

    await expect(optionPerp.connect(user1).settle(0)).to.be.revertedWith("Too early");

    await network.provider.send("evm_setNextBlockTimestamp", [1671290433]);
    await network.provider.send("evm_mine");

    // before expiry but after liquidation price goes up and option token has positive pnl
    await priceOracle.updateUnderlyingPrice("110000000000");

    await optionPerp.updateEpoch(getTime() + oneWeek * 10);

    const pnl = await optionPerp._getOptionPnl(0);
    expect(pnl).to.eq(214953269);

    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq("98526462020");

    await optionPerp.connect(user1).settle(0);

    const endBalance = (await usdc.balanceOf(user1.address));
    expect(endBalance).to.eq("98741415289"); // 214.95 USDC of profit
    // 1.16822429 tokens * (1284 strike - 1100 expiry)

    optionPosition = await optionPerp.optionPositions(0);
    expect(optionPosition['isSettled']).to.eq(true);
  });

  it("long position should remain open after epoch expiry", async () => {
    await priceOracle.updateUnderlyingPrice("180000000000");

    const isPositionOpen = await optionPerp._isPositionOpen(1);
    let pnl = await optionPerp._getPositionPnl(1);

    expect(isPositionOpen).to.eq(true);
    expect(pnl).to.eq(800000000);
  });

  it("long position can be liquidated correctly too", async () => {
    const liquidationPrice = await optionPerp._getPositionLiquidationPrice(1);
    expect(liquidationPrice).to.eq("53135499300");

    await priceOracle.updateUnderlyingPrice("53411423100");

    await expect(optionPerp.connect(user3).liquidate(1)).to.be.revertedWith("Position has enough collateral");

    await priceOracle.updateUnderlyingPrice("53011423099");

    const startBalance = (await usdc.balanceOf(user3.address));
    expect(startBalance).to.eq('305000000');

    await optionPerp.connect(user3).liquidate(1);

    const endBalance = (await usdc.balanceOf(user3.address));
    expect(endBalance).to.eq('554999640'); // 250 USDC of liquidation fee
  });

  it("another user should be able to deposit and request withdraw, a bot should be able to fullfill it", async () => {
    const initialBalance = (await usdc.balanceOf(user2.address));
    expect(initialBalance).to.eq('9989999998');

    // Another user deposited 5k

    const amount = 5000 * 10 ** 6;
    await usdc.connect(user2).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(user2).deposit(true, amount);

    const lpTokenAmount = await quoteLpPositionMinter.balanceOf(user2.address);

    expect(lpTokenAmount.toString()).equals("4021863356");

    const totalSupply = await quoteLpPositionMinter.totalSupply();

    console.log(quoteLpPositionMinter.address);

    expect(totalSupply).to.eq("14021863356");

    const expectedAmountOut = await optionPerp.connect(user2).callStatic.withdraw(true, lpTokenAmount, 0);
    expect(expectedAmountOut).to.eq("4999999999");

    // We pay 10 USDC to bots
    const priorityFees = "10000000";

    // Create withdrawal request
    await optionPerp.connect(user2).openWithdrawalRequest(
      true, lpTokenAmount, expectedAmountOut.sub(priorityFees), priorityFees
    );

    // An external bot will try to trigger the withdraw asap
    await b50.sendTransaction({
      to: user3.address,
      value: ethers.utils.parseEther("100.0")
    });

    const user3Balance = await usdc.balanceOf(user3.address);
    expect(user3Balance).to.eq("554999640");

    await optionPerp.connect(user3).completeWithdrawalRequest(2);

    const feesObtainedByBot = (await usdc.balanceOf(user3.address)).sub(user3Balance);
    expect(feesObtainedByBot).to.eq("5000000");

    const amountObtainedByUser = await usdc.balanceOf(user2.address);
    expect(amountObtainedByUser).to.eq("9979999997");
  });

  it("open a short", async () => {
    await priceOracle.updateUnderlyingPrice("100000000000");

    const startBalance = (await usdc.balanceOf(user1.address));
    expect(startBalance).to.eq('98741415289');

    console.log('Open short');

    await optionPerp
      .connect(user1)
      .openPosition(true, toDecimals(3000, 8), toDecimals(910, 6));

    // We open a short of $3000 with $910 of collateral (lev 3.29x)

    await priceOracle.updateUnderlyingPrice("50000000000");

    // LPs are losing 500 * 3 = $1500
  });

  it("should also be able to deposit base successfully", async () => {
    await weth.connect(b50).transfer(user2.address, ethers.utils.parseEther("1.0"));

    const amount = (1 * 10 ** 18).toString();
    await weth.connect(user2).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(user2).deposit(false, amount);

    const lpTokenAmount = await baseLpPositionMinter.balanceOf(user2.address);

    // Unrealized pnl is $1500
    // Total deposits are 10000000099754534490, we subtract pnl in ETH term (3) so we have 7000000099754534490
    // Total supply was 10000000000000000000
    // Amount out is now (1 * 10 ** 18) * 10000000000000000000 / 7000000000754534490 = 1428571428417441940
    expect(lpTokenAmount.toString()).equals("1428571428417441940");

    // Test withdraw to see if we can get back our 1 ETH burning 1.4285 LP tokens
    await optionPerp.connect(user2).withdraw(false, lpTokenAmount, 0);

    const endBalance = (await weth.balanceOf(user2.address));
    expect(endBalance).to.eq('999999999999999999');
  });
});