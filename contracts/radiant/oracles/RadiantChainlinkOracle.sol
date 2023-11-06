// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {OwnableUpgradeable} from "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";
import {IChainlinkAdapter} from "../../interfaces/IChainlinkAdapter.sol";
import {IBaseOracle} from "../../interfaces/IBaseOracle.sol";

/// @title RadiantChainlinkOracle Contract
/// @author Radiant
contract RadiantChainlinkOracle is IBaseOracle, OwnableUpgradeable {
	/// @notice Eth price feed
	IChainlinkAdapter public ethChainlinkAdapter;
	/// @notice Token price feed
	IChainlinkAdapter public rdntChainlinkAdapter;

	error AddressZero();

	/**
	 * @notice Initializer
	 * @param _ethChainlinkAdapter Chainlink adapter for ETH.
	 * @param _rdntChainlinkAdapter Chainlink price feed for RDNT.
	 */
	function initialize(address _ethChainlinkAdapter, address _rdntChainlinkAdapter) external initializer {
		if (_ethChainlinkAdapter == address(0)) revert AddressZero();
		if (_rdntChainlinkAdapter == address(0)) revert AddressZero();
		ethChainlinkAdapter = IChainlinkAdapter(_ethChainlinkAdapter);
		rdntChainlinkAdapter = IChainlinkAdapter(_rdntChainlinkAdapter);
		__Ownable_init();
	}

	/**
	 * @notice Returns USD price in quote token.
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8
	 */
	function latestAnswer() public view returns (uint256 price) {
		// Chainlink param validations happens inside here
		price = rdntChainlinkAdapter.latestAnswer();
	}

	/**
	 * @notice Returns price in ETH
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8.
	 */
	function latestAnswerInEth() public view returns (uint256 price) {
		uint256 rdntPrice = rdntChainlinkAdapter.latestAnswer();
		uint256 ethPrice = ethChainlinkAdapter.latestAnswer();
		price = (rdntPrice * (10 ** 8)) / ethPrice;
	}

	/**
	 * @dev Check if update() can be called instead of wasting gas calling it.
	 */
	function canUpdate() public pure returns (bool) {
		return false;
	}

	/**
	 * @dev this function only exists so that the contract is compatible with the IBaseOracle Interface
	 */
	function update() public {}

	/**
	 * @notice Returns current price.
	 */
	function consult() public view returns (uint256 price) {
		price = latestAnswer();
	}
}
