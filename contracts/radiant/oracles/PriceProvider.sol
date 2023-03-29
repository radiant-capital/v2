// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.12;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../interfaces/IBaseOracle.sol";
import "../../interfaces/IPoolHelper.sol";
import "../../interfaces/IChainlinkAggregator.sol";
import "../../interfaces/IEligibilityDataProvider.sol";
import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

/// @title PriceProvider Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract PriceProvider is Initializable, OwnableUpgradeable {
	using SafeMath for uint256;

	/// @notice Chainlink aggregator for USD price of base token
	IChainlinkAggregator public baseTokenPriceInUsdProxyAggregator;

	/// @notice Pool helper contract - Uniswap/Balancer
	IPoolHelper public poolHelper;

	/// @notice Eligibility data provider contract
	IEligibilityDataProvider public eligibilityProvider;

	/// @notice Base oracle contract
	IBaseOracle public oracle;

	bool private usePool;

	/**
	 * @notice Initializer
	 * @param _baseTokenPriceInUsdProxyAggregator Chainlink aggregator for USD price of base token
	 * @param _poolHelper Pool helper contract - Uniswap/Balancer
	 */
	function initialize(
		IChainlinkAggregator _baseTokenPriceInUsdProxyAggregator,
		IPoolHelper _poolHelper
	) public initializer {
		require(address(_baseTokenPriceInUsdProxyAggregator) != (address(0)), "Not a valid address");
		require(address(_poolHelper) != (address(0)), "Not a valid address");
		__Ownable_init();

		poolHelper = _poolHelper;
		baseTokenPriceInUsdProxyAggregator = _baseTokenPriceInUsdProxyAggregator;
		usePool = true;
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
		if (usePool) {
			// use sparingly, TWAP/CL otherwise
			uint256 ethPrice = uint256(IChainlinkAggregator(baseTokenPriceInUsdProxyAggregator).latestAnswer());
			uint256 priceInEth = poolHelper.getPrice();
			price = priceInEth.mul(ethPrice).div(10 ** 8);
		} else {
			price = oracle.latestAnswer();
		}
	}

	/**
	 * @notice Returns lp token price in ETH.
	 */
	function getLpTokenPrice() public view returns (uint) {
		// decis 8
		uint rdntPriceInEth = getTokenPrice();
		return poolHelper.getLpPrice(rdntPriceInEth);
	}

	/**
	 * @notice Returns lp token price in USD.
	 */
	function getLpTokenPriceUsd() public view returns (uint256 price) {
		// decimals 8
		uint256 lpPriceInEth = getLpTokenPrice();
		// decimals 8
		uint256 ethPrice = uint256(baseTokenPriceInUsdProxyAggregator.latestAnswer());
		price = lpPriceInEth.mul(ethPrice).div(10 ** 8);
	}

	/**
	 * @notice Returns lp token address.
	 */
	function getLpTokenAddress() public view returns (address) {
		return poolHelper.lpTokenAddr();
	}

	function setOracle(address _newOracle) external onlyOwner {
		require(_newOracle != address(0));
		oracle = IBaseOracle(_newOracle);
	}

	function setPoolHelper(address _poolHelper) external onlyOwner {
		poolHelper = IPoolHelper(_poolHelper);
		require(getLpTokenPrice() != 0, "invalid oracle");
	}

	function setAggregator(address _baseTokenPriceInUsdProxyAggregator) external onlyOwner {
		baseTokenPriceInUsdProxyAggregator = IChainlinkAggregator(_baseTokenPriceInUsdProxyAggregator);
		require(getLpTokenPriceUsd() != 0, "invalid oracle");
	}

	function setUsePool(bool _usePool) external onlyOwner {
		usePool = _usePool;
	}

	/**
	 * @notice Returns decimals of price.
	 */
	function decimals() public pure returns (uint256) {
		return 8;
	}
}
