// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title Migration contract from V1 to V2
/// @author Radiant team
/// @dev All function calls are currently implemented without side effects
contract Migration is Ownable, Pausable {
	using SafeMath for uint256;
	using SafeERC20 for ERC20;

	/// @notice V1 of RDNT
	ERC20 public tokenV1;

	/// @notice V2 of RDNT
	ERC20 public tokenV2;

	/// @notice emitted when migrate v1 token into v2
	event Migrate(address indexed user, uint256 amount);

	/**
	 * @notice constructor
	 * @param _tokenV1 RDNT V1 token address
	 * @param _tokenV2 RDNT V2 token address
	 */
	constructor(ERC20 _tokenV1, ERC20 _tokenV2) Ownable() {
		tokenV1 = _tokenV1;
		tokenV2 = _tokenV2;
		_pause();
	}

	function pause() public onlyOwner {
		_pause();
	}

	function unpause() public onlyOwner {
		_unpause();
	}

	/**
	 * @notice Withdraw ERC20 token
	 * @param _token address for withdraw
	 * @param _amount to withdraw
	 */
	function withdrawToken(ERC20 _token, uint256 _amount) external onlyOwner {
		_token.safeTransfer(owner(), _amount);
	}

	/**
	 * @notice Migrate from V1 to V2
	 * @param _amount of V1 token
	 */
	function exchange(uint256 _amount) external whenNotPaused {
		tokenV1.safeTransferFrom(_msgSender(), address(this), _amount);
		tokenV2.safeTransfer(_msgSender(), _amount);

		emit Migrate(_msgSender(), _amount);
	}
}
