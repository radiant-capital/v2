// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DataTypes} from "../types/DataTypes.sol";

/**
 * @title Helpers library
 * @author Aave
 */
library Helpers {
	/**
	 * @dev Fetches the user current stable and variable debt balances
	 * @param user The user address
	 * @param reserve The reserve data object
	 * @return The stable and variable debt balance
	 **/
	function getUserCurrentDebt(
		address user,
		DataTypes.ReserveData storage reserve
	) internal view returns (uint256, uint256) {
		return (
			IERC20(reserve.stableDebtTokenAddress).balanceOf(user),
			IERC20(reserve.variableDebtTokenAddress).balanceOf(user)
		);
	}

	function getUserCurrentDebtMemory(
		address user,
		DataTypes.ReserveData memory reserve
	) internal view returns (uint256, uint256) {
		return (
			IERC20(reserve.stableDebtTokenAddress).balanceOf(user),
			IERC20(reserve.variableDebtTokenAddress).balanceOf(user)
		);
	}
}
