// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {DustRefunder} from "./helpers/DustRefunder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import {IMultiFeeDistribution} from "../../interfaces/IMultiFeeDistribution.sol";
import {ILendingPool, DataTypes} from "../../interfaces/ILendingPool.sol";
import {IPoolHelper} from "../../interfaces/IPoolHelper.sol";
import {IPriceProvider} from "../../interfaces/IPriceProvider.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IWETH} from "../../interfaces/IWETH.sol";
import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {UniV2Helper} from "../libraries/UniV2Helper.sol";

/// @title LockZap contract
/// @author Radiant
contract LockZap is Initializable, OwnableUpgradeable, PausableUpgradeable, DustRefunder {
	using SafeERC20 for IERC20;

	/// @notice The maximum amount of slippage that a user can set for the execution of Zaps
	/// @dev If the slippage limit of the LockZap contract is lower then that of the Compounder, transactions might fail unexpectedly.
	///      Therefore ensure that this slippage limit is equal to that of the Compounder contract.
	uint256 public constant MAX_SLIPPAGE = 9000; // 10%

	/// @notice RATIO Divisor
	uint256 public constant RATIO_DIVISOR = 10000;

	/// @notice Base Percent
	uint256 public constant BASE_PERCENT = 100;

	/// @notice Borrow rate mode
	uint256 public constant VARIABLE_INTEREST_RATE_MODE = 2;

	/// @notice We don't utilize any specific referral code for borrows perfomed via zaps
	uint16 public constant REFERRAL_CODE = 0;

	/// @notice Wrapped ETH
	IWETH public weth;

	/// @notice RDNT token address
	address public rdntAddr;

	/// @notice Multi Fee distribution contract
	IMultiFeeDistribution public mfd;

	/// @notice Lending Pool contract
	ILendingPool public lendingPool;

	/// @notice Pool helper contract used for RDNT-WETH swaps
	IPoolHelper public poolHelper;

	/// @notice Price provider contract
	IPriceProvider public priceProvider;

	/// @notice aave oracle contract
	IAaveOracle public aaveOracle;

	/// @notice parameter to set the ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
	uint256 public ethLPRatio;

	/// @notice AMM router used for all non RDNT-WETH swaps on Arbitrum
	address public uniRouter;

	/********************** Events ***********************/
	/// @notice Emitted when zap is done
	event Zapped(
		bool _borrow,
		uint256 _ethAmt,
		uint256 _rdntAmt,
		address indexed _from,
		address indexed _onBehalf,
		uint256 _lockTypeIndex
	);

	event PriceProviderUpdated(address indexed _provider);

	event MfdUpdated(address indexed _mfdAddr);

	event PoolHelperUpdated(address indexed _poolHelper);

	event UniRouterUpdated(address indexed _uniRouter);

	/********************** Errors ***********************/
	error AddressZero();

	error InvalidRatio();

	error InvalidLockLength();

	error AmountZero();

	error SlippageTooHigh();

	error SpecifiedSlippageExceedLimit();

	error InvalidZapETHSource();

	error ReceivedETHOnAlternativeAssetZap();

	error InsufficientETH();

	error EthTransferFailed();

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _rndtPoolHelper Pool helper address used for RDNT-WETH swaps
	 * @param _uniRouter UniV2 router address used for all non RDNT-WETH swaps
	 * @param _lendingPool Lending pool
	 * @param _weth weth address
	 * @param _rdntAddr RDNT token address
	 * @param _ethLPRatio ratio of ETH in the LP token, can be 2000 for an 80/20 bal lp
	 * @param _aaveOracle Aave oracle address
	 */
	function initialize(
		IPoolHelper _rndtPoolHelper,
		address _uniRouter,
		ILendingPool _lendingPool,
		IWETH _weth,
		address _rdntAddr,
		uint256 _ethLPRatio,
		IAaveOracle _aaveOracle
	) external initializer {
		if (address(_rndtPoolHelper) == address(0)) revert AddressZero();
		if (address(_uniRouter) == address(0)) revert AddressZero();
		if (address(_lendingPool) == address(0)) revert AddressZero();
		if (address(_weth) == address(0)) revert AddressZero();
		if (_rdntAddr == address(0)) revert AddressZero();
		if (_ethLPRatio == 0 || _ethLPRatio >= RATIO_DIVISOR) revert InvalidRatio();
		if (address(_aaveOracle) == address(0)) revert AddressZero();

		__Ownable_init();
		__Pausable_init();

		lendingPool = _lendingPool;
		poolHelper = _rndtPoolHelper;
		uniRouter = _uniRouter;
		weth = _weth;
		rdntAddr = _rdntAddr;
		ethLPRatio = _ethLPRatio;
		aaveOracle = _aaveOracle;
	}

	receive() external payable {}

	/**
	 * @notice Set Price Provider.
	 * @param _provider Price provider contract address.
	 */
	function setPriceProvider(address _provider) external onlyOwner {
		if (_provider == address(0)) revert AddressZero();
		priceProvider = IPriceProvider(_provider);
		emit PriceProviderUpdated(_provider);
	}

	/**
	 * @notice Set AAVE Oracle used to fetch asset prices in USD.
	 * @param _aaveOracle oracle contract address.
	 */
	function setAaveOracle(address _aaveOracle) external onlyOwner {
		if (_aaveOracle == address(0)) revert AddressZero();
		aaveOracle = IAaveOracle(_aaveOracle);
	}

	/**
	 * @notice Set Multi fee distribution contract.
	 * @param _mfdAddr New contract address.
	 */
	function setMfd(address _mfdAddr) external onlyOwner {
		if (_mfdAddr == address(0)) revert AddressZero();
		mfd = IMultiFeeDistribution(_mfdAddr);
		emit MfdUpdated(_mfdAddr);
	}

	/**
	 * @notice Set Pool Helper contract used fror WETH-RDNT swaps
	 * @param _poolHelper New PoolHelper contract address.
	 */
	function setPoolHelper(address _poolHelper) external onlyOwner {
		if (_poolHelper == address(0)) revert AddressZero();
		poolHelper = IPoolHelper(_poolHelper);
		emit PoolHelperUpdated(_poolHelper);
	}

	/**
	 * @notice Set Univ2 style router contract address used for all non RDNT<>WETH swaps
	 * @param _uniRouter New PoolHelper contract address.
	 */
	function setUniRouter(address _uniRouter) external onlyOwner {
		if (_uniRouter == address(0)) revert AddressZero();
		uniRouter = _uniRouter;
		emit UniRouterUpdated(_uniRouter);
	}

	/**
	 * @notice Returns pool helper address used for RDNT-WETH swaps
	 */
	function getPoolHelper() external view returns (address) {
		return address(poolHelper);
	}

	/**
	 * @notice Returns uni router address used for all non RDNT-WETH swaps
	 */
	function getUniRouter() external view returns (address) {
		return address(uniRouter);
	}

	/**
	 * @notice Get Variable debt token address
	 * @param _asset underlying.
	 */
	function getVDebtToken(address _asset) external view returns (address) {
		DataTypes.ReserveData memory reserveData = lendingPool.getReserveData(_asset);
		return reserveData.variableDebtTokenAddress;
	}

	/**
	 * @notice Calculate amount of specified tokens received for selling RDNT
	 * @dev this function is mainly used to calculate how much of the specified token is needed to match the provided RDNT amount when providing liquidity to an AMM
	 * @param _token address of the token that would be received
	 * @param _amount of RDNT to be sold
	 * @return amount of _token received
	 */
	function quoteFromToken(address _token, uint256 _amount) public view returns (uint256) {
		address weth_ = address(weth);
		if (_token != weth_) {
			uint256 wethAmount = poolHelper.quoteFromToken(_amount);
			return UniV2Helper._quoteSwap(uniRouter, weth_, _token, wethAmount);
		}
		return poolHelper.quoteFromToken(_amount);
	}

	/**
	 * @notice Zap tokens to stake LP
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for zapping
	 * @param _assetAmt amount of weth.
	 * @param _rdntAmt amount of RDNT.
	 * @param _lockTypeIndex lock length index.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function zap(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _rdntAmt,
		uint256 _lockTypeIndex,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		return
			_zap(_borrow, _asset, _assetAmt, _rdntAmt, msg.sender, msg.sender, _lockTypeIndex, msg.sender, _slippage);
	}

	/**
	 * @notice Zap tokens to stake LP
	 * @dev It will use default lock index
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for zapping
	 * @param _assetAmt amount of weth.
	 * @param _rdntAmt amount of RDNT.
	 * @param _onBehalf user address to be zapped.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function zapOnBehalf(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _rdntAmt,
		address _onBehalf,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		uint256 duration = mfd.defaultLockIndex(_onBehalf);
		return _zap(_borrow, _asset, _assetAmt, _rdntAmt, msg.sender, _onBehalf, duration, _onBehalf, _slippage);
	}

	/**
	 * @notice Zap tokens from vesting
	 * @param _borrow option to borrow ETH
	 * @param _asset to be used for zapping
	 * @param _assetAmt amount of _asset tokens used to create dLP position
	 * @param _lockTypeIndex lock length index. cannot be shortest option (index 0)
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return LP amount
	 */
	function zapFromVesting(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _lockTypeIndex,
		uint256 _slippage
	) public payable whenNotPaused returns (uint256) {
		if (_lockTypeIndex == 0) revert InvalidLockLength();
		uint256 rdntAmt = mfd.zapVestingToLp(msg.sender);

		return
			_zap(_borrow, _asset, _assetAmt, rdntAmt, address(this), msg.sender, _lockTypeIndex, msg.sender, _slippage);
	}

	/**
	 * @notice Calculates slippage ratio from usd value to LP
	 * @param _assetValueUsd amount value in USD used to create LP pair
	 * @param _liquidity LP token amount
	 */
	function _calcSlippage(uint256 _assetValueUsd, uint256 _liquidity) internal returns (uint256 ratio) {
		priceProvider.update();
		uint256 lpAmountValueUsd = (_liquidity * priceProvider.getLpTokenPriceUsd()) / 1E18;
		ratio = (lpAmountValueUsd * (RATIO_DIVISOR)) / (_assetValueUsd);
	}

	/**
	 * @notice Zap into LP
	 * @param _borrow option to borrow ETH
	 * @param _asset that will be used to zap.
	 * @param _assetAmt amount of assets to be zapped
	 * @param _rdntAmt amount of RDNT.
	 * @param _from src address of RDNT
	 * @param _onBehalf of the user.
	 * @param _lockTypeIndex lock length index.
	 * @param _refundAddress dust is refunded to this address.
	 * @param _slippage maximum amount of slippage allowed for any occurring trades
	 * @return liquidity LP amount
	 */
	function _zap(
		bool _borrow,
		address _asset,
		uint256 _assetAmt,
		uint256 _rdntAmt,
		address _from,
		address _onBehalf,
		uint256 _lockTypeIndex,
		address _refundAddress,
		uint256 _slippage
	) internal returns (uint256 liquidity) {
		IWETH weth_ = weth;
		if (_asset == address(0)) {
			_asset = address(weth_);
		}
		if (_slippage == 0) {
			_slippage = MAX_SLIPPAGE;
		} else {
			if (MAX_SLIPPAGE > _slippage || _slippage > RATIO_DIVISOR) revert SpecifiedSlippageExceedLimit();
		}
		bool isAssetWeth = _asset == address(weth_);

		// Handle pure ETH
		if (msg.value > 0) {
			if (!isAssetWeth) revert ReceivedETHOnAlternativeAssetZap();
			if (_borrow) revert InvalidZapETHSource();
			_assetAmt = msg.value;
			weth_.deposit{value: _assetAmt}();
		}
		if (_assetAmt == 0) revert AmountZero();
		uint256 assetAmountValueUsd = (_assetAmt * aaveOracle.getAssetPrice(_asset)) /
			(10 ** IERC20Metadata(_asset).decimals());

		// Handle borrowing logic
		if (_borrow) {
			// Borrow the asset on the users behalf
			lendingPool.borrow(_asset, _assetAmt, VARIABLE_INTEREST_RATE_MODE, REFERRAL_CODE, msg.sender);

			// If asset isn't WETH, swap for WETH
			if (!isAssetWeth) {
				_assetAmt = UniV2Helper._swap(uniRouter, _asset, address(weth_), _assetAmt);
			}
		} else if (msg.value == 0) {
			// Transfer asset from user
			IERC20(_asset).safeTransferFrom(msg.sender, address(this), _assetAmt);
			if (!isAssetWeth) {
				_assetAmt = UniV2Helper._swap(uniRouter, _asset, address(weth_), _assetAmt);
			}
		}

		weth_.approve(address(poolHelper), _assetAmt);
		//case where rdnt is matched with provided ETH
		if (_rdntAmt != 0) {
			// _from == this when zapping from vesting
			if (_from != address(this)) {
				IERC20(rdntAddr).safeTransferFrom(msg.sender, address(this), _rdntAmt);
			}

			IERC20(rdntAddr).forceApprove(address(poolHelper), _rdntAmt);
			liquidity = poolHelper.zapTokens(_assetAmt, _rdntAmt);
			assetAmountValueUsd = (assetAmountValueUsd * RATIO_DIVISOR) / ethLPRatio;
		} else {
			liquidity = poolHelper.zapWETH(_assetAmt);
		}

		if (address(priceProvider) != address(0)) {
			if (_calcSlippage(assetAmountValueUsd, liquidity) < _slippage) revert SlippageTooHigh();
		}

		IERC20(poolHelper.lpTokenAddr()).forceApprove(address(mfd), liquidity);
		mfd.stake(liquidity, _onBehalf, _lockTypeIndex);
		emit Zapped(_borrow, _assetAmt, _rdntAmt, _from, _onBehalf, _lockTypeIndex);

		_refundDust(rdntAddr, _asset, _refundAddress);
	}

	/**
	 * @notice Pause zapping operation.
	 */
	function pause() external onlyOwner {
		_pause();
	}

	/**
	 * @notice Unpause zapping operation.
	 */
	function unpause() external onlyOwner {
		_unpause();
	}

	/**
	 * @notice Allows owner to recover ETH locked in this contract.
	 * @param to ETH receiver
	 * @param value ETH amount
	 */
	function withdrawLockedETH(address to, uint256 value) external onlyOwner {
		TransferHelper.safeTransferETH(to, value);
	}
}
