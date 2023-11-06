// SPDX-License-Identifier: MIT
// Based on the LooksRare airdrop contract

pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @title ARBAirdrop
 * @notice It distributes ARB tokens with a Merkle-tree airdrop.
 */
contract ArbAirdrop is Pausable, ReentrancyGuard, Ownable {
	using SafeERC20 for IERC20;

	IERC20 public immutable arbToken;

	uint256 public immutable MAXIMUM_AMOUNT_TO_CLAIM;

	bool public isMerkleRootSet;

	bytes32 public merkleRoot;

	uint256 public endTimestamp;

	mapping(address => bool) public hasClaimed;

	event AirdropRewardsClaim(address indexed user, uint256 amount);
	event MerkleRootSet(bytes32 merkleRoot);
	event NewEndTimestamp(uint256 endTimestamp);
	event TokensWithdrawn(uint256 amount);

	error AirdropAlreadyClaimed();
	error ClaimAmountTooHigh();
	error ClaimTimeExceeded();
	error InvalidProof();
	error MerkleRootAlreadySet();
	error MerkleRootNotSet();
	error NewTimeStampTooFar();
	error TooEarlyToWithdraw();

	/**
	 * @notice Constructor
	 * @param _endTimestamp end timestamp for claiming
	 * @param _maximumAmountToClaim maximum amount to claim per a user
	 * @param _arbToken address of the ARB airdrop token
	 */
	constructor(uint256 _endTimestamp, uint256 _maximumAmountToClaim, address _arbToken) {
		endTimestamp = _endTimestamp;
		MAXIMUM_AMOUNT_TO_CLAIM = _maximumAmountToClaim;
		arbToken = IERC20(_arbToken);
	}

	/**
	 * @notice Claim tokens for airdrop
	 * @param amount amount to claim for the airdrop
	 * @param merkleProof array containing the merkle proof
	 */
	function claim(uint256 amount, bytes32[] calldata merkleProof) external whenNotPaused nonReentrant {
		if (!isMerkleRootSet) revert MerkleRootNotSet();
		if (amount > MAXIMUM_AMOUNT_TO_CLAIM) revert ClaimAmountTooHigh();
		if (block.timestamp > endTimestamp) revert ClaimTimeExceeded();

		// Verify the user has claimed
		if (hasClaimed[msg.sender]) revert AirdropAlreadyClaimed();

		// Compute the leaf and verify the merkle proof
		bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));

		if (!MerkleProof.verify(merkleProof, merkleRoot, leaf)) revert InvalidProof();

		// Set as claimed
		hasClaimed[msg.sender] = true;

		// Transfer tokens
		arbToken.safeTransfer(msg.sender, amount);

		emit AirdropRewardsClaim(msg.sender, amount);
	}

	/**
	 * @notice Check whether it is possible to claim
	 * @param user address of the user
	 * @param amount amount to claim
	 * @param merkleProof array containing the merkle proof
	 */
	function canClaim(address user, uint256 amount, bytes32[] calldata merkleProof) external view returns (bool) {
		if (block.timestamp <= endTimestamp && !hasClaimed[user]) {
			// Compute the leaf and verify the merkle proof
			bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(user, amount))));
			return MerkleProof.verify(merkleProof, merkleRoot, leaf);
		} else {
			return false;
		}
	}

	/**
	 * @notice Pause airdrop
	 */
	function pauseAirdrop() external onlyOwner whenNotPaused {
		_pause();
	}

	/**
	 * @notice Set merkle root for airdrop
	 * @dev Setting it in the constructor would be more convenient.
	 *      However, this function is effectively used to initiate the airdrop process.
	 * @param _merkleRoot merkle root
	 */
	function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
		if (isMerkleRootSet) revert MerkleRootAlreadySet();

		isMerkleRootSet = true;
		merkleRoot = _merkleRoot;

		emit MerkleRootSet(_merkleRoot);
	}

	/**
	 * @notice Unpause airdrop
	 */
	function unpauseAirdrop() external onlyOwner whenPaused {
		_unpause();
	}

	/**
	 * @notice Update end timestamp
	 * @param newEndTimestamp new endtimestamp
	 * @dev Must be within 30 days
	 */
	function updateEndTimestamp(uint256 newEndTimestamp) external onlyOwner {
		if (block.timestamp + 30 days < newEndTimestamp) revert NewTimeStampTooFar();
		endTimestamp = newEndTimestamp;

		emit NewEndTimestamp(newEndTimestamp);
	}

	/**
	 * @notice Transfer tokens back to owner
	 */
	function withdrawTokenRewards() external onlyOwner {
		if (block.timestamp < (endTimestamp + 1 days)) revert TooEarlyToWithdraw();
		uint256 balanceToWithdraw = arbToken.balanceOf(address(this));
		arbToken.safeTransfer(msg.sender, balanceToWithdraw);

		emit TokensWithdrawn(balanceToWithdraw);
	}
}
