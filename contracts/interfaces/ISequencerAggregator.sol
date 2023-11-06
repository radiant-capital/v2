// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "./IChainlinkAggregator.sol";

interface ISequencerAggregator is IChainlinkAggregator {
	function aggregator() external view returns (address);

	function updateStatus(bool status, uint64 timestamp) external;
}
