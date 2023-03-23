// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./AddressPagination.sol";

/// @title Locker List Contract
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract LockerList is Ownable {
	using AddressPagination for address[];

	// Users list
	address[] internal userlist;
	mapping(address => uint256) internal indexOf;
	mapping(address => bool) internal inserted;

	/********************** Events ***********************/

	event LockerAdded(address indexed locker);
	event LockerRemoved(address indexed locker);

	/**
	 * @dev Constructor
	 */
	constructor() Ownable() {}

	/********************** Lockers list ***********************/
	/**
	 * @notice Return the number of users.
	 */
	function lockersCount() external view returns (uint256) {
		return userlist.length;
	}

	/**
	 * @notice Return the list of users.
	 */
	function getUsers(uint256 page, uint256 limit) external view returns (address[] memory) {
		return userlist.paginate(page, limit);
	}

	function addToList(address user) external onlyOwner {
		if (inserted[user] == false) {
			inserted[user] = true;
			indexOf[user] = userlist.length;
			userlist.push(user);
		}

		emit LockerAdded(user);
	}

	function removeFromList(address user) external onlyOwner {
		assert(inserted[user] == true);

		delete inserted[user];

		uint256 index = indexOf[user];
		uint256 lastIndex = userlist.length - 1;
		address lastUser = userlist[lastIndex];

		indexOf[lastUser] = index;
		delete indexOf[user];

		userlist[index] = lastUser;
		userlist.pop();

		emit LockerRemoved(user);
	}
}
