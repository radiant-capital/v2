// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

library AddressPagination {
	function paginate(
		address[] memory array,
		uint256 page,
		uint256 limit
	) internal pure returns (address[] memory result) {
		result = new address[](limit);
		for (uint256 i = 0; i < limit; i++) {
			if (page * limit + i >= array.length) {
				result[i] = address(0);
			} else {
				result[i] = array[page * limit + i];
			}
		}
	}
}
