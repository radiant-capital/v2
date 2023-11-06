// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BaseOracle} from "../BaseOracle.sol";
import {FixedPoint} from "../../../dependencies/uniswap/contracts/FixedPoint.sol";
import {UniswapV2OracleLibrary, IUniswapV2Pair} from "../../../dependencies/uniswap/contracts/UniswapV2OracleLibrary.sol";

/// @title UniV2TwapOracle Contract
/// @author Radiant team
/// @dev Fixed window oracle that recomputes the average price for the entire period once every period
/// Note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract UniV2TwapOracle is BaseOracle {
	using FixedPoint for *;

	/// @notice TWAP period
	uint256 public period;

	/// @notice Used for being able to consult past the period end
	uint256 public consultLeniency;

	/// @notice If false, consult() will fail if the TWAP is stale
	bool public allowStaleConsults;

	/// @notice Uniswap pair contract
	IUniswapV2Pair public pair;

	/// @notice First token of the pair
	address public token0;

	/// @notice Second token of the pair
	address public token1;

	/// @notice First token of the pair
	uint256 public price0CumulativeLast;

	/// @notice First token of the pair
	uint256 public price1CumulativeLast;

	/// @notice Last updated timestamp
	uint32 public blockTimestampLast;

	/// @notice Average price of token0
	FixedPoint.uq112x112 public price0Average;

	/// @notice Average price of token1
	FixedPoint.uq112x112 public price1Average;

	/// @notice Minimum TWAP time period
	uint256 public constant PERIOD_MIN = 10;

	error InvalidToken();

	error NoReserves();

	error PeriodBelowMin();

	error PeriodNotElapsed();

	error PriceIsStale();

	/********************** Events ***********************/

	event PeriodUpdated(uint256 indexed _period);

	event ConsultLeniencyUpdated(uint256 indexed _consultLeniency);

	event AllowStaleConsultsUpdated(bool indexed _allowStaleConsults);

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _pair Uniswap pair contract
	 * @param _rdnt RDNT token address.
	 * @param _ethChainlinkFeed Chainlink price feed for ETH.
	 * @param _period TWAP period.
	 * @param _consultLeniency Used for being able to consult past the period end.
	 * @param _allowStaleConsults Enable/Disable stale.
	 */
	function initialize(
		address _pair,
		address _rdnt,
		address _ethChainlinkFeed,
		uint256 _period,
		uint256 _consultLeniency,
		bool _allowStaleConsults
	) external initializer {
		if (_pair == address(0)) revert AddressZero();
		if (_rdnt == address(0)) revert AddressZero();
		if (_ethChainlinkFeed == address(0)) revert AddressZero();

		pair = IUniswapV2Pair(_pair);
		token0 = pair.token0();
		token1 = pair.token1();

		price0CumulativeLast = pair.price0CumulativeLast(); // Fetch the current accumulated price value (1 / 0)
		price1CumulativeLast = pair.price1CumulativeLast(); // Fetch the current accumulated price value (0 / 1)
		uint112 reserve0;
		uint112 reserve1;
		(reserve0, reserve1, blockTimestampLast) = pair.getReserves();

		if (reserve0 == 0 || reserve1 == 0) revert NoReserves(); // Ensure that there's liquidity in the pair
		if (_period < PERIOD_MIN) revert PeriodBelowMin(); // Ensure period has a min time

		period = _period;
		consultLeniency = _consultLeniency;
		allowStaleConsults = _allowStaleConsults;

		__BaseOracle_init(_rdnt, _ethChainlinkFeed);
	}

	/**
	 * @notice Sets new period.
	 * @param _period TWAP period.
	 */
	function setPeriod(uint256 _period) external onlyOwner {
		if (_period < PERIOD_MIN) revert PeriodBelowMin(); // Ensure period has a min time
		period = _period;
		emit PeriodUpdated(_period);
	}

	/**
	 * @notice Sets new consult leniency.
	 * @param _consultLeniency new value.
	 */
	function setConsultLeniency(uint256 _consultLeniency) external onlyOwner {
		consultLeniency = _consultLeniency;
		emit ConsultLeniencyUpdated(_consultLeniency);
	}

	/**
	 * @notice Sets stale consult option.
	 * @param _allowStaleConsults new value.
	 */
	function setAllowStaleConsults(bool _allowStaleConsults) external onlyOwner {
		allowStaleConsults = _allowStaleConsults;
		emit AllowStaleConsultsUpdated(_allowStaleConsults);
	}

	/**
	 * @dev Check if update() can be called instead of wasting gas calling it.
	 */
	function canUpdate() public view override returns (bool) {
		uint32 blockTimestamp = UniswapV2OracleLibrary.currentBlockTimestamp();
		uint32 timeElapsed;
		unchecked {
			timeElapsed = blockTimestamp - blockTimestampLast; // Overflow is desired
		}
		return (timeElapsed >= period);
	}

	/**
	 * @notice Updates price
	 */
	function update() external {
		(uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = UniswapV2OracleLibrary
			.currentCumulativePrices(address(pair));
		uint32 timeElapsed;
		unchecked {
			timeElapsed = blockTimestamp - blockTimestampLast; // Overflow is desired
		}

		// Ensure that at least one full period has passed since the last update
		if (timeElapsed < period) revert PeriodNotElapsed();

		// Overflow is desired, casting never truncates
		// Cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
		unchecked {
			price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
			price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));
			price0CumulativeLast = price0Cumulative;
			price1CumulativeLast = price1Cumulative;
			blockTimestampLast = blockTimestamp;
		}
	}

	/**
	 * @dev This will always return 0 before update has been called successfully for the first time.
	 */
	function _consult(address _token, uint256 _amountIn) internal view returns (uint256 amountOut) {
		uint32 blockTimestamp = UniswapV2OracleLibrary.currentBlockTimestamp();
		uint32 timeElapsed;
		unchecked {
			timeElapsed = blockTimestamp - blockTimestampLast; // Overflow is desired
		}

		// Ensure that the price is not stale
		if ((timeElapsed >= (period + consultLeniency)) && !allowStaleConsults) revert PriceIsStale();

		if (_token == token0) {
			amountOut = price0Average.mul(_amountIn).decode144();
		} else {
			if (_token != token1) revert InvalidToken();
			amountOut = price1Average.mul(_amountIn).decode144();
		}
	}

	/**
	 * @notice Returns current price.
	 */
	function consult() public view override returns (uint256) {
		uint8 decimals = IERC20Metadata(token).decimals();
		return _consult(token, 10 ** decimals);
	}
}
