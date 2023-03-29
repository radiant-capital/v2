// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "./BaseOracle.sol";

import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";

/// @title ManualOracle Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract ManualOracle is Initializable, BaseOracle {
	/// @notice Price stored manually
	uint256 public price;

	/**
	 * @notice Initializer
	 * @param _rdnt RDNT token address.
	 * @param _ethChainlinkFeed chainlink price feed for ETH.
	 */
	function initialize(address _rdnt, address _ethChainlinkFeed) external initializer {
		require(_rdnt != address(0), "rdnt is 0 address");
		require(_ethChainlinkFeed != address(0), "ethChainlinkFeed is 0 address");
		__BaseOracle_init(_rdnt, _ethChainlinkFeed);
	}

	/**
	 * @notice Sets new price.
	 * @param _price Price amount to be set.
	 */
	function setPrice(uint256 _price) public onlyOwner {
		require(_price != 0, "price cannot be 0");
		price = _price;
	}

	/**
	 * @notice Returns current price
	 */
	function consult() public view override returns (uint) {
		return price;
	}
}
