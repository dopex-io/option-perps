// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import {IERC20} from "./interface/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Pausable} from "./helpers/Pausable.sol";

import {ILpPositionMinter} from "./interface/ILpPositionMinter.sol";
import {IPerpPositionMinter} from "./interface/IPerpPositionMinter.sol";
import {IOptionPositionMinter} from "./interface/IOptionPositionMinter.sol";
import {IOptionPricing} from "./interface/IOptionPricing.sol";
import {IVolatilityOracle} from "./interface/IVolatilityOracle.sol";
import {IPriceOracle} from "./interface/IPriceOracle.sol";
import {IGmxRouter} from "./interface/IGmxRouter.sol";
import {IGmxHelper} from "./interface/IGmxHelper.sol";

import "hardhat/console.sol";

// On LP deposit:
// - select ETH or USDC, adds to LP for current epoch

// User opens long:
// - Purchase options from ETH LP and sell option into USDC LP
// - If position size is 1 ETH, max leverage = abs(atm delta) * mark price * amount/(atm premium + fees + funding until expiry)
// - User selects amount of leverage on UI upto max leverage and required collateral is calculated and passed to openPosition()
// - On openPosition(), position is opened and recorded in struct. NFT representing position is transferred to user
// - ETH + USD LP records total position size, collateral and delta of position
// - PNL and delta are retrieved by querying position NFTs for user and total position size + delta for LP
// - Liquidation price is calculated by opening price - (margin / delta)

// User closes position:
// - Both long call and short put are closed
// - PNL is settled on both ETH and USD LPs
// - Fees and funding are deducted from final settlement

// User hits liquidation price:
// - Margin from position is credited to LP
// - Call option is still open since option premium is seized from margin

// User holds option until expiry:
// - Options are settled as per SSOV from either LP depending on whether they're calls/puts

// On expiry:
// - LPs are auto-rolled over to next epoch
// - Positions remains open
// - Options can be settled

// Notes:
// - 2 pools - eth / usdc  - single-sided liquidity
// - Max leverage for opening long/short = mark price/((atm premium * 2) + fees + funding until expiry)
// - Max leverage: 1000 / ((90 * 2) + (90 * 0.25 * 0.01) + (1000 * 0.03))
// - Margin for opening long/short = (atm premium * max leverage / target leverage) + fees + funding until expiry
// - On closing, If pnl is +ve, payoff is removed from eth LP if long, USD lp if short
// - If pnl is -ve, OTM option is returned to pool + premium
// - Liquidation price = opening price - (margin / delta)
// - Deposits are always open
// - Withdraws are always open (with a priority queue system)

contract OptionPerp is Ownable, Pausable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  IERC20 public base;
  IERC20 public quote;

  IOptionPricing public optionPricing;
  IVolatilityOracle public volatilityOracle;
  IPriceOracle public priceOracle;

  ILpPositionMinter public quoteLpPositionMinter;
  ILpPositionMinter public baseLpPositionMinter;
  IPerpPositionMinter public perpPositionMinter;
  IOptionPositionMinter public optionPositionMinter;

  IGmxRouter public gmxRouter;
  IGmxHelper public gmxHelper;
  
  uint public expiry;
  uint public epoch;

  uint public withdrawalRequestsCounter;

  mapping (bool => EpochData) public epochData;
  mapping (uint => PerpPosition) public perpPositions;
  mapping (uint => OptionPosition) public optionPositions;
  mapping (uint => PendingWithdrawal) public pendingWithdrawals;

  // epoch => expiryPrice
  mapping (uint => uint) public expiryPrices;

  uint public constant divisor       = 1e8;
  uint public minFundingRate          = 3650000000; // 36.5% annualized (0.1% a day)
  uint public maxFundingRate          = 365000000000; // 365% annualized (1% a day)
  uint public feeOpenPosition        = 5000000; // 0.05%
  uint public feeClosePosition       = 5000000; // 0.05%
  uint public feeLiquidation         = 50000000; // 0.5%
  uint public feePriorityWithheld    = 5000000000; // 50%
  uint public liquidationThreshold   = 500000000; // 5%

  uint internal constant MAX_UINT = 2**256 - 1;

  uint internal constant POSITION_PRECISION = 1e8;
  uint internal constant OPTIONS_PRECISION = 1e18;

  struct EpochData {
    // Total asset deposits
    uint totalDeposits;
    // Active deposits for option writes
    uint activeDeposits;
    // Average price of all positions taken by LP
    uint averageOpenPrice;
    // Open position count (in base asset)
    uint positions;
    // Margin deposited for write positions by users selling into LP
    uint margin;
    // Premium collected for option purchases from the pool
    uint premium;
    // Opening fees collected from positions
    uint openingFees;
    // Closing fees collected from positions
    uint closingFees;
    // Total open interest (in asset)
    uint oi;
  }

  struct PerpPosition {
    // Is position open
    bool isOpen;
    // Is short position
    bool isShort;
    // Open position count (in base asset)
    uint positions;
    // Total size in asset
    uint size;
    // Average open price
    uint averageOpenPrice;
    // Margin provided
    uint margin;
    // Premium for position
    uint premium;
    // Fees for opening position
    uint openingFees;
    // Fees for closing position
    uint closingFees;
    // Funding for position
    int funding;
    // Final PNL of position
    int pnl;
    // Opened at timestamp
    uint openedAt;
  }

  struct PendingWithdrawal {
    // lp token amount
    uint amountIn;
    // min amount of underlying token accepted after fees
    uint minAmountOut;
    // is quote?
    bool isQuote;
    // quantity of amount out used to incentivize a quick withdrawal
    uint priorityFee;
    // user who asks to withdraw
    address user;
  }

  struct OptionPosition {
    // Is option settled
    bool isSettled;
    // Is put
    bool isPut;
    // Total amount
    uint amount;
    // Strike price
    uint strike;
    // Epoch
    uint epoch;
  }

  event Settle(
      uint epoch,
      uint strike,
      uint amount,
      uint pnl,
      address indexed to
  );

  event Deposit(
    bool isQuote,
    uint amountIn,
    uint amountOut,
    address indexed user
  );

  event OpenPerpPosition(
    bool isShort,
    uint size,
    uint collateralAmount,
    address indexed user,
    uint indexed id
  );

  event AddCollateralToPosition(
    uint indexed id,
    uint amount,
    address indexed sender
  );

  event ReduceCollateralForPosition(
    uint indexed id,
    uint amount,
    address indexed sender
  );

  event ClosePerpPosition(
    uint indexed id,
    uint size,
    int pnl,
    address indexed user
  );

  event LiquidatePosition(
    uint indexed id,
    uint margin,
    uint positions,
    uint price,
    uint liquidationFee,
    address indexed liquidator
  );

  event Withdraw(
    uint amountIn,
    uint amountOut,
    bool isQuote,
    uint amountOutFeesForBot,
    uint amountOutFeesWithheld,
    address resolver,
    address indexed user
  );

  event CreateWithdrawRequest(
    uint indexed id,
    uint amountIn,
    bool isQuote,
    uint minAmountOut,
    uint priorityFee,
    address indexed user
  );

  event DeleteWithdrawRequest(
    uint indexed id,
    bool isFulfilled
  );

  event EmergencyWithdraw(address sender);

  constructor(
    address _base,
    address _quote,
    address _optionPricing,
    address _volatilityOracle,
    address _priceOracle,
    address _gmxRouter,
    address _gmxHelper,
    address _quoteLpPositionMinter,
    address _baseLpPositionMinter,
    address _perpPositionMinter,
    address _optionPositionMinter,
    uint _expiry
  ) {
    require(_base != address(0), "Invalid base token");
    require(_quote != address(0), "Invalid quote token");
    require(_optionPricing != address(0), "Invalid option pricing");
    require(_volatilityOracle != address(0), "Invalid volatility oracle");
    require(_priceOracle != address(0), "Invalid price oracle");
    base = IERC20(_base);
    quote = IERC20(_quote);
    optionPricing = IOptionPricing(_optionPricing);
    volatilityOracle = IVolatilityOracle(_volatilityOracle);
    priceOracle = IPriceOracle(_priceOracle);
    gmxHelper = IGmxHelper(_gmxHelper);
    gmxRouter = IGmxRouter(_gmxRouter);
    expiry = _expiry;

    quoteLpPositionMinter = ILpPositionMinter(_quoteLpPositionMinter);
    baseLpPositionMinter = ILpPositionMinter(_baseLpPositionMinter);
    perpPositionMinter = IPerpPositionMinter(_perpPositionMinter);
    optionPositionMinter = IOptionPositionMinter(_optionPositionMinter);

    base.approve(_gmxRouter, MAX_UINT);
  }

  /// @notice Internal function to handle swaps using GMX
  /// @param from Address of the token to sell
  /// @param to Address of the token to buy
  /// @param targetAmountOut Target amount of to token we want to receive
  function swapUsingGmxExactOut(
        address from,
        address to,
        uint256 targetAmountOut
    ) internal returns (uint exactAmountOut) {
      address[] memory path;

      path = new address[](2);
      path[0] = address(from);
      path[1] = address(to);

      uint balance = IERC20(to).balanceOf(address(this));

      uint amountIn = gmxHelper.getAmountIn(targetAmountOut, 0, to, from);

      gmxRouter.swap(path, amountIn, 0, address(this));

      exactAmountOut = IERC20(to).balanceOf(address(this)) - balance;
  }

  /// @notice Internal function to get total supply of quote/base lp tokens
  /// @param isQuote If true it returns quote lp tokens supply
  function getTotalSupply(bool isQuote) internal view returns (uint totalSupply) {
    totalSupply = uint(isQuote ? quoteLpPositionMinter.totalSupply() : baseLpPositionMinter.totalSupply());
  }

  /// @notice Public function to compute lp amount given an amount
  /// @param isQuote If true user deposits quote token (else base)
  /// @param amountIn Amount of quote/base token to deposit
  function calcLpAmount(
  bool isQuote,
  uint amountIn
  )
  public
  view
  returns (uint amountOut)
  {
    int currentPrice = int(getMarkPrice());
    int averageOpenPrice = int(epochData[!isQuote].averageOpenPrice);

    // unrealizedPnl is ie6
    // we use !isQuote to get PnL of traders
    int unrealizedPnl = (isQuote ? (currentPrice - averageOpenPrice) : (averageOpenPrice - currentPrice)) * (int(epochData[!isQuote].positions) / 10 ** 2) / int(divisor);

    // totalDeposits is ie6 for isQuote, ie18 for isBase
    int deposits = int(epochData[isQuote].totalDeposits) - (isQuote ? unrealizedPnl : ((unrealizedPnl * 10 ** 2) * 10 ** 18) / currentPrice);

    console.log('Current price');
    console.logInt(currentPrice);

    console.log('Average open price');
    console.log(epochData[!isQuote].averageOpenPrice);

    console.log('Total Deposits');
    console.log(epochData[isQuote].totalDeposits);

    console.log('Unrealized pnl');
    console.logInt(unrealizedPnl);

    console.log('Deposits');
    console.logInt(deposits);

    console.log('Amount in');
    console.log(amountIn);

    console.log('Total supply');
    console.log(getTotalSupply(isQuote));

    if (deposits == 0) amountOut = amountIn;
    else amountOut = (amountIn * getTotalSupply(isQuote)) / uint(deposits);

    console.log('Amount out');
    console.log(amountOut);
  }

  /// @notice External function to deposit base or quote liquidity
  /// @param isQuote If true user deposits quote token (else base)
  /// @param amountIn Amount of quote/base token to deposit
  function deposit(
    bool isQuote,
    uint amountIn
  ) external nonReentrant() {
    _whenNotPaused();

    console.log('DEPOSITS');

    uint amountOut = calcLpAmount(isQuote, uint(amountIn));
    epochData[isQuote].totalDeposits += uint(amountIn);

    console.log('TOTAL DEPOSIT NOW');
    console.log(epochData[isQuote].totalDeposits);

    console.log("AMOUNT OUT");
    console.log(amountOut);

    if (isQuote) {
      quote.safeTransferFrom(msg.sender, address(this), amountIn);
      quoteLpPositionMinter.mint(msg.sender, amountOut);
    } else {
      base.safeTransferFrom(msg.sender, address(this), amountIn);
      baseLpPositionMinter.mint(msg.sender, amountOut);
    }

    emit Deposit(
      isQuote,
      amountIn,
      amountOut,
      msg.sender
    );
  }

  /// @notice Public function to open a withdrawal request
  /// @param isQuote If true user wants to withdraw quote token (else base)
  /// @param amountIn Amount of LP tokens to burn
  /// @param minAmountOut Minimum amount of base/quote tokens to receive
  /// @param priorityFee Amount of base/quote tokens to pay to LPs/bots to acquire withdrawal priority
  function openWithdrawalRequest(
    bool isQuote,
    uint amountIn,
    uint minAmountOut,
    uint priorityFee
  ) public returns (uint id)
  {
    _whenNotPaused();

    uint lpAmount;

    if (isQuote) {
      lpAmount = quoteLpPositionMinter.balanceOf(msg.sender);
    } else {
      lpAmount = baseLpPositionMinter.balanceOf(msg.sender);
    }

    require(lpAmount >= amountIn, "Insufficient LP token amount");

    console.log("LP AMOUNT");
    console.log(lpAmount);
    console.log("AMOUNT IN");
    console.log(amountIn);

    pendingWithdrawals[withdrawalRequestsCounter] = PendingWithdrawal({
      amountIn: amountIn,
      minAmountOut: minAmountOut,
      isQuote: isQuote,
      priorityFee: priorityFee,
      user: msg.sender
    });

    emit CreateWithdrawRequest(
      withdrawalRequestsCounter,
      amountIn,
      isQuote,
      minAmountOut,
      priorityFee,
      msg.sender
    );

    withdrawalRequestsCounter += 1;

    id = withdrawalRequestsCounter - 1;

    console.log('ID TO WITHDRAW');
    console.log(id);
  }

  /// @notice Public function to fulfill a withdrawal request
  /// @param id Identifier of the withdrawal request
  function completeWithdrawalRequest(
    uint id
  ) public nonReentrant() returns (uint amountOut, uint amountOutFeesForBot, uint amountOutFeesWithheld)
  {
    _whenNotPaused();

    PendingWithdrawal memory pendingWithdrawal = pendingWithdrawals[id];

    require(pendingWithdrawal.user != address(0), "Invalid id");

    uint available = epochData[pendingWithdrawal.isQuote].totalDeposits - epochData[pendingWithdrawal.isQuote].activeDeposits;

    uint totalSupply = getTotalSupply(pendingWithdrawal.isQuote);

    console.log("AMOUNT TO BURN");
    console.log(pendingWithdrawal.amountIn);

    uint currentPrice = getMarkPrice();

    // unrealizedPnl is ie6
    // we use !isQuote to get PnL of traders
    uint unrealizedPnl = (pendingWithdrawal.isQuote ? (currentPrice - epochData[!pendingWithdrawal.isQuote].averageOpenPrice) : (epochData[!pendingWithdrawal.isQuote].averageOpenPrice - currentPrice)) * (epochData[!pendingWithdrawal.isQuote].positions / 10 ** 2) / divisor;

    // totalDeposits is ie6 for isQuote, ie18 for isBase
    uint deposits = epochData[pendingWithdrawal.isQuote].totalDeposits - (pendingWithdrawal.isQuote ? unrealizedPnl : ((unrealizedPnl * 10 ** 2) * 10 ** 18) / currentPrice);

    if (pendingWithdrawal.isQuote) {
      quoteLpPositionMinter.burnFromOptionPerp(pendingWithdrawal.user, pendingWithdrawal.amountIn);

      console.log('IS QUOTE');
      console.log('AMOUNT IN');
      console.log(pendingWithdrawal.amountIn);
      console.log('AVAILABLE');
      console.log(available);
      console.log('TOTAL SUPPLY');
      console.log(getTotalSupply(pendingWithdrawal.isQuote));

      amountOut = (pendingWithdrawal.amountIn * deposits) / totalSupply;
      require(amountOut <= available, "Insufficient liquidity");

      quote.safeTransfer(pendingWithdrawal.user, amountOut - pendingWithdrawal.priorityFee);

      amountOutFeesWithheld = pendingWithdrawal.priorityFee * feePriorityWithheld / (divisor * 100);
      amountOutFeesForBot = pendingWithdrawal.priorityFee - amountOutFeesWithheld;

      quote.safeTransfer(msg.sender, amountOutFeesForBot);
    } else {
      baseLpPositionMinter.burnFromOptionPerp(pendingWithdrawal.user, pendingWithdrawal.amountIn);

      console.log('AMOUNT IN');
      console.log(pendingWithdrawal.amountIn);
      console.log('AVAILABLE');
      console.log(available);
      console.log('TOTAL SUPPLY');
      console.log(getTotalSupply(pendingWithdrawal.isQuote));

      amountOut = (pendingWithdrawal.amountIn * deposits) / totalSupply;
      require(amountOut <= available, "Insufficient liquidity");

      base.safeTransfer(pendingWithdrawal.user, amountOut - pendingWithdrawal.priorityFee);

      amountOutFeesWithheld = pendingWithdrawal.priorityFee * feePriorityWithheld / (divisor * 100);
      amountOutFeesForBot = pendingWithdrawal.priorityFee - amountOutFeesWithheld;

      base.safeTransfer(msg.sender, amountOutFeesForBot);
    }

    require(amountOut - pendingWithdrawal.priorityFee >= pendingWithdrawal.minAmountOut, "Insufficient amount out");

    console.log('AMOUNT OUT');
    console.log(amountOut);

    delete pendingWithdrawals[id];

    epochData[pendingWithdrawal.isQuote].totalDeposits = epochData[pendingWithdrawal.isQuote].totalDeposits - amountOut;

    emit DeleteWithdrawRequest(
      id,
      true
    );

    emit Withdraw(
      pendingWithdrawal.amountIn,
      amountOut - pendingWithdrawal.priorityFee,
      pendingWithdrawal.isQuote,
      amountOutFeesForBot,
      amountOutFeesWithheld,
      msg.sender,
      pendingWithdrawal.user
    );
  }

  /// @notice External function to delete a withdrawal request
  /// @param id Identifier of the withdrawal request
  function cancelWithdrawalRequest(
    uint id
  ) external
  {
    _whenNotPaused();

    PendingWithdrawal memory pendingWithdrawal = pendingWithdrawals[id];

    require(pendingWithdrawal.user == msg.sender, "Invalid sender");

    delete pendingWithdrawals[id];

    emit DeleteWithdrawRequest(
      id,
      false
    );
  }

  /// @notice External function to immediately withdraw if enough liquidity is available
  /// @param isQuote If true user wants to withdraw quote token (else base)
  /// @param amountIn Amount of LP tokens to burn
  /// @param minAmountOut Minimum amount of base/quote tokens to receive
  function withdraw(
    bool isQuote,
    uint amountIn,
    uint minAmountOut
  ) external returns (uint amountOut)
  {
    uint id = openWithdrawalRequest(isQuote, amountIn, minAmountOut, 0);
    (amountOut,,) = completeWithdrawalRequest(id);
  }

  /// @notice Public function to open a position
  /// @param isShort If true then it's a short position (else long)
  /// @param size Size of the position in USD (ie8)
  /// @param collateralAmount Collateral used to cover premium + funding + fees and write option in USD (1e6)
  function openPosition(
    bool isShort,
    uint size,
    uint collateralAmount
  ) public nonReentrant() returns (uint id) {
    _whenNotPaused();

    uint _sizeInBase = size * uint(10 ** base.decimals()) / getMarkPrice();
    // Check if enough liquidity is available to open position
    require(
      (epochData[isShort].totalDeposits -
      epochData[isShort].activeDeposits) >=
      (isShort ? size / 10 ** 2 : _sizeInBase),
      "Not enough liquidity to open position"
    );

    console.log('isShort');
    console.log(isShort);
    console.log('Total deposits');
    console.log(epochData[isShort].totalDeposits);
    console.log('Total active');
    console.log(epochData[isShort].activeDeposits);

    // Calculate premium for ATM option in USD
    // If is short, premium is in quote.decimals(). if long, base.decimals();
    uint premium = calcPremium(getMarkPrice(), size);

    // Calculate opening fees in USD
    uint openingFees = calcFees(true, size / 10 ** 2);
    console.log('Opening fees');
    console.log(openingFees);

    // Calculate closing fees in USD
    uint closingFees = calcFees(false, size / 10 ** 2);
    console.log('Closing fees');
    console.log(closingFees);

    // Calculate minimum collateral in USD
    uint minCollateral = (premium * 2) + openingFees + closingFees;
    console.log('Min collateral');
    console.log(minCollateral);

    // Check if collateral amount is sufficient for short side of trade and long premium
    require(
      collateralAmount >= minCollateral,
      "Collateral must be greater than min. collateral"
    );

    // Number of positions (in 8 decimals)
    uint positions = size * divisor / getMarkPrice();
    console.log('Positions');
    console.log(positions);

    // Update epoch LP data
    epochData[isShort].margin            += collateralAmount;
    epochData[isShort].oi                += size;
    epochData[isShort].premium           += premium;
    epochData[isShort].openingFees       += openingFees;
    epochData[isShort].activeDeposits    += size / 10 ** 2;
    epochData[isShort].positions         += positions;

    if (epochData[isShort].averageOpenPrice == 0)
      epochData[isShort].averageOpenPrice  = getMarkPrice();
    else
      epochData[isShort].averageOpenPrice  =
        epochData[isShort].oi /
        epochData[isShort].positions;

    // Transfer collateral from user
    quote.safeTransferFrom(
        msg.sender,
        address(this),
        collateralAmount
      );

    // Generate perp position NFT
    id = perpPositionMinter.mint(msg.sender);
    console.log("Minted to");
    console.log(msg.sender);
    console.log("Minter");
    console.log(address(perpPositionMinter));

    perpPositions[id] = PerpPosition({
      isOpen: true,
      isShort: isShort,
      positions: positions,
      size: size,
      averageOpenPrice: getMarkPrice(),
      margin: collateralAmount,
      premium: premium,
      openingFees: openingFees,
      closingFees: 0,
      funding: 0,
      pnl: 0,
      openedAt: block.timestamp
    });

    // Emit open perp position event
    emit OpenPerpPosition(
      isShort,
      size,
      collateralAmount,
      msg.sender,
      id
    );
  }

  /// @notice External function to change the size of a position (it closes the existing position and creates a new one)
  /// @param id Identifier of the position
  /// @param size Size of the desired position in USD (ie8)
  /// @param collateralAmount Desired amount of collateral to use (1e6)
  /// @param minAmountOut Amount retrieved when closing the position
  function changePositionSize(
    uint id,
    uint size,
    uint collateralAmount, 
    uint minAmountOut
  ) external returns (uint amountOut) {
    _whenNotPaused();

    bool isShort = perpPositions[id].isShort;
    uint originalSize = perpPositions[id].size;
    amountOut = closePosition(id, minAmountOut);

    openPosition(isShort, size, collateralAmount);
  }

  /// @notice External function to return the volatility
  /// @param strike Strike of option
  function getVolatility(uint strike)
  public
  view
  returns (uint volatility) {
    volatility =
      uint(volatilityOracle.getVolatility(
        strike
      ));
  }

  /// @notice Internal function to calculate premium
  /// @param strike Strike of option
  /// @param size Amount of option
  function calcPremium(
    uint strike,
    uint size
  )
  internal
  returns (uint premium) {
    premium = (uint(optionPricing.getOptionPrice(
        false, // ATM options: does not matter if call or put
        expiry,
        strike,
        strike,
        getVolatility(strike)
    )) * (size / strike));
    
    premium = premium / (divisor / uint(10 ** quote.decimals()));
  }

  /// @notice Internal function to calculate fees
  /// @param openingPosition True if is opening position (else is closing)
  /// @param amount Value of option in USD (ie6)
  function calcFees(
    bool openingPosition,
    uint amount
  )
  internal
  view
  returns (uint fees) {
    fees = (amount * (openingPosition ? feeOpenPosition : feeClosePosition)) / (100 * divisor);
  }

  /// @notice Public function to retrieve price of base asset from oracle
  /// @param price Mark price
  function getMarkPrice()
  public
  view
  returns (uint price) {
    price = uint(priceOracle.getUnderlyingPrice());
  }

  /// @notice Public function to add collateral to an existing position
  /// @param id Identifier of the position
  /// @param collateralAmount Desired amount of collateral to add (1e6)
  function addCollateral(
    uint id,
    uint collateralAmount
  ) external nonReentrant() {
    _whenNotPaused();

    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    epochData[perpPositions[id].isShort].margin += collateralAmount;
    perpPositions[id].margin += collateralAmount;
    // Move collateral
    IERC20(quote).safeTransferFrom(
      msg.sender,
      address(this),
      collateralAmount
    );
    emit AddCollateralToPosition(
      id,
      collateralAmount,
      msg.sender
    );
  }

  /// @notice Public function to reduce collateral from an existing position
  /// @param id Identifier of the position
  /// @param collateralAmount Desired amount of collateral to remove (1e6)
  function reduceCollateral(
    uint id,
    uint collateralAmount
  ) external nonReentrant() {
    _whenNotPaused();

    require(collateralAmount <= epochData[perpPositions[id].isShort].margin, "Amount to withdraw is too big");

    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    epochData[perpPositions[id].isShort].margin -= collateralAmount;
    perpPositions[id].margin -= collateralAmount;

    require(isPositionCollateralized(id), "Position is not collateralized");

    // Move collateral
    IERC20(quote).safeTransfer(
       msg.sender,
      collateralAmount
    );

    emit ReduceCollateralForPosition(
      id,
      collateralAmount,
      msg.sender
    );
  }

  /// @notice Public function to returns true if position is open
  /// @param id Identifier of the position
  function isPositionOpen(uint id)
  public
  view
  returns (bool value) {
    value = perpPositions[id].isOpen;
  }

  /// @notice Public function to get value of an open perp position
  /// @param id Identifier of the position
  function getPositionValue(uint id)
  public
  view
  returns (uint value) {
    value = perpPositions[id].positions * getMarkPrice() / (divisor * 100); // ie6
  }

  /// @notice Public function to get funding rate
  /// @param isShort True for short side
  function getFundingRate(bool isShort)
  public
  view
  returns (int fundingRate) {
    uint markPrice = getMarkPrice() / 10 ** 2;
    uint shortOiInUsd = epochData[true].oi * markPrice / divisor; // ie6
    uint longOiInUsd = epochData[false].oi * markPrice / divisor; // ie6
    fundingRate = int(minFundingRate);

    if (shortOiInUsd > 0) {
      uint longShortRatio = divisor * longOiInUsd / shortOiInUsd;
      int longFunding;

      if (longShortRatio > divisor) longFunding = int(maxFundingRate);
      else longFunding = (int(maxFundingRate - minFundingRate) * int(longShortRatio)) / int(divisor);

      fundingRate = isShort ? -1 * longFunding :  longFunding;
    }
  }

  /// @notice Public function to get funding of an open perp position
  /// @param id Identifier of the position
  function getPositionFunding(uint id)
  public
  view
  returns (int funding) {
    int fundingRate = getFundingRate(perpPositions[id].isShort);

    // size is ie8
    // margin is ie6
    // _borrowed is ie6
    int _borrowed = int(perpPositions[id].size / 10 ** 2 - perpPositions[id].margin);
    funding = ((_borrowed * fundingRate / int(divisor * 100)) * int(block.timestamp - perpPositions[id].openedAt)) / int(365 days); // ie6
  }

  /// @notice Public function to get Pnl of an option position
  /// @param id Identifier of the position
  function getOptionPnl(uint id)
  public
  view
  returns (uint value) {
    uint expiryPrice = expiryPrices[optionPositions[id].epoch];

    require(expiryPrice > 0, "Too early");

    console.log('STRIKE');
    console.log(optionPositions[id].strike);

    console.log('EXPIRY PRICE');
    console.log(expiryPrice);

    console.log('AMOUNT');
    console.log(optionPositions[id].amount);

    // all terms are ie8
    // after we multiply we have an ie16 term so we remove 8 and another 2 to make it ie6

    if (optionPositions[id].isPut) {
      value = ((optionPositions[id].strike - expiryPrice) * optionPositions[id].amount) / 10 ** (8 + 2); // ie6
    } else {
      value = ((expiryPrice - optionPositions[id].strike) * optionPositions[id].amount) / 10 ** (8 + 2); // ie6
    }
  }

  /// @notice Public function to get Pnl of a  position
  /// @param id Identifier of the position
  function getPositionPnl(uint id)
  public
  view
  returns (int value) {
    int positionValue = int(getPositionValue(id));

    value = perpPositions[id].isShort ?
      int(perpPositions[id].size / 10 ** 2) - positionValue :
      positionValue - int(perpPositions[id].size / 10 ** 2); // ie6
  }

  /// @notice Get net margin of an open perp position
  /// @param id Identifier of the position
  function getPositionNetMargin(uint id)
  public
  view
  returns (int value) {
    int pnl = getPositionPnl(id);
    int sizePlusPnl = int(perpPositions[id].size / 10 ** 2)  + pnl;

    uint closingFees = sizePlusPnl <= 0 ? 0 : calcFees(false, uint(sizePlusPnl));

    value = int(perpPositions[id].margin) - int(perpPositions[id].premium) - int(perpPositions[id].openingFees) - int(closingFees) - getPositionFunding(id); // ie6
  }

  /// @notice Get liquidation price
  /// @param id Identifier of the position
  function getPositionLiquidationPrice(uint id)
  public
  view
  returns (uint price) {
    int netMargin = getPositionNetMargin(id);
    netMargin -= netMargin * int(liquidationThreshold / (divisor * 100));

    if (netMargin < 0) netMargin = 0;

    if (perpPositions[id].isShort) {
      price = (divisor * (perpPositions[id].size) / perpPositions[id].positions) + (divisor * (uint(netMargin) * 10 ** 2) / perpPositions[id].positions); // ie8
    } else {
      price = (divisor * (perpPositions[id].size) / perpPositions[id].positions) - (divisor * (uint(netMargin) * 10 ** 2) / perpPositions[id].positions); // ie8
    }
  }

  /// @notice Function to check whether a position is sufficiently collateralized
  /// @param id Identifier of the position
  function isPositionCollateralized(uint id)
  public
  view
  returns (bool isCollateralized) {
    int pnl = getPositionPnl(id);
    int netMargin = getPositionNetMargin(id);
    netMargin -= netMargin * int(liquidationThreshold / (divisor * 100));
    isCollateralized = netMargin + pnl >= 0;
  }

  /// @notice Public function to settle a call/put option
  /// @param id Identifier of the option
  function settle(
    uint id
  ) public nonReentrant() {
    _whenNotPaused();

    address owner = optionPositionMinter.ownerOf(id);

    require(!optionPositions[id].isSettled, "Already settled");
    require(optionPositions[id].epoch < epoch, "Too early");
    require(msg.sender == owner, "Invalid sender");

    optionPositions[id].isSettled = true;

    uint pnl = getOptionPnl(id);

    require(pnl > 0, "Negative pnl");

    if (optionPositions[id].isPut) {
      quote.safeTransfer(owner, pnl);
      epochData[true].totalDeposits -= pnl;
    }
    else {
      base.safeTransfer(owner, pnl);
      epochData[false].totalDeposits -= pnl;
    }

    emit Settle(
        optionPositions[id].epoch,
        optionPositions[id].strike,
        optionPositions[id].amount,
        pnl,
        owner
    );
  }

  /// @notice Public function to close a position
  /// @param id Identifier of the option
  /// @param minAmountOut Minimum amount of pnl + collateral to receive
  function closePosition(
    uint id,
    uint minAmountOut
  ) public nonReentrant() returns (uint amountOut) {
    _whenNotPaused();

    // Check if position is open
    require(perpPositions[id].isOpen, "Position not open");
    // Sender must be owner of position
    require(perpPositionMinter.ownerOf(id) == msg.sender, "Invalid sender");
    // Position must be sufficiently collateralized
    require(isPositionCollateralized(id), "Position is not collateralized");

    // Calculate pnl
    int pnl = getPositionPnl(id);
    // Settle option positions
    bool isShort = perpPositions[id].isShort;
    // Calculate funding
    int funding = getPositionFunding(id);
    // Calculate closing fees
    uint closingFees = int(perpPositions[id].size / 10 ** 2) + pnl <= 0 ? 0 : calcFees(false, uint(int(perpPositions[id].size / 10 ** 2) + pnl));

    epochData[isShort].margin -= perpPositions[id].margin;
    epochData[isShort].activeDeposits -= perpPositions[id].size / 10 ** 2;

    console.log(epochData[isShort].totalDeposits);
    epochData[isShort].totalDeposits = uint(int(epochData[isShort].totalDeposits) - pnl + funding + int(closingFees));

    epochData[isShort].oi -= perpPositions[id].size;

    epochData[isShort].averageOpenPrice  =
      epochData[isShort].oi /
      epochData[isShort].positions;

    epochData[isShort].positions -= perpPositions[id].positions;

    epochData[isShort].closingFees += closingFees;

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = pnl;
    perpPositions[id].funding = funding;
    perpPositions[id].closingFees = closingFees;

    uint toTransfer = uint(int(perpPositions[id].margin) + pnl - int(perpPositions[id].premium) - int(perpPositions[id].openingFees) - int(perpPositions[id].closingFees) - perpPositions[id].funding);

    if (toTransfer > 0) {
      amountOut = toTransfer;
      require(amountOut >= minAmountOut, "Amount out is not enough");

      if (!perpPositions[id].isShort) {
        // Convert collateral + PNL to quote and send to user
        amountOut = swapUsingGmxExactOut(address(base), address(quote), amountOut);
      }

      quote.safeTransfer(perpPositionMinter.ownerOf(id), amountOut);
    } else amountOut = 0;

    emit ClosePerpPosition(
      id,
      perpPositions[id].size,
      pnl,
      msg.sender
    );
  }

  /// @notice External function to liquidate a position
  /// @param id Identifier of the option
  function liquidate(
    uint id
  ) external nonReentrant() {
    _whenNotPaused();

    // Check if position is not sufficiently collateralized
    require(!isPositionCollateralized(id), "Position has enough collateral");
    require(perpPositions[id].isOpen, "Position not open");

    bool isShort = perpPositions[id].isShort;
    uint liquidationFee = perpPositions[id].margin * feeLiquidation / divisor;

    epochData[isShort].margin -= perpPositions[id].margin;
    epochData[isShort].activeDeposits -= perpPositions[id].size / 10 ** 2;
    epochData[isShort].totalDeposits += (perpPositions[id].size / 10 ** 2) + perpPositions[id].margin - liquidationFee;
    epochData[isShort].oi -= perpPositions[id].size;
    epochData[isShort].positions -= perpPositions[id].positions;

    if (epochData[isShort].positions > 0)
      epochData[isShort].averageOpenPrice = epochData[isShort].oi / epochData[isShort].positions;
    else epochData[isShort].averageOpenPrice = 0;

    perpPositions[id].isOpen = false;
    perpPositions[id].pnl = -1 * int(perpPositions[id].margin);

    uint amountOut = liquidationFee;

    if (!perpPositions[id].isShort) {
      // swap base for enough quote to pay liquidationFee
      amountOut = swapUsingGmxExactOut(address(base), address(quote), amountOut);
    }

    // Transfer liquidation fee to sender
    IERC20(quote).
      transfer(
        msg.sender,
        amountOut
      );

    // Mint option for liquidated user
    // PUT if isShort, CALL if not
    uint optionId = optionPositionMinter.mint(perpPositionMinter.ownerOf(id));

    optionPositions[optionId] = OptionPosition({
      isSettled: false,
      isPut: isShort,
      amount: perpPositions[id].positions,
      strike: perpPositions[id].averageOpenPrice,
      epoch: epoch
    });

    emit LiquidatePosition(
      id,
      perpPositions[id].margin,
      perpPositions[id].positions,
      getMarkPrice(),
      liquidationFee,
      msg.sender
    );
  }

  /// @notice Transfers all funds to msg.sender
  /// @dev Can only be called by the owner
  /// @param tokens The list of erc20 tokens to withdraw
  /// @param transferNative Whether should transfer the native currency
  function emergencyWithdraw(address[] calldata tokens, bool transferNative)
      external
      onlyOwner
  {
      _whenPaused();
      if (transferNative) payable(msg.sender).transfer(address(this).balance);

      IERC20 token;

      for (uint256 i; i < tokens.length; ) {
          token = IERC20(tokens[i]);
          token.safeTransfer(msg.sender, token.balanceOf(address(this)));

          unchecked {
              ++i;
          }
      }

      emit EmergencyWithdraw(msg.sender);
  }

  /// @notice Pauses the vault for emergency cases
  /// @dev Can only be called by the owner
  function pause() external onlyOwner {
      _pause();
  }

  /// @notice Unpauses the vault
  /// @dev Can only be called by the owner
  function unpause() external onlyOwner {
      _unpause();
  }

    /// @notice External function to expiry and update epoch
  /// @dev Can only be called by the owner
  /// @param nextExpiryTimestamp Next expiry timestamp
  function updateEpoch(
    uint nextExpiryTimestamp
  )
  external
  onlyOwner {
    _whenNotPaused();
    require(uint(block.timestamp) <= expiry, "Too soon");

    expiry = nextExpiryTimestamp;
    expiryPrices[epoch] = getMarkPrice();
    epoch += 1;
  }

  /// @notice External function to update parameters
  /// @dev Can only be called by the owner
  /// @param parameters Array of values to set parameters
  function updateParameters(uint[7] memory parameters)
  external
  onlyOwner {
    minFundingRate = parameters[0];
    maxFundingRate = parameters[1];
    feeOpenPosition = parameters[2];
    feeClosePosition = parameters[3];
    feeLiquidation = parameters[4];
    feePriorityWithheld = parameters[5];
    liquidationThreshold = parameters[6];
  }
}
