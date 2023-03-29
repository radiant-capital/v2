// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../../interfaces/ILendingPool.sol";
import "../../interfaces/IEligibilityDataProvider.sol";
import "../../interfaces/IChainlinkAggregator.sol";
import "../../interfaces/IChefIncentivesController.sol";
import "../../interfaces/ILockZap.sol";
import "../../interfaces/IAaveOracle.sol";
import "../../interfaces/IWETH.sol";

/// @title Leverager Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract Leverager is Ownable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	/// @notice Ratio Divisor
	uint256 public constant RATIO_DIVISOR = 10000;

	/// @notice Mock ETH address
	address public constant API_ETH_MOCK_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

	/// @notice Lending Pool address
	ILendingPool public lendingPool;

	/// @notice EligibilityDataProvider contract address
	IEligibilityDataProvider public eligibilityDataProvider;

	/// @notice LockZap contract address
	ILockZap public lockZap;

	/// @notice ChefIncentivesController contract address
	IChefIncentivesController public cic;

	/// @notice Wrapped ETH contract address
	IWETH public weth;

	/// @notice Aave oracle address
	IAaveOracle public aaveOracle;

	/// @notice Fee ratio
	uint256 public feePercent;

	/// @notice Treasury address
	address public treasury;

	/// @notice Emitted when fee ratio is updated
	event FeePercentUpdated(uint256 _feePercent);

	/// @notice Emitted when treasury is updated
	event TreasuryUpdated(address indexed _treasury);

	/**
	 * @notice Constructor
	 * @param _lendingPool Address of lending pool.
	 * @param _rewardEligibleDataProvider EligibilityProvider address.
	 * @param _aaveOracle address.
	 * @param _lockZap address.
	 * @param _weth WETH address.
	 * @param _feePercent leveraging fee ratio.
	 * @param _treasury address.
	 */
	constructor(
		ILendingPool _lendingPool,
		IEligibilityDataProvider _rewardEligibleDataProvider,
		IAaveOracle _aaveOracle,
		ILockZap _lockZap,
		IChefIncentivesController _cic,
		IWETH _weth,
		uint256 _feePercent,
		address _treasury
	) {
		require(address(_lendingPool) != (address(0)), "Not a valid address");
		require(address(_rewardEligibleDataProvider) != (address(0)), "Not a valid address");
		require(address(_aaveOracle) != (address(0)), "Not a valid address");
		require(address(_lockZap) != (address(0)), "Not a valid address");
		require(address(_cic) != (address(0)), "Not a valid address");
		require(address(_weth) != (address(0)), "Not a valid address");
		require(_treasury != address(0), "Not a valid address");
		require(_feePercent <= 1e4, "Invalid ratio");

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
		require(msg.sender == address(weth), "Receive not allowed");
	}

	/**
	 * @dev Revert fallback calls
	 */
	fallback() external payable {
		revert("Fallback not allowed");
	}

	/**
	 * @notice Sets fee ratio
	 * @param _feePercent fee ratio.
	 */
	function setFeePercent(uint256 _feePercent) external onlyOwner {
		require(_feePercent <= 1e4, "Invalid ratio");
		feePercent = _feePercent;
		emit FeePercentUpdated(_feePercent);
	}

	/**
	 * @notice Sets fee ratio
	 * @param _treasury address
	 */
	function setTreasury(address _treasury) external onlyOwner {
		require(_treasury != address(0), "treasury is 0 address");
		treasury = _treasury;
		emit TreasuryUpdated(_treasury);
	}

	/**
	 * @dev Returns the configuration of the reserve
	 * @param asset The address of the underlying asset of the reserve
	 * @return The configuration of the reserve
	 **/
	function getConfiguration(address asset) external view returns (DataTypes.ReserveConfigurationMap memory) {
		return lendingPool.getConfiguration(asset);
	}

	/**
	 * @dev Returns variable debt token address of asset
	 * @param asset The address of the underlying asset of the reserve
	 * @return varaiableDebtToken address of the asset
	 **/
	function getVDebtToken(address asset) public view returns (address) {
		DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(asset);
		return reserveData.variableDebtTokenAddress;
	}

	/**
	 * @dev Returns loan to value
	 * @param asset The address of the underlying asset of the reserve
	 * @return ltv of the asset
	 **/
	function ltv(address asset) public view returns (uint256) {
		DataTypes.ReserveConfigurationMap memory conf = lendingPool.getConfiguration(asset);
		return conf.data % (2 ** 16);
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
		require(borrowRatio <= RATIO_DIVISOR, "Invalid ratio");
		uint16 referralCode = 0;
		uint256 fee;
		if (!isBorrow) {
			IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
			fee = amount.mul(feePercent).div(RATIO_DIVISOR);
			IERC20(asset).safeTransfer(treasury, fee);
			amount = amount.sub(fee);
		}
		if (IERC20(asset).allowance(address(this), address(lendingPool)) == 0) {
			IERC20(asset).safeApprove(address(lendingPool), type(uint256).max);
		}
		if (IERC20(asset).allowance(address(this), address(treasury)) == 0) {
			IERC20(asset).safeApprove(treasury, type(uint256).max);
		}

		if (!isBorrow) {
			lendingPool.deposit(asset, amount, msg.sender, referralCode);
		}

		cic.setEligibilityExempt(msg.sender, true);

		for (uint256 i = 0; i < loopCount; i += 1) {
			amount = amount.mul(borrowRatio).div(RATIO_DIVISOR);
			lendingPool.borrow(asset, amount, interestRateMode, referralCode, msg.sender);

			fee = amount.mul(feePercent).div(RATIO_DIVISOR);
			IERC20(asset).safeTransfer(treasury, fee);
			lendingPool.deposit(asset, amount.sub(fee), msg.sender, referralCode);
		}

		cic.setEligibilityExempt(msg.sender, false);

		zapWETHWithBorrow(wethToZap(msg.sender), msg.sender);
	}

	/**
	 * @dev Loop the deposit and borrow of ETH
	 * @param interestRateMode stable or variable borrow mode
	 * @param borrowRatio Ratio of tokens to borrow
	 * @param loopCount Repeat count for loop
	 **/
	function loopETH(uint256 interestRateMode, uint256 borrowRatio, uint256 loopCount) external payable {
		require(borrowRatio <= RATIO_DIVISOR, "Invalid ratio");
		uint16 referralCode = 0;
		uint256 amount = msg.value;
		if (IERC20(address(weth)).allowance(address(this), address(lendingPool)) == 0) {
			IERC20(address(weth)).safeApprove(address(lendingPool), type(uint256).max);
		}
		if (IERC20(address(weth)).allowance(address(this), address(treasury)) == 0) {
			IERC20(address(weth)).safeApprove(treasury, type(uint256).max);
		}

		uint256 fee = amount.mul(feePercent).div(RATIO_DIVISOR);
		_safeTransferETH(treasury, fee);

		amount = amount.sub(fee);

		weth.deposit{value: amount}();
		lendingPool.deposit(address(weth), amount, msg.sender, referralCode);

		for (uint256 i = 0; i < loopCount; i += 1) {
			amount = amount.mul(borrowRatio).div(RATIO_DIVISOR);
			lendingPool.borrow(address(weth), amount, interestRateMode, referralCode, msg.sender);
			weth.withdraw(amount);

			fee = amount.mul(feePercent).div(RATIO_DIVISOR);
			_safeTransferETH(treasury, fee);

			weth.deposit{value: amount.sub(fee)}();
			lendingPool.deposit(address(weth), amount.sub(fee), msg.sender, referralCode);
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

		uint256 fee = amount.mul(feePercent).div(RATIO_DIVISOR);
		amount = amount.sub(fee);

		required = required.add(requiredLocked(asset, amount));

		for (uint256 i = 0; i < loopCount; i += 1) {
			amount = amount.mul(borrowRatio).div(RATIO_DIVISOR);
			fee = amount.mul(feePercent).div(RATIO_DIVISOR);
			required = required.add(requiredLocked(asset, amount.sub(fee)));
		}

		if (locked >= required) {
			return 0;
		} else {
			uint256 deltaUsdValue = required.sub(locked); //decimals === 8
			uint256 wethPrice = aaveOracle.getAssetPrice(address(weth));
			uint8 priceDecimal = IChainlinkAggregator(aaveOracle.getSourceOfAsset(address(weth))).decimals();
			uint256 wethAmount = deltaUsdValue.mul(10 ** 18).mul(10 ** priceDecimal).div(wethPrice).div(10 ** 8);
			wethAmount = wethAmount.add(wethAmount.mul(6).div(100));
			return wethAmount;
		}
	}

	/**
	 * @notice Return estimated zap WETH amount for eligbility.
	 * @param user for zap
	 **/
	function wethToZap(address user) public view returns (uint256) {
		uint256 required = eligibilityDataProvider.requiredUsdValue(user);
		uint256 locked = eligibilityDataProvider.lockedUsdValue(user);
		if (locked >= required) {
			return 0;
		} else {
			uint256 deltaUsdValue = required.sub(locked); //decimals === 8
			uint256 wethPrice = aaveOracle.getAssetPrice(address(weth));
			uint8 priceDecimal = IChainlinkAggregator(aaveOracle.getSourceOfAsset(address(weth))).decimals();
			uint256 wethAmount = deltaUsdValue.mul(10 ** 18).mul(10 ** priceDecimal).div(wethPrice).div(10 ** 8);
			wethAmount = wethAmount.add(wethAmount.mul(6).div(100));
			return wethAmount;
		}
	}

	/**
	 * @notice Zap WETH by borrowing.
	 * @param amount to zap
	 * @param borrower to zap
	 * @return liquidity amount by zapping
	 **/
	function zapWETHWithBorrow(uint256 amount, address borrower) public returns (uint256 liquidity) {
		require(msg.sender == borrower || msg.sender == address(lendingPool), "!borrower||lendingpool");

		if (amount > 0) {
			uint16 referralCode = 0;
			lendingPool.borrow(address(weth), amount, 2, referralCode, borrower);
			if (IERC20(address(weth)).allowance(address(this), address(lockZap)) == 0) {
				IERC20(address(weth)).safeApprove(address(lockZap), type(uint256).max);
			}
			liquidity = lockZap.zapOnBehalf(false, amount, 0, borrower);
		}
	}

	/**
	 * @notice Returns required LP lock amount.
	 * @param asset underlyig asset
	 * @param amount of tokens
	 **/
	function requiredLocked(address asset, uint256 amount) internal view returns (uint256) {
		uint256 assetPrice = aaveOracle.getAssetPrice(asset);
		uint8 assetDecimal = IERC20Metadata(asset).decimals();
		uint256 requiredVal = assetPrice
			.mul(amount)
			.div(10 ** assetDecimal)
			.mul(eligibilityDataProvider.requiredDepositRatio())
			.div(eligibilityDataProvider.RATIO_DIVISOR());
		return requiredVal;
	}

	/**
	 * @dev transfer ETH to an address, revert if it fails.
	 * @param to recipient of the transfer
	 * @param value the amount to send
	 */
	function _safeTransferETH(address to, uint256 value) internal {
		(bool success, ) = to.call{value: value}(new bytes(0));
		require(success, "ETH_TRANSFER_FAILED");
	}
}
