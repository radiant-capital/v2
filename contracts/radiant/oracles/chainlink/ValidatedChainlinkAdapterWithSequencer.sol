// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {AggregatorV3Interface} from "../../../interfaces/AggregatorV3Interface.sol";
import {BaseChainlinkAdapter} from "./BaseChainlinkAdapter.sol";

/// @title ChainlinkAdapter Contract
/// @author Radiant
contract ValidatedChainlinkAdapterWithSequencer is BaseChainlinkAdapter {
	AggregatorV3Interface public constant ARBITRUM_SEQUENCER_UPTIME_FEED =
		AggregatorV3Interface(0xFdB631F5EE196F0ed6FAa767959853A9F217697D);
	uint256 public constant GRACE_PERIOD_TIME = 3600;
	uint256 public constant UPDATE_PERIOD = 86400;

	error SequencerDown();
	error GracePeriodNotOver();

	constructor(address _chainlinkFeed, uint256 _heartbeat) BaseChainlinkAdapter(_chainlinkFeed, _heartbeat) {}

	/**
	 * @notice Check the sequencer status for the Arbitrum mainnet.
	 */
	function checkSequencerFeed() public view {
		(, int256 answer, uint256 startedAt, , ) = ARBITRUM_SEQUENCER_UPTIME_FEED.latestRoundData();
		// Answer == 0: Sequencer is up
		// Answer == 1: Sequencer is down
		bool isSequencerUp = answer == 0;
		if (!isSequencerUp) {
			revert SequencerDown();
		}

		// Make sure the grace period has passed after the sequencer is back up.
		uint256 timeSinceUp = block.timestamp - startedAt;
		if (timeSinceUp <= GRACE_PERIOD_TIME) {
			revert GracePeriodNotOver();
		}
	}

	/**
	 * @notice Returns USD price in quote token.
	 * @dev supports 18 decimal token
	 * @return price of token in decimal 8
	 */
	function latestAnswer() external view override returns (uint256 price) {
		checkSequencerFeed();
		(, int256 answer, , uint256 updatedAt, ) = chainlinkFeed.latestRoundData();
		validate(answer, updatedAt);
		return uint256(answer);
	}
}
