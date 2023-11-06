// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AddressPagination} from "../libraries/AddressPagination.sol";

/// @title Locker List Contract
/// @author Radiant
contract LockerList is Ownable {
	using AddressPagination for address[];

	// Users list
	address[] internal userList;
	mapping(address => uint256) internal indexOf;
	mapping(address => bool) internal inserted;

	/********************** Events ***********************/

	event LockerAdded(address indexed locker);
	event LockerRemoved(address indexed locker);

	/********************** Errors ***********************/

	error Ineligible();

	/********************** Lockers list ***********************/

	/**
	 * @notice Return the number of users.
	 * @return count The number of users
	 */
	function lockersCount() external view returns (uint256 count) {
		count = userList.length;
	}

	/**
	 * @notice Return the list of users.
	 * @dev This is a very gas intensive function to execute and thus should only by utilized by off-chain entities.
	 * @param page The page number to retrieve
	 * @param limit The number of entries per page
	 * @return users A paginated list of users
	 */
	function getUsers(uint256 page, uint256 limit) external view returns (address[] memory users) {
		users = userList.paginate(page, limit);
	}

	/**
	 * @notice Add a locker.
	 * @dev This can be called only by the owner. Owner should be MFD contract.
	 * @param user address to be added
	 */
	function addToList(address user) external onlyOwner {
		if (inserted[user] == false) {
			inserted[user] = true;
			indexOf[user] = userList.length;
			userList.push(user);
		}

		emit LockerAdded(user);
	}

	/**
	 * @notice Remove a locker.
	 * @dev This can be called only by the owner. Owner should be MFD contract.
	 * @param user address to remove
	 */
	function removeFromList(address user) external onlyOwner {
		if (inserted[user] == false) revert Ineligible();

		delete inserted[user];

		uint256 index = indexOf[user];
		uint256 lastIndex = userList.length - 1;
		address lastUser = userList[lastIndex];

		indexOf[lastUser] = index;
		delete indexOf[user];

		userList[index] = lastUser;
		userList.pop();

		emit LockerRemoved(user);
	}
}
