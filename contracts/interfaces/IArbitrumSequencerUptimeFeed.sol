// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.12;

interface IArbitrumSequencerUptimeFeed {
	function aliasedL1MessageSender() external view returns (address);

	function updateStatus(bool status, uint64 timestamp) external;
}
