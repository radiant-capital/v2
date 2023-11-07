// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TransferHelper} from "../libraries/TransferHelper.sol";
import {IStargateRouter} from "../../interfaces/IStargateRouter.sol";
import {IRouterETH} from "../../interfaces/IRouterETH.sol";
import {ILendingPool} from "../../interfaces/ILendingPool.sol";
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
contract StargateBorrow is OwnableUpgradeable {
	using SafeERC20 for IERC20;

	/// @notice FEE ratio DIVISOR
	uint256 public constant FEE_PERCENT_DIVISOR = 10000;

	// MAX slippage that cannot be exceeded when setting slippage variable
	uint256 public constant MAX_SLIPPAGE = 80;

	// ETH address
	address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

	// Max reasonable fee, 1%
	uint256 public constant MAX_REASONABLE_FEE = 100;

	/// @notice Stargate Router
	IStargateRouter public router;

	/// @notice Stargate Router ETH
	IRouterETH public routerETH;

	/// @notice Lending Pool address
	ILendingPool public lendingPool;

	// Weth address
	IWETH internal weth;

	// Referral code
	uint16 public constant REFERRAL_CODE = 0;

	/// @notice asset => poolId; at the moment, pool IDs for USDC and USDT are the same accross all chains
	mapping(address => uint256) public poolIdPerChain;

	/// @notice DAO wallet
	address public daoTreasury;

	/// @notice Cross chain borrow fee ratio
	uint256 public xChainBorrowFeePercent;

	/// @notice Max slippage allowed for SG bridge swaps
	/// 99 = 1%
	uint256 public maxSlippage;

	/// @notice Emitted when DAO address is updated
	event DAOTreasuryUpdated(address indexed _daoTreasury);

	/// @notice Emitted when fee info is updated
	event XChainBorrowFeePercentUpdated(uint256 indexed percent);

	/// @notice Emited when pool ids of assets are updated
	event PoolIDsUpdated(address[] assets, uint256[] poolIDs);

	error InvalidRatio();

	error AddressZero();

	/// @notice Emitted when new slippage is set too high
	error SlippageSetToHigh();

	error LengthMismatch();

	constructor() {
		_disableInitializers();
	}

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
		uint256 _xChainBorrowFeePercent,
		uint256 _maxSlippage
	) external initializer {
		if (address(_router) == address(0)) revert AddressZero();
		if (address(_lendingPool) == address(0)) revert AddressZero();
		if (address(_weth) == address(0)) revert AddressZero();
		if (_treasury == address(0)) revert AddressZero();
		if (_xChainBorrowFeePercent > MAX_REASONABLE_FEE) revert AddressZero();
		if (_maxSlippage < MAX_SLIPPAGE) revert SlippageSetToHigh();

		router = _router;
		routerETH = _routerETH;
		lendingPool = _lendingPool;
		daoTreasury = _treasury;
		xChainBorrowFeePercent = _xChainBorrowFeePercent;
		weth = _weth;
		maxSlippage = _maxSlippage;
		__Ownable_init();
	}

	receive() external payable {}

	/**
	 * @notice Set DAO Treasury.
	 * @param _daoTreasury DAO Treasury address.
	 */
	function setDAOTreasury(address _daoTreasury) external onlyOwner {
		if (_daoTreasury == address(0)) revert AddressZero();
		daoTreasury = _daoTreasury;
		emit DAOTreasuryUpdated(_daoTreasury);
	}

	/**
	 * @notice Set Cross Chain Borrow Fee Percent.
	 * @param percent Fee ratio.
	 */
	function setXChainBorrowFeePercent(uint256 percent) external onlyOwner {
		if (percent > MAX_REASONABLE_FEE) revert InvalidRatio();
		xChainBorrowFeePercent = percent;
		emit XChainBorrowFeePercentUpdated(percent);
	}

	/**
	 * @notice Set pool ids of assets.
	 * @param assets array.
	 * @param poolIDs array.
	 */
	function setPoolIDs(address[] calldata assets, uint256[] calldata poolIDs) external onlyOwner {
		uint256 length = assets.length;
		if (length != poolIDs.length) revert LengthMismatch();
		for (uint256 i = 0; i < length; ) {
			poolIdPerChain[assets[i]] = poolIDs[i];
			unchecked {
				i++;
			}
		}
		emit PoolIDsUpdated(assets, poolIDs);
	}

	/**
	 * @notice Set max slippage allowed for StarGate bridge Swaps.
	 * @param _maxSlippage Max slippage allowed.
	 */
	function setMaxSlippage(uint256 _maxSlippage) external onlyOwner {
		if (_maxSlippage < MAX_SLIPPAGE) revert SlippageSetToHigh();
		maxSlippage = _maxSlippage;
	}

	/**
	 * @notice Get Cross Chain Borrow Fee amount.
	 * @param amount Fee cost.
	 * @return Fee amount for cross chain borrow
	 */
	function getXChainBorrowFeeAmount(uint256 amount) public view returns (uint256) {
		uint256 feeAmount = (amount * (xChainBorrowFeePercent)) / (FEE_PERCENT_DIVISOR);
		return feeAmount;
	}

	/**
	 * @notice Quote LZ swap fee
	 * @dev Call Router.sol method to get the value for swap()
	 * @param _dstChainId dest LZ chain id
	 * @param _functionType function type
	 * @param _toAddress address
	 * @param _transferAndCallPayload payload to call after transfer
	 * @param _lzTxParams transaction params
	 * @return Message Fee
	 * @return amount of wei in source gas token
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
	 * @dev Borrow asset for another chain
	 * @param asset for loop
	 * @param amount for the initial deposit
	 * @param interestRateMode stable or variable borrow mode
	 * @param dstChainId Destination chain id
	 **/
	function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 dstChainId) external payable {
		if (address(asset) == ETH_ADDRESS && address(routerETH) != address(0)) {
			_borrowETH(amount, interestRateMode, dstChainId);
		} else {
			lendingPool.borrow(asset, amount, interestRateMode, REFERRAL_CODE, msg.sender);
			uint256 feeAmount = getXChainBorrowFeeAmount(amount);
			if (feeAmount > 0) {
				IERC20(asset).safeTransfer(daoTreasury, feeAmount);
				amount = amount - feeAmount;
			}
			IERC20(asset).forceApprove(address(router), amount);
			router.swap{value: msg.value}(
				dstChainId, // dest chain id
				poolIdPerChain[asset], // src chain pool id
				poolIdPerChain[asset], // dst chain pool id
				payable(msg.sender), // receive address
				amount, // transfer amount
				(amount * maxSlippage) / 100, // max slippage: 1%
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
	function _borrowETH(uint256 amount, uint256 interestRateMode, uint16 dstChainId) internal {
		lendingPool.borrow(address(weth), amount, interestRateMode, REFERRAL_CODE, msg.sender);
		weth.withdraw(amount);
		uint256 feeAmount = getXChainBorrowFeeAmount(amount);
		if (feeAmount > 0) {
			TransferHelper.safeTransferETH(daoTreasury, feeAmount);
			amount = amount - feeAmount;
		}

		routerETH.swapETH{value: amount + msg.value}(
			dstChainId, // dest chain id
			payable(msg.sender), // receive address
			abi.encodePacked(msg.sender),
			amount, // transfer amount
			(amount * maxSlippage) / 100 // max slippage: 1%
		);
	}

	/**
	 * @notice Allows owner to recover ETH locked in this contract.
	 * @param to ETH receiver
	 * @param value ETH amount
	 */
	function withdrawLockedETH(address to, uint256 value) external onlyOwner {
		TransferHelper.safeTransferETH(to, value);
	}
}
