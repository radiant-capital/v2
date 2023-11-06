// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
import {IBaseOracle} from "../../interfaces/IBaseOracle.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IAToken} from "../../interfaces/IAToken.sol";
import {IChainlinkAdapter} from "../../interfaces/IChainlinkAdapter.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolHelper} from "../../interfaces/IPoolHelper.sol";

/// @title PriceProvider Contract
/// @author Radiant
contract PriceProvider is Initializable, OwnableUpgradeable {
	uint8 public constant DECIMALS = 18;

	/// @notice Chainlink aggregator for USD price of base token
	IChainlinkAdapter public baseAssetChainlinkAdapter;

	/// @notice Pool helper contract - Uniswap/Balancer
	IPoolHelper public poolHelper;

	/// @notice Selected RDNT Oracle
	IBaseOracle public oracle;

	bool public usePool;

	/// @notice price oracle utilized by the radiant lending protocol
	IAaveOracle public aaveOracle;

	error AddressZero();

	error InvalidOracle();

	/********************** Events ***********************/

	event OracleUpdated(address indexed _newOracle);

	event PoolHelperUpdated(address indexed _poolHelper);

	event AggregatorUpdated(address indexed _baseTokenPriceInUsdProxyAggregator);

	event UsePoolUpdated(bool indexed _usePool);

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _baseAssetChainlinkAdapter Chainlink aggregator for USD price of base token
	 * @param _poolHelper Pool helper contract - Uniswap/Balancer
	 * @param _aaveOracle Price oralce utilized by the radiant lending protocol
	 */
	function initialize(
		IChainlinkAdapter _baseAssetChainlinkAdapter,
		IPoolHelper _poolHelper,
		IAaveOracle _aaveOracle
	) public initializer {
		if (address(_baseAssetChainlinkAdapter) == (address(0))) revert AddressZero();
		if (address(_poolHelper) == (address(0))) revert AddressZero();
		__Ownable_init();

		poolHelper = _poolHelper;
		baseAssetChainlinkAdapter = IChainlinkAdapter(_baseAssetChainlinkAdapter);
		usePool = true;
		aaveOracle = _aaveOracle;
	}

	/**
	 * @notice Update oracles.
	 */
	function update() public {
		if (address(oracle) != address(0) && oracle.canUpdate()) {
			oracle.update();
		}
	}

	/**
	 * @notice Returns the latest price in eth.
	 */
	function getTokenPrice() public view returns (uint256 priceInEth) {
		if (usePool) {
			// use sparingly, TWAP/CL otherwise
			priceInEth = poolHelper.getPrice();
		} else {
			priceInEth = oracle.latestAnswerInEth();
		}
	}

	/**
	 * @notice Returns the latest price in USD.
	 */
	function getTokenPriceUsd() public view returns (uint256 price) {
		// use sparingly, TWAP/CL otherwise
		if (usePool) {
			uint256 ethPrice = baseAssetChainlinkAdapter.latestAnswer();
			uint256 priceInEth = poolHelper.getPrice();
			price = (priceInEth * uint256(ethPrice)) / (10 ** 8);
		} else {
			price = oracle.latestAnswer();
		}
	}

	/**
	 * @notice Returns lp token price in ETH.
	 */
	function getLpTokenPrice() public view returns (uint256) {
		// decis 8
		uint256 rdntPriceInEth = getTokenPrice();
		return poolHelper.getLpPrice(rdntPriceInEth);
	}

	/**
	 * @notice Returns lp token price in USD.
	 */
	function getLpTokenPriceUsd() public view returns (uint256 price) {
		// decimals 8
		uint256 lpPriceInEth = getLpTokenPrice();
		// decimals 8
		uint256 ethPrice = baseAssetChainlinkAdapter.latestAnswer();
		price = (lpPriceInEth * uint256(ethPrice)) / (10 ** 8);
	}

	/**
	 * @notice Returns lp token address.
	 */
	function getLpTokenAddress() public view returns (address) {
		return poolHelper.lpTokenAddr();
	}

	/**
	 * @notice Returns the USD value of a provided token and token amount.
	 * @dev This function checks if the provided token is an rToken, if yes it returns the price for the underlying asset
	 * @param rewardToken Address of the token to get the price for
	 * @param amount Amount of the token to get the price for
	 */
	function getRewardTokenPrice(address rewardToken, uint256 amount) public view returns (uint256) {
		address assetAddress;

		try IAToken(rewardToken).UNDERLYING_ASSET_ADDRESS() returns (address underlyingAddress) {
			assetAddress = underlyingAddress;
		} catch {
			assetAddress = rewardToken;
		}

		uint256 assetPrice = IAaveOracle(aaveOracle).getAssetPrice(assetAddress);
		address sourceOfAsset = IAaveOracle(aaveOracle).getSourceOfAsset(assetAddress);

		uint8 priceDecimals;
		try IChainlinkAggregator(sourceOfAsset).decimals() returns (uint8 decimals) {
			priceDecimals = decimals;
		} catch {
			priceDecimals = 8;
		}

		// note using original asset arg here, so it uses the rToken
		uint8 assetDecimals = IERC20Metadata(rewardToken).decimals();
		return (assetPrice * amount * (10 ** DECIMALS)) / (10 ** priceDecimals) / (10 ** assetDecimals);
	}

	/**
	 * @notice Sets new oracle.
	 */
	function setOracle(address _newOracle) external onlyOwner {
		if (_newOracle == address(0)) revert AddressZero();
		oracle = IBaseOracle(_newOracle);
		emit OracleUpdated(_newOracle);
	}

	/**
	 * @notice Sets pool helper contract.
	 */
	function setPoolHelper(address _poolHelper) external onlyOwner {
		poolHelper = IPoolHelper(_poolHelper);
		if (getLpTokenPrice() == 0) revert InvalidOracle();
		emit PoolHelperUpdated(_poolHelper);
	}

	/**
	 * @notice Sets base token price aggregator.
	 */
	function setAggregator(address _baseAssetChainlinkAdapter) external onlyOwner {
		baseAssetChainlinkAdapter = IChainlinkAdapter(_baseAssetChainlinkAdapter);
		if (getLpTokenPriceUsd() == 0) revert InvalidOracle();
		emit AggregatorUpdated(_baseAssetChainlinkAdapter);
	}

	/**
	 * @notice Sets option to use pool.
	 */
	function setUsePool(bool _usePool) external onlyOwner {
		usePool = _usePool;
		emit UsePoolUpdated(_usePool);
	}

	/**
	 * @notice Returns decimals of price.
	 */
	function decimals() public pure returns (uint256) {
		return 8;
	}
}
