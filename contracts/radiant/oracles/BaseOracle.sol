// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";
import "../../interfaces/IChainlinkAggregator.sol";
import "../../interfaces/IBaseOracle.sol";

/// @title BaseOracle Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract BaseOracle is Initializable, OwnableUpgradeable {
	using SafeMath for uint256;

	/// @notice Token for price
	address public token;

	/// @notice Chainlink price feed for ETH
	address public ethChainlinkFeed;

	/// @notice Enable/Disable fallback
	bool public fallbackEnabled;

	/// @notice Oracle to be used as a fallback
	IBaseOracle public fallbackOracle;

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
	function setFallback(address _fallback) public onlyOwner {
		require(_fallback != address(0), "invalid address");
		fallbackOracle = IBaseOracle(_fallback);
	}

	/**
	 * @notice Enable/Disable use of fallback oracle
	 * @param _enabled Boolean value.
	 */
	function enableFallback(bool _enabled) public onlyOwner {
		require(address(fallbackOracle) != (address(0)), "no fallback set");
		fallbackEnabled = _enabled;
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

		price = priceInEth.mul(ethPrice).div(10 ** 8);
	}

	/**
	 * @notice Returns USD price in ETH
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8.
	 */
	function latestAnswerInEth() public view returns (uint256 price) {
		if (!fallbackEnabled) {
			price = consult();
		} else {
			price = fallbackOracle.consult();
		}
		price = price.div(10 ** 10);
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
	function consult() public view virtual returns (uint amountOut) {}
}
