// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {TransferHelper} from "../libraries/TransferHelper.sol";
import {ILendingPool, DataTypes} from "../../interfaces/ILendingPool.sol";
import {IEligibilityDataProvider} from "../../interfaces/IEligibilityDataProvider.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IChefIncentivesController} from "../../interfaces/IChefIncentivesController.sol";
import {ILockZap} from "../../interfaces/ILockZap.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

/// @title Leverager Contract
/// @author Radiant
contract Leverager is OwnableUpgradeable {
	using SafeERC20 for IERC20;

	/// @notice margin estimation used for zapping eth to dlp
	uint256 public constant ZAP_MARGIN_ESTIMATION = 6;

	/// @notice maximum margin allowed to be set by the deployer
	uint256 public constant MAX_MARGIN = 10;

	/// @notice Ratio Divisor
	uint256 public constant RATIO_DIVISOR = 10000;

	// Max reasonable fee, 1%
	uint256 public constant MAX_REASONABLE_FEE = 100;

	/// @notice Mock ETH address
	address public constant API_ETH_MOCK_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

	/// @notice LTV Calculation precision
	uint256 public constant TWO_POW_16 = 2 ** 16;

	/// @notice Interest rate mode
	uint256 public constant INTEREST_RATE_MODE = 2;

	/// @notice Lending Pool address
	ILendingPool public lendingPool;

	/// @notice EligibilityDataProvider contract address
	IEligibilityDataProvider public eligibilityDataProvider;

	/// @notice LockZap contract address
	ILockZap public lockZap;

	/// @notice Wrapped ETH contract address
	IWETH public weth;

	/// @notice Aave oracle address
	IAaveOracle public aaveOracle;

	/// @notice Fee ratio
	uint256 public feePercent;

	/// @notice Treasury address
	address public treasury;

	/// @notice ChefIncentivesController contract address
	IChefIncentivesController public cic;

	/// @notice Emitted when fee ratio is updated
	event FeePercentUpdated(uint256 indexed _feePercent);

	/// @notice Emitted when treasury is updated
	event TreasuryUpdated(address indexed _treasury);

	error AddressZero();

	error ReceiveNotAllowed();

	error FallbackNotAllowed();

	error InsufficientPermission();

	error EthTransferFailed();

	/// @notice Disallow a loop count of 0
	error InvalidLoopCount();

	/// @notice Emitted when ratio is invalid
	error InvalidRatio();

	/// @notice Thrown when deployer sets the margin too high
	error MarginTooHigh();

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _lendingPool Address of lending pool.
	 * @param _rewardEligibleDataProvider EligibilityProvider address.
	 * @param _aaveOracle address.
	 * @param _lockZap address.
	 * @param _cic address.
	 * @param _weth WETH address.
	 * @param _feePercent leveraging fee ratio.
	 * @param _treasury address.
	 */
	function initialize(
		ILendingPool _lendingPool,
		IEligibilityDataProvider _rewardEligibleDataProvider,
		IAaveOracle _aaveOracle,
		ILockZap _lockZap,
		IChefIncentivesController _cic,
		IWETH _weth,
		uint256 _feePercent,
		address _treasury
	) public initializer {
		if (address(_lendingPool) == address(0)) revert AddressZero();
		if (address(_rewardEligibleDataProvider) == address(0)) revert AddressZero();
		if (address(_aaveOracle) == address(0)) revert AddressZero();
		if (address(_lockZap) == address(0)) revert AddressZero();
		if (address(_cic) == address(0)) revert AddressZero();
		if (address(_weth) == address(0)) revert AddressZero();
		if (_treasury == address(0)) revert AddressZero();
		if (_feePercent > MAX_REASONABLE_FEE) revert InvalidRatio();
		__Ownable_init();

		lendingPool = _lendingPool;
		eligibilityDataProvider = _rewardEligibleDataProvider;
		lockZap = _lockZap;
		aaveOracle = _aaveOracle;
		cic = _cic;
		weth = _weth;
		feePercent = _feePercent;
		treasury = _treasury;
	}

	/**
	 * @dev Only WETH contract is allowed to transfer ETH here. Prevent other addresses to send Ether to this contract.
	 */
	receive() external payable {
		if (msg.sender != address(weth)) revert ReceiveNotAllowed();
	}

	/**
	 * @dev Revert fallback calls
	 */
	fallback() external payable {
		revert FallbackNotAllowed();
	}

	/**
	 * @notice Sets fee ratio
	 * @param _feePercent fee ratio.
	 */
	function setFeePercent(uint256 _feePercent) external onlyOwner {
		if (_feePercent > MAX_REASONABLE_FEE) revert InvalidRatio();
		feePercent = _feePercent;
		emit FeePercentUpdated(_feePercent);
	}

	/**
	 * @notice Sets fee ratio
	 * @param _treasury address
	 */
	function setTreasury(address _treasury) external onlyOwner {
		if (_treasury == address(0)) revert AddressZero();
		treasury = _treasury;
		emit TreasuryUpdated(_treasury);
	}

	/**
	 * @dev Returns the configuration of the reserve
	 * @param asset The address of the underlying asset of the reserve
	 * @return The configuration of the reserve
	 **/
	function getConfiguration(address asset) public view returns (DataTypes.ReserveConfigurationMap memory) {
		return lendingPool.getConfiguration(asset);
	}

	/**
	 * @dev Returns variable debt token address of asset
	 * @param asset The address of the underlying asset of the reserve
	 * @return varaiableDebtToken address of the asset
	 **/
	function getVDebtToken(address asset) external view returns (address) {
		DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(asset);
		return reserveData.variableDebtTokenAddress;
	}

	/**
	 * @dev Returns loan to value
	 * @param asset The address of the underlying asset of the reserve
	 * @return ltv of the asset
	 **/
	function ltv(address asset) external view returns (uint256) {
		DataTypes.ReserveConfigurationMap memory conf = getConfiguration(asset);
		return conf.data % TWO_POW_16;
	}

	/**
	 * @dev Loop the deposit and borrow of an asset
	 * @param asset for loop
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param borrowRatio Ratio of tokens to borrow
	 * @param loopCount Repeat count for loop
	 * @param isBorrow true when the loop without deposit tokens
	 **/
	function loop(
		address asset,
		uint256 amount,
		uint256 interestRateMode,
		uint256 borrowRatio,
		uint256 loopCount,
		bool isBorrow
	) external {
		if (!(borrowRatio > 0 && borrowRatio <= RATIO_DIVISOR)) revert InvalidRatio();
		if (loopCount == 0) revert InvalidLoopCount();
		uint16 referralCode = 0;
		uint256 fee;
		if (!isBorrow) {
			IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
			fee = (amount * feePercent) / RATIO_DIVISOR;
			if (fee > 0) {
				IERC20(asset).safeTransfer(treasury, fee);
				amount = amount - fee;
			}
		}
		_approve(asset);

		cic.setEligibilityExempt(msg.sender, true);

		if (!isBorrow) {
			lendingPool.deposit(asset, amount, msg.sender, referralCode);
		} else {
			amount = (amount * RATIO_DIVISOR) / borrowRatio;
		}

		for (uint256 i = 0; i < loopCount; ) {
			// Reenable on last deposit
			if (i == (loopCount - 1)) {
				cic.setEligibilityExempt(msg.sender, false);
			}

			amount = (amount * borrowRatio) / RATIO_DIVISOR;
			lendingPool.borrow(asset, amount, interestRateMode, referralCode, msg.sender);

			fee = (amount * feePercent) / RATIO_DIVISOR;
			if (fee > 0) {
				IERC20(asset).safeTransfer(treasury, fee);
				amount = amount - fee;
			}

			lendingPool.deposit(asset, amount, msg.sender, referralCode);
			unchecked {
				i++;
			}
		}
		zapWETHWithBorrow(wethToZap(msg.sender), msg.sender);
	}

	/**
	 * @dev Loop the deposit and borrow of ETH
	 * @param interestRateMode stable or variable borrow mode
	 * @param borrowRatio Ratio of tokens to borrow
	 * @param loopCount Repeat count for loop
	 **/
	function loopETH(uint256 interestRateMode, uint256 borrowRatio, uint256 loopCount) external payable {
		if (!(borrowRatio > 0 && borrowRatio <= RATIO_DIVISOR)) revert InvalidRatio();
		if (loopCount == 0) revert InvalidLoopCount();
		uint16 referralCode = 0;
		uint256 amount = msg.value;
		_approve(address(weth));

		uint256 fee = (amount * feePercent) / RATIO_DIVISOR;
		if (fee > 0) {
			TransferHelper.safeTransferETH(treasury, fee);
			amount = amount - fee;
		}

		cic.setEligibilityExempt(msg.sender, true);

		weth.deposit{value: amount}();
		lendingPool.deposit(address(weth), amount, msg.sender, referralCode);

		for (uint256 i = 0; i < loopCount; ) {
			// Reenable on last deposit
			if (i == (loopCount - 1)) {
				cic.setEligibilityExempt(msg.sender, false);
			}

			amount = (amount * borrowRatio) / RATIO_DIVISOR;
			lendingPool.borrow(address(weth), amount, interestRateMode, referralCode, msg.sender);

			fee = (amount * feePercent) / RATIO_DIVISOR;
			if (fee > 0) {
				weth.withdraw(fee);
				TransferHelper.safeTransferETH(treasury, fee);
				amount = amount - fee;
			}

			lendingPool.deposit(address(weth), amount, msg.sender, referralCode);
			unchecked {
				i++;
			}
		}
		zapWETHWithBorrow(wethToZap(msg.sender), msg.sender);
	}

	/**
	 * @dev Loop the borrow and deposit of ETH
	 * @param interestRateMode stable or variable borrow mode
	 * @param amount initial amount to borrow
	 * @param borrowRatio Ratio of tokens to borrow
	 * @param loopCount Repeat count for loop
	 **/
	function loopETHFromBorrow(
		uint256 interestRateMode,
		uint256 amount,
		uint256 borrowRatio,
		uint256 loopCount
	) external {
		if (!(borrowRatio > 0 && borrowRatio <= RATIO_DIVISOR)) revert InvalidRatio();
		if (loopCount == 0) revert InvalidLoopCount();
		uint16 referralCode = 0;
		_approve(address(weth));

		uint256 fee;

		cic.setEligibilityExempt(msg.sender, true);

		for (uint256 i = 0; i < loopCount; ) {
			// Reenable on last deposit
			if (i == (loopCount - 1)) {
				cic.setEligibilityExempt(msg.sender, false);
			}

			lendingPool.borrow(address(weth), amount, interestRateMode, referralCode, msg.sender);

			fee = (amount * feePercent) / RATIO_DIVISOR;
			if (fee > 0) {
				weth.withdraw(fee);
				TransferHelper.safeTransferETH(treasury, fee);
				amount = amount - fee;
			}

			lendingPool.deposit(address(weth), amount, msg.sender, referralCode);

			amount = (amount * borrowRatio) / RATIO_DIVISOR;
			unchecked {
				i++;
			}
		}
		zapWETHWithBorrow(wethToZap(msg.sender), msg.sender);
	}

	/**
	 * @notice Return estimated zap WETH amount for eligbility after loop.
	 * @param user for zap
	 * @param asset src token
	 * @param amount of `asset`
	 * @param borrowRatio Single ratio of borrow
	 * @param loopCount Repeat count for loop
	 * @return WETH amount
	 **/
	function wethToZapEstimation(
		address user,
		address asset,
		uint256 amount,
		uint256 borrowRatio,
		uint256 loopCount
	) external view returns (uint256) {
		if (asset == API_ETH_MOCK_ADDRESS) {
			asset = address(weth);
		}
		uint256 required = eligibilityDataProvider.requiredUsdValue(user);
		uint256 locked = eligibilityDataProvider.lockedUsdValue(user);

		uint256 fee = (amount * feePercent) / RATIO_DIVISOR;
		amount = amount - fee;

		required = required + _requiredLocked(asset, amount);

		for (uint256 i = 0; i < loopCount; ) {
			amount = (amount * borrowRatio) / RATIO_DIVISOR;
			fee = (amount * feePercent) / RATIO_DIVISOR;
			amount = amount - fee;
			required = required + _requiredLocked(asset, amount);
			unchecked {
				i++;
			}
		}
		return _calcWethAmount(locked, required);
	}

	/**
	 * @notice Return estimated zap WETH amount for eligbility.
	 * @param user for zap
	 * @return WETH amount
	 **/
	function wethToZap(address user) public view returns (uint256) {
		uint256 required = eligibilityDataProvider.requiredUsdValue(user);
		uint256 locked = eligibilityDataProvider.lockedUsdValue(user);
		return _calcWethAmount(locked, required);
	}

	/**
	 * @notice Zap WETH by borrowing.
	 * @param amount to zap
	 * @param borrower to zap
	 * @return liquidity amount by zapping
	 **/
	function zapWETHWithBorrow(uint256 amount, address borrower) public returns (uint256 liquidity) {
		if (msg.sender != borrower && msg.sender != address(lendingPool)) revert InsufficientPermission();

		if (amount > 0) {
			uint16 referralCode = 0;
			lendingPool.borrow(address(weth), amount, INTEREST_RATE_MODE, referralCode, borrower);
			if (IERC20(address(weth)).allowance(address(this), address(lockZap)) == 0) {
				IERC20(address(weth)).forceApprove(address(lockZap), type(uint256).max);
			}
			// Using default slippage value
			liquidity = lockZap.zapOnBehalf(false, address(0), amount, 0, borrower, 0);
		}
	}

	/**
	 * @notice Set the CIC contract address
	 * @param _cic CIC contract address
	 */
	function setChefIncentivesController(IChefIncentivesController _cic) external onlyOwner {
		if (address(_cic) == address(0)) revert AddressZero();
		cic = _cic;
	}

	/**
	 * @notice Returns required LP lock amount.
	 * @param asset underlying asset
	 * @param amount of tokens
	 * @return Required lock value
	 **/
	function _requiredLocked(address asset, uint256 amount) internal view returns (uint256) {
		uint256 assetPrice = aaveOracle.getAssetPrice(asset);
		uint8 assetDecimal = IERC20Metadata(asset).decimals();
		uint256 requiredVal = (((assetPrice * amount) / (10 ** assetDecimal)) *
			eligibilityDataProvider.requiredDepositRatio()) / eligibilityDataProvider.RATIO_DIVISOR();
		return requiredVal;
	}

	/**
	 * @notice Approves token allowance of `lendingPool` and `treasury`.
	 * @param asset underlyig asset
	 **/
	function _approve(address asset) internal {
		if (IERC20(asset).allowance(address(this), address(lendingPool)) == 0) {
			IERC20(asset).forceApprove(address(lendingPool), type(uint256).max);
		}
		if (IERC20(asset).allowance(address(this), address(treasury)) == 0) {
			IERC20(asset).forceApprove(treasury, type(uint256).max);
		}
	}

	/**
	 * @notice Calculated needed WETH amount to be eligible.
	 * @param locked usd value
	 * @param required usd value
	 **/
	function _calcWethAmount(uint256 locked, uint256 required) internal view returns (uint256 wethAmount) {
		if (locked < required) {
			uint256 deltaUsdValue = required - locked; //decimals === 8
			uint256 wethPrice = aaveOracle.getAssetPrice(address(weth));
			uint8 priceDecimal = IChainlinkAggregator(aaveOracle.getSourceOfAsset(address(weth))).decimals();
			wethAmount = (deltaUsdValue * (10 ** 18) * (10 ** priceDecimal)) / wethPrice / (10 ** 8);
			wethAmount = wethAmount + ((wethAmount * ZAP_MARGIN_ESTIMATION) / 100);
		}
	}
}
