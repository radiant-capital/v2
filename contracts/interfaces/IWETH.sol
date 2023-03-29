// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.8.12;

interface IWETH {
	function balanceOf(address) external returns (uint);

	function deposit() external payable;

	function withdraw(uint256) external;

	function approve(address guy, uint256 wad) external returns (bool);

	function transferFrom(address src, address dst, uint256 wad) external returns (bool);

	function transfer(address to, uint value) external returns (bool);

	function allowance(address owner, address spender) external returns (uint256);
}
