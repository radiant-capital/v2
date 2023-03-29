// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../../interfaces/IStargateRouter.sol";
import "../../interfaces/IRouterETH.sol";
import "../../interfaces/ILendingPool.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

/*
    Chain Ids
        Ethereum: 101
        BSC: 102
        Avalanche: 106
        Polygon: 109
        Arbitrum: 110
        Optimism: 111
        Fantom: 112
        Swimmer: 114
        DFK: 115
        Harmony: 116
        Moonbeam: 126

    Pool Ids
        Ethereum
            USDC: 1
            USDT: 2
            ETH: 13
        BSC
            USDT: 2
            BUSD: 5
        Avalanche
            USDC: 1
            USDT: 2
        Polygon
            USDC: 1
            USDT: 2
        Arbitrum
            USDC: 1
            USDT: 2
            ETH: 13
        Optimism
            USDC: 1
            ETH: 13
        Fantom
            USDC: 1
 */

/// @title Borrow gate via stargate
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract StargateBorrow is OwnableUpgradeable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	/// @notice FEE ratio DIVISOR
	uint256 public constant FEE_PERCENT_DIVISOR = 10000;

	// ETH pool Id
	uint256 private constant POOL_ID_ETH = 13;

	// ETH address
	address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

	/// @notice Stargate Router
	IStargateRouter public router;

	/// @notice Stargate Router ETH
	IRouterETH public routerETH;

	/// @notice Lending Pool address
	ILendingPool public lendingPool;

	// Weth address
	IWETH internal weth;

	/// @notice asset => poolId; at the moment, pool IDs for USDC and USDT are the same accross all chains
	mapping(address => uint256) public poolIdPerChain;

	/// @notice DAO wallet
	address public daoTreasury;

	/// @notice Cross chain borrow fee ratio
	uint256 public xChainBorrowFeePercent;

	/// @notice Emitted when DAO address is updated
	event DAOTreasuryUpdated(address indexed _daoTreasury);

	/// @notice Emitted when fee info is updated
	event XChainBorrowFeePercentUpdated(uint256 percent);

	/// @notice Emited when pool ids of assets are updated
	event PoolIDsUpdated(address[] assets, uint256[] poolIDs);

	/**
	 * @notice Constructor
	 * @param _router Stargate Router address
	 * @param _routerETH Stargate Router for ETH
	 * @param _lendingPool Lending pool
	 * @param _weth WETH address
	 * @param _treasury Treasury address
	 * @param _xChainBorrowFeePercent Cross chain borrow fee ratio
	 */
	function initialize(
		IStargateRouter _router,
		IRouterETH _routerETH,
		ILendingPool _lendingPool,
		IWETH _weth,
		address _treasury,
		uint256 _xChainBorrowFeePercent
	) public initializer {
		require(address(_router) != (address(0)), "Not a valid address");
		require(address(_lendingPool) != (address(0)), "Not a valid address");
		require(address(_weth) != (address(0)), "Not a valid address");
		require(_treasury != address(0), "Not a valid address");
		require(_xChainBorrowFeePercent <= uint256(1e4), "Not a valid number");

		router = _router;
		routerETH = _routerETH;
		lendingPool = _lendingPool;
		daoTreasury = _treasury;
		xChainBorrowFeePercent = _xChainBorrowFeePercent;
		weth = _weth;
		__Ownable_init();
	}

	receive() external payable {}

	/**
	 * @notice Set DAO Treasury.
	 * @param _daoTreasury DAO Treasury address.
	 */
	function setDAOTreasury(address _daoTreasury) external onlyOwner {
		require(_daoTreasury != address(0), "daoTreasury is 0 address");
		daoTreasury = _daoTreasury;
		emit DAOTreasuryUpdated(_daoTreasury);
	}

	/**
	 * @notice Set Cross Chain Borrow Fee Percent.
	 * @param percent Fee ratio.
	 */
	function setXChainBorrowFeePercent(uint256 percent) external onlyOwner {
		require(percent <= 1e4, "Invalid ratio");
		xChainBorrowFeePercent = percent;
		emit XChainBorrowFeePercentUpdated(percent);
	}

	/**
	 * @notice Set pool ids of assets.
	 * @param assets array.
	 * @param poolIDs array.
	 */
	function setPoolIDs(address[] memory assets, uint256[] memory poolIDs) external onlyOwner {
		require(assets.length == poolIDs.length, "length mismatch");
		for (uint256 i = 0; i < assets.length; i += 1) {
			poolIdPerChain[assets[i]] = poolIDs[i];
		}
		emit PoolIDsUpdated(assets, poolIDs);
	}

	/**
	 * @notice Get Cross Chain Borrow Fee amount.
	 * @param amount Fee cost.
	 */
	function getXChainBorrowFeeAmount(uint256 amount) public view returns (uint256) {
		uint256 feeAmount = amount.mul(xChainBorrowFeePercent).div(FEE_PERCENT_DIVISOR);
		return feeAmount;
	}

	/**
	 * @notice Quote LZ swap fee
	 * @dev Call Router.sol method to get the value for swap()
	 */
	function quoteLayerZeroSwapFee(
		uint16 _dstChainId,
		uint8 _functionType,
		bytes calldata _toAddress,
		bytes calldata _transferAndCallPayload,
		IStargateRouter.lzTxObj memory _lzTxParams
	) external view returns (uint256, uint256) {
		return router.quoteLayerZeroFee(_dstChainId, _functionType, _toAddress, _transferAndCallPayload, _lzTxParams);
	}

	/**
	 * @dev Loop the deposit and borrow of an asset
	 * @param asset for loop
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param dstChainId Destination chain id
	 **/
	function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 dstChainId) external payable {
		if (address(asset) == ETH_ADDRESS && address(routerETH) != address(0)) {
			borrowETH(amount, interestRateMode, dstChainId);
		} else {
			lendingPool.borrow(asset, amount, interestRateMode, 0, msg.sender);
			uint256 feeAmount = getXChainBorrowFeeAmount(amount);
			IERC20(asset).safeTransfer(daoTreasury, feeAmount);
			amount = amount.sub(feeAmount);
			IERC20(asset).safeApprove(address(router), 0);
			IERC20(asset).safeApprove(address(router), amount);
			router.swap{value: msg.value}(
				dstChainId, // dest chain id
				poolIdPerChain[asset], // src chain pool id
				poolIdPerChain[asset], // dst chain pool id
				payable(msg.sender), // receive address
				amount, // transfer amount
				amount.mul(99).div(100), // max slippage: 1%
				IStargateRouter.lzTxObj(0, 0, "0x"),
				abi.encodePacked(msg.sender),
				bytes("")
			);
		}
	}

	/**
	 * @dev Borrow ETH
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param dstChainId Destination chain id
	 **/
	function borrowETH(uint256 amount, uint256 interestRateMode, uint16 dstChainId) internal {
		lendingPool.borrow(address(weth), amount, interestRateMode, 0, msg.sender);
		weth.withdraw(amount);
		uint256 feeAmount = getXChainBorrowFeeAmount(amount);
		_safeTransferETH(daoTreasury, feeAmount);
		amount = amount.sub(feeAmount);

		routerETH.swapETH{value: amount.add(msg.value)}(
			dstChainId, // dest chain id
			payable(msg.sender), // receive address
			abi.encodePacked(msg.sender),
			amount, // transfer amount
			amount.mul(99).div(100) // max slippage: 1%
		);
	}

	/**
	 * @dev transfer ETH to an address, revert if it fails.
	 * @param to recipient of the transfer
	 * @param value the amount to send
	 */
	function _safeTransferETH(address to, uint256 value) internal {
		(bool success, ) = to.call{value: value}(new bytes(0));
		require(success, "ETH_TRANSFER_FAILED");
	}
}
