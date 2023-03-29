// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "./BaseOracle.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";
import "@uniswap/v3-core/contracts/UniswapV3Factory.sol";

import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

contract UniV3TwapOracle is Initializable, BaseOracle {
	using SafeMath for uint256;

	/// @notice Uniswap V3 pool address
	IUniswapV3Pool public pool;

	/// @notice First token of the pair
	IERC20Metadata public token0;

	/// @notice Second token of the pair
	IERC20Metadata public token1;

	/// @notice Decimal of token0
	uint8 public decimals0;

	/// @notice Decimal of token1
	uint8 public decimals1;

	/// @notice TWAP loopback period
	uint32 public lookbackSecs;

	/// @notice Can flip the order of the pricing
	bool public priceInToken0;

	/**
	 * @notice Initializer
	 * @param _pair Uniswap pair contract
	 * @param _rdnt RDNT token address.
	 * @param _ethChainlinkFeed Chainlink price feed for ETH.
	 */
	function initialize(
		address _pair,
		address _rdnt,
		address _ethChainlinkFeed,
		uint32 _lookbackSecs
	) external initializer {
		require(_pair != address(0), "pair is 0 address");
		require(_rdnt != address(0), "rdnt is 0 address");
		require(_ethChainlinkFeed != address(0), "ethChainlinkFeed is 0 address");
		pool = IUniswapV3Pool(_pair);
		token0 = IERC20Metadata(pool.token0());
		token1 = IERC20Metadata(pool.token1());

		decimals0 = token0.decimals();
		decimals1 = token1.decimals();

		lookbackSecs = _lookbackSecs;

		priceInToken0 = false;
		__BaseOracle_init(_rdnt, _ethChainlinkFeed);
	}

	/* ========== RESTRICTED FUNCTIONS ========== */

	/**
	 * @dev Convenience function
	 */
	function increaseObservationCardinality(uint16 numCardinals) external onlyOwner {
		pool.increaseObservationCardinalityNext(numCardinals);
	}

	/**
	 * @notice Sets new TWAP loopback period
	 * @param _secs Loopback period in seconds
	 */
	function setTWAPLookbackSec(uint32 _secs) external onlyOwner {
		lookbackSecs = _secs;
	}

	/**
	 * @notice Toggles price quote option.
	 */
	function toggleTokenForPricing() external onlyOwner {
		priceInToken0 = !priceInToken0;
	}

	/* ========== VIEWS ========== */

	/**
	 * @notice Returns token symbols for base and pricing.
	 * @return base token symbol
	 * @return pricing token symbol
	 */
	function tokenSymbols() external view returns (string memory base, string memory pricing) {
		if (priceInToken0) {
			base = token1.symbol();
			pricing = token0.symbol();
		} else {
			base = token0.symbol();
			pricing = token1.symbol();
		}
	}

	/**
	 * @notice Returns price
	 * @return amountOut Price in base token.
	 */
	function getPrecisePrice() public view returns (uint256 amountOut) {
		// Get the average price tick first
		(int24 arithmeticMeanTick, ) = OracleLibrary.consult(address(pool), lookbackSecs);

		// Get the quote for selling 1 unit of a token. Assumes 1e18 for both.
		if (priceInToken0) {
			if (decimals0 <= 18) {
				amountOut = OracleLibrary
					.getQuoteAtTick(arithmeticMeanTick, uint128(10 ** decimals1), address(token1), address(token0))
					.mul(10 ** (18 - decimals0));
			} else {
				amountOut = OracleLibrary
					.getQuoteAtTick(arithmeticMeanTick, uint128(10 ** decimals1), address(token1), address(token0))
					.div(10 ** (decimals0 - 18));
			}
		} else {
			if (decimals1 <= 18) {
				amountOut = OracleLibrary
					.getQuoteAtTick(arithmeticMeanTick, uint128(10 ** decimals0), address(token0), address(token1))
					.mul(10 ** (18 - decimals1));
			} else {
				amountOut = OracleLibrary
					.getQuoteAtTick(arithmeticMeanTick, uint128(10 ** decimals0), address(token0), address(token1))
					.div(10 ** (decimals1 - 18));
			}
		}
	}

	/**
	 * @notice Returns current price.
	 */
	function consult() public view override returns (uint256) {
		return getPrecisePrice();
	}

	/**
	 * @dev AggregatorV3Interface / Chainlink compatibility.
	 */
	function latestRoundData()
		external
		view
		returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
	{
		return (0, int256(getPrecisePrice()), 0, block.timestamp, 0);
	}
}
