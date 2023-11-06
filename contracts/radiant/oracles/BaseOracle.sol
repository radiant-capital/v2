// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IBaseOracle} from "../../interfaces/IBaseOracle.sol";

/// @title BaseOracle Contract
/// @author Radiant
abstract contract BaseOracle is Initializable, OwnableUpgradeable {
	/// @notice Token for price
	address public token;

	/// @notice Chainlink price feed for ETH
	address public ethChainlinkFeed;

	/// @notice Enable/Disable fallback
	bool public fallbackEnabled;

	/// @notice Oracle to be used as a fallback
	IBaseOracle public fallbackOracle;

	error AddressZero();

	error FallbackNotSet();

	/********************** Events ***********************/
	event FallbackOracleUpdated(address indexed _fallback);

	event FallbackOracleEnabled(bool indexed _enabled);

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _token Token address.
	 * @param _ethChainlinkFeed chainlink price feed for ETH.
	 */
	function __BaseOracle_init(address _token, address _ethChainlinkFeed) internal onlyInitializing {
		__Ownable_init();
		token = _token;
		ethChainlinkFeed = _ethChainlinkFeed;
	}

	/**
	 * @notice Sets fallback oracle
	 * @param _fallback Oracle address for fallback.
	 */
	function setFallback(address _fallback) external onlyOwner {
		if (_fallback == address(0)) revert AddressZero();
		fallbackOracle = IBaseOracle(_fallback);
		emit FallbackOracleUpdated(_fallback);
	}

	/**
	 * @notice Enable/Disable use of fallback oracle
	 * @param _enabled Boolean value.
	 */
	function enableFallback(bool _enabled) external onlyOwner {
		if (address(fallbackOracle) == (address(0))) revert FallbackNotSet();
		fallbackEnabled = _enabled;
		emit FallbackOracleEnabled(_enabled);
	}

	/**
	 * @notice Returns USD price in quote token.
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8
	 */
	function latestAnswer() public view returns (uint256 price) {
		// returns decimals 8
		uint256 priceInEth = latestAnswerInEth();

		// returns decimals 8
		uint256 ethPrice = uint256(IChainlinkAggregator(ethChainlinkFeed).latestAnswer());

		price = (priceInEth * ethPrice) / (10 ** 8);
	}

	/**
	 * @notice Returns price in ETH
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8.
	 */
	function latestAnswerInEth() public view returns (uint256 price) {
		if (!fallbackEnabled) {
			price = consult();
		} else {
			price = fallbackOracle.consult();
		}
		price = price / (10 ** 10);
	}

	/**
	 * @dev returns possibility for update
	 */
	function canUpdate() public view virtual returns (bool) {
		return false;
	}

	/**
	 * @dev implement in child contract
	 */
	function consult() public view virtual returns (uint256) {}

	// Allowing for storage vars to be added/shifted above without effecting any inheriting contracts/proxies
	uint256[50] private __gap;
}
