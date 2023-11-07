// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

/// @title Library for pagination of address array
/// @author Radiant Devs
library AddressPagination {
	/**
	 * @notice Paginate address array.
	 * @param array storage slot of the array to paginate.
	 * @param page number
	 * @param limit per page
	 * @return result address array.
	 */
	function paginate(
		address[] storage array,
		uint256 page,
		uint256 limit
	) internal view returns (address[] memory result) {
		result = new address[](limit);
		uint256 length = array.length;
		for (uint256 i = 0; i < limit; ) {
			if (page * limit + i >= length) {
				result[i] = address(0);
			} else {
				result[i] = array[page * limit + i];
			}
			unchecked {
				i++;
			}
		}
	}
}
