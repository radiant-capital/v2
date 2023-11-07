// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH} from "../../../interfaces/IWETH.sol";

/// @title Dust Refunder Contract
/// @dev Refunds dust tokens remaining from zapping.
/// @author Radiant
contract DustRefunder {
	using SafeERC20 for IERC20;

	/**
	 * @notice Refunds RDNT and WETH.
	 * @param _rdnt RDNT address
	 * @param _weth WETH address
	 * @param _refundAddress Address for refund
	 */
	function _refundDust(address _rdnt, address _weth, address _refundAddress) internal {
		IERC20 rdnt = IERC20(_rdnt);
		IWETH weth = IWETH(_weth);

		uint256 dustWETH = weth.balanceOf(address(this));
		if (dustWETH > 0) {
			weth.transfer(_refundAddress, dustWETH);
		}
		uint256 dustRdnt = rdnt.balanceOf(address(this));
		if (dustRdnt > 0) {
			rdnt.safeTransfer(_refundAddress, dustRdnt);
		}
	}
}
