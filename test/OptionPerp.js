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

  const timeTravel = async seconds => {
    await network.provider.send("evm_increaseTime", [seconds]);
    await network.provider.send("evm_mine", []);
  };

  before(async () => {
    signers = await ethers.getSigners();
    owner = signers[0];

    // Users
    user0 = signers[1];
    user1 = signers[2];
    user2 = signers[3];
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
    // Option Perp
    const OptionPerp = await ethers.getContractFactory("OptionPerp");
    optionPerp = await OptionPerp.deploy(
      weth.address,
      usdc.address,
      optionPricing.address,
      volatilityOracle.address,
      priceOracle.address,
      "0xaBBc5F99639c9B6bCb58544ddf04EFA6802F4064", // GMX
      "0xE592427A0AEce92De3Edee1F18E0157C05861564", // UNI V3
      quoteLpPositionMinter.address,
      baseLpPositionMinter.address
    );
    console.log("deployed option perp:", optionPerp.address);
    await quoteLpPositionMinter.setOptionPerpContract(optionPerp.address);
    await baseLpPositionMinter.setOptionPerpContract(optionPerp.address);
    await perpPositionMinter.setOptionPerpContract(optionPerp.address);

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

  it("should bootstrap successfully", async () => {
    const oneWeekFromNow = getTime() + oneWeek;
    await optionPerp.expireAndBootstrap(oneWeekFromNow);
    expect(await optionPerp.currentEpoch()).equals(1);
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
  });

  it("should not be able to immediately withdraw", async () => {
    const amount = (10 * 10 ** 6).toString();
    await quoteLpPositionMinter.approve(optionPerp.address, amount);
    await expect(optionPerp.connect(user1).withdraw(true, amount, 0)).to.be.revertedWith('Withdraws are not open');
  });

  it("should not bootstrap if current epoch hasn't expired", async () => {
    const oneWeekFromNow = getTime() + oneWeek;
    await expect(
      optionPerp.expireAndBootstrap(oneWeekFromNow)
    ).to.be.revertedWith(
      "Cannot bootstrap before the current epoch was expired"
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
    const initialBalance = (await usdc.balanceOf(user1.address));
    expect(initialBalance).to.eq('100000000000');

    await usdc.connect(user1).approve(optionPerp.address, "100000000000000000000");

    await expect(optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(100000, 8), toDecimals(50000, 6))
    ).to.be.revertedWith("Not enough liquidity to open position");
  });

  it("should open a long position successfully", async () => {
    const initialBalance = (await usdc.balanceOf(user1.address));
    expect(initialBalance).to.eq('100000000000');

    await usdc.connect(user1).approve(optionPerp.address, "100000000000000000000");

    await optionPerp
      .connect(user1)
      .openPosition(false, toDecimals(1000, 8), toDecimals(500, 6));
    const { size } = await optionPerp.perpPositions(0);
    expect(size).equal(toDecimals(1000, 8));
    expect(await usdc.balanceOf(user1.address)).equals(
      initialBalance.sub(toDecimals(500, 6))
    );
  });

  it("should be able to close a long position with a profit", async () => {
    await priceOracle.updateUnderlyingPrice("150000000000");

    const estimatedPnl = await optionPerp._getPositionPnl(0);
    expect(estimatedPnl).to.eq('500000000');

    let amountOutAfterClosing = await optionPerp.connect(user1).callStatic.closePosition(0, 0);
    expect(amountOutAfterClosing).to.eq('993749995');

    await network.provider.send("evm_setNextBlockTimestamp", [1671240414]);
    await network.provider.send("evm_mine");

    // After hours we pay more funding
    amountOutAfterClosing = await optionPerp.connect(user1).callStatic.closePosition(0, 0);
    expect(amountOutAfterClosing).to.gte('989965527');

    await optionPerp.connect(user1).closePosition(0, 0);

    const finalBalance = (await usdc.balanceOf(user1.address));

    // Initial balance was 100k
    expect(finalBalance).to.eq('100489965521');
  });

  it("should open multiple position (short, long) successfully", async () => {
    await priceOracle.updateUnderlyingPrice("100000000000");

    const initialBalance = (await usdc.balanceOf(user1.address));
    expect(initialBalance).to.eq('100489965521');

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
    expect(obtainedClosingLong).to.eq(775948660); // $775

    const obtainedClosingShort = await optionPerp.connect(user1).callStatic.closePosition(2, 0); // $1 from liquidationPrice
    expect(obtainedClosingShort).to.eq(48406244); // $48
  });

  it("add collateral to improve liquidation price", async () => {
    const initialBalance = (await usdc.balanceOf(user1.address));
    expect(initialBalance).to.eq('99079965521');

    // Deposit $500 more
    await optionPerp.connect(user1).addCollateral(2, toDecimals(500, 6))

    const balance = (await usdc.balanceOf(user1.address));
    expect(balance).to.eq('98579965521');

    // Liquidation price for our short goes from $1285 to $1442
    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(2);
    expect(shortLiquidationPrice).to.eq(144285760566);
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
  });

  it("it is possible to reduce collateral", async () => {
    // We reduce collateral of our position (too much)
    await expect(optionPerp.connect(user1).reduceCollateral(3, toDecimals(900, 6))).to.be.revertedWith("Amount to withdraw is too big");

    // We reduce collateral of a reasonable amount ($200)
    await optionPerp.connect(user1).reduceCollateral(3, toDecimals(200, 6));

    const shortLiquidationPrice = await optionPerp._getPositionLiquidationPrice(3);
    expect(shortLiquidationPrice).to.eq(176663533164); // Liquidation price decrases to $1766

    let pnl = await optionPerp._getPositionPnl(3);
    expect(pnl).to.eq(12); // PnL does not change

    let shortPositionValue = await optionPerp._getPositionValue(3);
    expect(shortPositionValue).to.eq(1499999988); // Position value does not change

    await priceOracle.updateUnderlyingPrice("150000000000");

    pnl = await optionPerp._getPositionPnl(3);
    expect(pnl).to.eq(-252336435); // PnL goes to -$252

    shortPositionValue = await optionPerp._getPositionValue(3);
    expect(shortPositionValue).to.eq(1752336435); // Position value increases
  });

  it("another user should be able to deposit", async () => {
    await priceOracle.updateUnderlyingPrice("160000000000");

    await usdc.connect(bf5).transfer(user2.address, "100000000000");

    expect((await optionPerp.epochLpData(1, true)).totalDeposits).equals(
      "310852000000"
    );

    const amount = 10000 * 10 ** 6;
    await usdc.connect(user2).approve(optionPerp.address, MAX_UINT);
    await optionPerp.connect(user2).deposit(true, amount);

    const deposited = await quoteLpPositionMinter.balanceOf(user2.address);

    expect(deposited.toString()).equals("322078990");
  });
});
