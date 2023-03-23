// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./BaseOracle.sol";
import "../../dependencies/openzeppelin/upgradeability/PausableUpgradeable.sol";

import "../../interfaces/IBaseOracle.sol";
import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";

/// @title ComboOracle Contract
/// @author Radiant
/// @dev Returns average of multiple oracle sources, if TWAP, use same period
contract ComboOracle is Initializable, PausableUpgradeable, BaseOracle {
	using SafeMath for uint256;

	/// @notice Array of different oracles
	IBaseOracle[] public sources;

	/// @notice The current price
	uint256 public price;

	/// @notice Last updated timestamp
	uint32 public blockTimestampLast;

	/**
	 * @dev Emitted a price discrepancy is detected from the oracle sources.
	 * @param averagePrice The average price of the sources.
	 * @param lowestPrice The lowest price of the sources.
	 */
	event PriceDiscrepancy(uint256 averagePrice, uint256 lowestPrice);

	/**
	 * @notice Initializer
	 * @param _rdnt RDNT token address.
	 * @param _ethChainlinkFeed chainlink price feed for ETH.
	 */
	function initialize(address _rdnt, address _ethChainlinkFeed) external initializer {
		__Pausable_init();
		__BaseOracle_init(_rdnt, _ethChainlinkFeed);
	}

	/**
	 * @notice Adds new oracle
	 * @param _source New price source.
	 */
	function addSource(address _source) public onlyOwner {
		require(_source != address(0), "invalid address");
		sources.push(IBaseOracle(_source));
	}

	/**
	 * @notice Removes the oracle at a given index
	 * @param _index New index of the oracle.
	 */
	function removeSource(uint256 _index) public onlyOwner {
		require(_index < sources.length, "index out of bounds");
		sources[_index] = sources[sources.length - 1];
		sources.pop();
	}

	/**
	 * @notice Calculated price
	 * @return price Average price of several sources.
	 */
	function consult() public view override returns (uint256 price) {
		require(sources.length != 0, "0 sources");

		// uint256 sum;
		// uint256 lowestPrice;
		// for (uint256 i = 0; i < sources.length; i++) {
		// 	uint256 sourcePrice = sources[i].consult();
		// 	require(sourcePrice != 0, "source consult failure");
		// 	if (lowestPrice == 0) {
		// 		lowestPrice = sourcePrice;
		// 	} else {
		// 		lowestPrice = lowestPrice > sourcePrice ? sourcePrice : lowestPrice;
		// 	}
		// 	sum = sum.add(sourcePrice);
		// }
		// uint256 averagedPrice = sum.div(sources.length);
		// if (averagedPrice > ((lowestPrice * 1025) / 1000)) {
		// 	emit PriceDiscrepancy(averagedPrice, lowestPrice);
		// } else {
		// 	price = averagedPrice;
		// 	blockTimestampLast = uint32(block.timestamp % 2 ** 32);
		// }
	}

	function pause() external onlyOwner {
		_pause();
	}

	function unpause() external onlyOwner {
		_unpause();
	}
}
