// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.5.0;

interface IWETH {
	function deposit() external payable;

	function transfer(address to, uint value) external returns (bool);

	function withdraw(uint) external;

	function balanceOf(address) external returns (uint);
}
