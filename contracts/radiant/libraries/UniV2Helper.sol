// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUniswapV2Router02} from "../../interfaces/uniswap/IUniswapV2Router02.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

library UniV2Helper {
	using SafeERC20 for IERC20;

	/**
	 * @notice Swap the privded amount of _inTokens for _outTokens
	 * @param _router the AMM router that will be used to perform the price query
	 * @param _inToken the address of the token that will be sold
	 * @param _outToken the address of the token that will be bought
	 * @param _inAmount amount of _inTokens to be sold
	 * @return amount of _outTokens received
	 */
	function _swap(address _router, address _inToken, address _outToken, uint256 _inAmount) internal returns (uint256) {
		address[] memory path = new address[](2);
		path[0] = _inToken;
		path[1] = _outToken;
		IERC20(_inToken).forceApprove(_router, _inAmount);
		return
			IUniswapV2Router02(_router).swapExactTokensForTokens(_inAmount, 0, path, address(this), block.timestamp)[1];
	}

	/**
	 * @notice Query the amount of _outTokens received for a given amount of _inTokens
	 * @param _router the AMM router that will be used to perform the price query
	 * @param _inToken the address of the token that will be sold
	 * @param _outToken the address of the token that will be bought
	 * @param _inAmount amount of _inTokens to be sold
	 * @return amount of _outTokens received
	 */
	function _quoteSwap(
		address _router,
		address _inToken,
		address _outToken,
		uint256 _inAmount
	) internal view returns (uint256) {
		address[] memory path = new address[](2);
		path[0] = _inToken;
		path[1] = _outToken;
		return IUniswapV2Router02(_router).getAmountsOut(_inAmount, path)[1];
	}
}
