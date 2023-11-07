// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {DustRefunder} from "./DustRefunder.sol";
import {BNum} from "../../../dependencies/math/BNum.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {IBalancerPoolHelper} from "../../../interfaces/IPoolHelper.sol";
import {IWETH} from "../../../interfaces/IWETH.sol";
import {IWeightedPoolFactory, IWeightedPool, IAsset, IVault, IBalancerQueries} from "../../../interfaces/balancer/IWeightedPoolFactory.sol";
import {VaultReentrancyLib} from "../../libraries/balancer-reentrancy/VaultReentrancyLib.sol";

/// @title Balance Pool Helper Contract
/// @author Radiant
contract BalancerPoolHelper is IBalancerPoolHelper, Initializable, OwnableUpgradeable, BNum, DustRefunder {
	using SafeERC20 for IERC20;

	error AddressZero();
	error PoolExists();
	error InsufficientPermission();
	error IdenticalAddresses();
	error ZeroAmount();
	error QuoteFail();

	address public inTokenAddr;
	address public outTokenAddr;
	address public wethAddr;
	address public lpTokenAddr;
	address public vaultAddr;
	bytes32 public poolId;
	address public lockZap;
	IWeightedPoolFactory public poolFactory;
	uint256 public constant RDNT_WEIGHT = 800000000000000000;
	uint256 public constant WETH_WEIGHT = 200000000000000000;
	uint256 public constant INITIAL_SWAP_FEE_PERCENTAGE = 5000000000000000;

	/// @notice In 80/20 pool, RDNT Weight is 4x of WETH weight
	uint256 public constant POOL_WEIGHT = 4;

	bytes32 public constant WBTC_WETH_USDC_POOL_ID = 0x64541216bafffeec8ea535bb71fbc927831d0595000100000000000000000002;
	bytes32 public constant DAI_USDT_USDC_POOL_ID = 0x1533a3278f3f9141d5f820a184ea4b017fce2382000000000000000000000016;
	address public constant REAL_WETH_ADDR = address(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1);

	address public constant BALANCER_QUERIES = 0xE39B5e3B6D74016b2F6A9673D7d7493B6DF549d5;

	address public constant USDT_ADDRESS = address(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9);
	address public constant DAI_ADDRESS = address(0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1);
	address public constant USDC_ADDRESS = address(0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8);

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param _inTokenAddr input token of the pool
	 * @param _outTokenAddr output token of the pool
	 * @param _wethAddr WETH address
	 * @param _vault Balancer Vault
	 * @param _poolFactory Balancer pool factory address
	 */
	function initialize(
		address _inTokenAddr,
		address _outTokenAddr,
		address _wethAddr,
		address _vault,
		IWeightedPoolFactory _poolFactory
	) external initializer {
		if (_inTokenAddr == address(0)) revert AddressZero();
		if (_outTokenAddr == address(0)) revert AddressZero();
		if (_wethAddr == address(0)) revert AddressZero();
		if (_vault == address(0)) revert AddressZero();
		if (address(_poolFactory) == address(0)) revert AddressZero();

		__Ownable_init();
		inTokenAddr = _inTokenAddr;
		outTokenAddr = _outTokenAddr;
		wethAddr = _wethAddr;
		vaultAddr = _vault;
		poolFactory = _poolFactory;
	}

	/**
	 * @notice Initialize a new pool.
	 * @param _tokenName Token name of lp token
	 * @param _tokenSymbol Token symbol of lp token
	 */
	function initializePool(string calldata _tokenName, string calldata _tokenSymbol) public onlyOwner {
		if (lpTokenAddr != address(0)) revert PoolExists();

		(address token0, address token1) = _sortTokens(inTokenAddr, outTokenAddr);

		IERC20[] memory tokens = new IERC20[](2);
		tokens[0] = IERC20(token0);
		tokens[1] = IERC20(token1);

		address[] memory rateProviders = new address[](2);
		rateProviders[0] = 0x0000000000000000000000000000000000000000;
		rateProviders[1] = 0x0000000000000000000000000000000000000000;

		uint256[] memory weights = new uint256[](2);

		if (token0 == outTokenAddr) {
			weights[0] = RDNT_WEIGHT;
			weights[1] = WETH_WEIGHT;
		} else {
			weights[0] = WETH_WEIGHT;
			weights[1] = RDNT_WEIGHT;
		}

		lpTokenAddr = poolFactory.create(
			_tokenName,
			_tokenSymbol,
			tokens,
			weights,
			rateProviders,
			INITIAL_SWAP_FEE_PERCENTAGE,
			address(this),
			"UwU"
		);

		poolId = IWeightedPool(lpTokenAddr).getPoolId();

		IERC20 outToken = IERC20(outTokenAddr);
		IERC20 inToken = IERC20(inTokenAddr);
		IERC20 lp = IERC20(lpTokenAddr);
		IERC20 weth = IERC20(wethAddr);

		outToken.forceApprove(vaultAddr, type(uint256).max);
		inToken.forceApprove(vaultAddr, type(uint256).max);
		weth.approve(vaultAddr, type(uint256).max);

		IAsset[] memory assets = new IAsset[](2);
		assets[0] = IAsset(token0);
		assets[1] = IAsset(token1);

		uint256 inTokenAmt = inToken.balanceOf(address(this));
		uint256 outTokenAmt = outToken.balanceOf(address(this));

		uint256[] memory maxAmountsIn = new uint256[](2);
		if (token0 == inTokenAddr) {
			maxAmountsIn[0] = inTokenAmt;
			maxAmountsIn[1] = outTokenAmt;
		} else {
			maxAmountsIn[0] = outTokenAmt;
			maxAmountsIn[1] = inTokenAmt;
		}

		IVault.JoinPoolRequest memory inRequest = IVault.JoinPoolRequest(
			assets,
			maxAmountsIn,
			abi.encode(0, maxAmountsIn),
			false
		);
		IVault(vaultAddr).joinPool(poolId, address(this), address(this), inRequest);
		uint256 liquidity = lp.balanceOf(address(this));
		lp.safeTransfer(msg.sender, liquidity);
	}

	/// @dev Return fair reserve amounts given spot reserves, weights, and fair prices.
	/// @param resA Reserve of the first asset
	/// @param resB Reserve of the second asset
	/// @param wA Weight of the first asset
	/// @param wB Weight of the second asset
	/// @param pxA Fair price of the first asset
	/// @param pxB Fair price of the second asset
	function _computeFairReserves(
		uint256 resA,
		uint256 resB,
		uint256 wA,
		uint256 wB,
		uint256 pxA,
		uint256 pxB
	) internal pure returns (uint256 fairResA, uint256 fairResB) {
		// NOTE: wA + wB = 1 (normalize weights)
		// constant product = resA^wA * resB^wB
		// constraints:
		// - fairResA^wA * fairResB^wB = constant product
		// - fairResA * pxA / wA = fairResB * pxB / wB
		// Solving equations:
		// --> fairResA^wA * (fairResA * (pxA * wB) / (wA * pxB))^wB = constant product
		// --> fairResA / r1^wB = constant product
		// --> fairResA = resA^wA * resB^wB * r1^wB
		// --> fairResA = resA * (resB/resA)^wB * r1^wB = resA * (r1/r0)^wB
		uint256 r0 = bdiv(resA, resB);
		uint256 r1 = bdiv(bmul(wA, pxB), bmul(wB, pxA));
		// fairResA = resA * (r1 / r0) ^ wB
		// fairResB = resB * (r0 / r1) ^ wA
		if (r0 > r1) {
			uint256 ratio = bdiv(r1, r0);
			fairResA = bmul(resA, bpow(ratio, wB));
			fairResB = bdiv(resB, bpow(ratio, wA));
		} else {
			uint256 ratio = bdiv(r0, r1);
			fairResA = bdiv(resA, bpow(ratio, wB));
			fairResB = bmul(resB, bpow(ratio, wA));
		}
	}

	/**
	 * @notice Calculates LP price
	 * @dev Return value decimal is 8
	 * @param rdntPriceInEth RDNT price in ETH
	 * @return priceInEth LP price in ETH
	 */
	function getLpPrice(uint256 rdntPriceInEth) public view returns (uint256 priceInEth) {
		IWeightedPool pool = IWeightedPool(lpTokenAddr);
		(address token0, ) = _sortTokens(inTokenAddr, outTokenAddr);
		(uint256 rdntBalance, uint256 wethBalance, ) = getReserves();
		uint256[] memory weights = pool.getNormalizedWeights();

		uint256 rdntWeight;
		uint256 wethWeight;

		if (token0 == outTokenAddr) {
			rdntWeight = weights[0];
			wethWeight = weights[1];
		} else {
			rdntWeight = weights[1];
			wethWeight = weights[0];
		}

		// RDNT in eth, 8 decis
		uint256 pxA = rdntPriceInEth;
		// ETH in eth, 8 decis
		uint256 pxB = 100000000;

		(uint256 fairResA, uint256 fairResB) = _computeFairReserves(
			rdntBalance,
			wethBalance,
			rdntWeight,
			wethWeight,
			pxA,
			pxB
		);
		// use fairReserveA and fairReserveB to compute LP token price
		// LP price = (fairResA * pxA + fairResB * pxB) / totalLPSupply
		priceInEth = (fairResA * pxA + fairResB * pxB) / pool.totalSupply();
	}

	/**
	 * @notice Returns RDNT price in WETH
	 * @return RDNT price
	 */
	function getPrice() public view returns (uint256) {
		address vaultAddress = vaultAddr;
		VaultReentrancyLib.ensureNotInVaultContext(IVault(vaultAddress));
		(IERC20[] memory tokens, uint256[] memory balances, ) = IVault(vaultAddress).getPoolTokens(poolId);
		uint256 rdntBalance = address(tokens[0]) == outTokenAddr ? balances[0] : balances[1];
		uint256 wethBalance = address(tokens[0]) == outTokenAddr ? balances[1] : balances[0];

		return (wethBalance * 1e8) / (rdntBalance / POOL_WEIGHT);
	}

	/**
	 * @notice Returns reserve information.
	 * @return rdnt RDNT amount
	 * @return weth WETH amount
	 * @return lpTokenSupply LP token supply
	 */
	function getReserves() public view returns (uint256 rdnt, uint256 weth, uint256 lpTokenSupply) {
		IERC20 lpToken = IERC20(lpTokenAddr);

		address vaultAddress = vaultAddr;
		VaultReentrancyLib.ensureNotInVaultContext(IVault(vaultAddress));
		(IERC20[] memory tokens, uint256[] memory balances, ) = IVault(vaultAddress).getPoolTokens(poolId);

		rdnt = address(tokens[0]) == outTokenAddr ? balances[0] : balances[1];
		weth = address(tokens[0]) == outTokenAddr ? balances[1] : balances[0];

		lpTokenSupply = lpToken.totalSupply();
	}

	/**
	 * @notice Add liquidity
	 * @param _wethAmt WETH amount
	 * @param _rdntAmt RDNT amount
	 * @return liquidity amount of LP token
	 */
	function _joinPool(uint256 _wethAmt, uint256 _rdntAmt) internal returns (uint256 liquidity) {
		(address token0, address token1) = _sortTokens(outTokenAddr, inTokenAddr);
		IAsset[] memory assets = new IAsset[](2);
		assets[0] = IAsset(token0);
		assets[1] = IAsset(token1);

		uint256[] memory maxAmountsIn = new uint256[](2);
		if (token0 == inTokenAddr) {
			maxAmountsIn[0] = _wethAmt;
			maxAmountsIn[1] = _rdntAmt;
		} else {
			maxAmountsIn[0] = _rdntAmt;
			maxAmountsIn[1] = _wethAmt;
		}

		bytes memory userDataEncoded = abi.encode(IWeightedPool.JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0);
		IVault.JoinPoolRequest memory inRequest = IVault.JoinPoolRequest(assets, maxAmountsIn, userDataEncoded, false);
		IVault(vaultAddr).joinPool(poolId, address(this), address(this), inRequest);

		IERC20 lp = IERC20(lpTokenAddr);
		liquidity = lp.balanceOf(address(this));
	}

	/**
	 * @notice Gets needed WETH for adding LP
	 * @param lpAmount LP amount
	 * @return wethAmount WETH amount
	 */
	function quoteWETH(uint256 lpAmount) public view override returns (uint256 wethAmount) {
		(address token0, address token1) = _sortTokens(outTokenAddr, inTokenAddr);
		IAsset[] memory assets = new IAsset[](2);
		assets[0] = IAsset(token0);
		assets[1] = IAsset(token1);

		uint256[] memory maxAmountsIn = new uint256[](2);
		uint256 enterTokenIndex;
		if (token0 == inTokenAddr) {
			enterTokenIndex = 0;
			maxAmountsIn[0] = type(uint256).max;
			maxAmountsIn[1] = 0;
		} else {
			enterTokenIndex = 1;
			maxAmountsIn[0] = 0;
			maxAmountsIn[1] = type(uint256).max;
		}

		bytes memory userDataEncoded = abi.encode(
			IWeightedPool.JoinKind.TOKEN_IN_FOR_EXACT_BPT_OUT,
			lpAmount,
			enterTokenIndex
		);
		IVault.JoinPoolRequest memory inRequest = IVault.JoinPoolRequest(assets, maxAmountsIn, userDataEncoded, false);

		(bool success, bytes memory data) = BALANCER_QUERIES.staticcall(
			abi.encodeCall(IBalancerQueries.queryJoin, (poolId, address(this), address(this), inRequest))
		);
		if (!success) revert QuoteFail();
		(, uint256[] memory amountsIn) = abi.decode(data, (uint256, uint256[]));
		return amountsIn[enterTokenIndex];
	}

	/**
	 * @notice Zap WETH
	 * @param amount to zap
	 * @return liquidity token amount
	 */
	function zapWETH(uint256 amount) public returns (uint256 liquidity) {
		if (msg.sender != lockZap) revert InsufficientPermission();
		IWETH(wethAddr).transferFrom(msg.sender, address(this), amount);
		liquidity = _joinPool(amount, 0);
		IERC20 lp = IERC20(lpTokenAddr);
		lp.safeTransfer(msg.sender, liquidity);
		_refundDust(outTokenAddr, wethAddr, msg.sender);
	}

	/**
	 * @notice Zap WETH and RDNT
	 * @param _wethAmt WETH amount
	 * @param _rdntAmt RDNT amount
	 * @return liquidity token amount
	 */
	function zapTokens(uint256 _wethAmt, uint256 _rdntAmt) public returns (uint256 liquidity) {
		if (msg.sender != lockZap) revert InsufficientPermission();
		IWETH(wethAddr).transferFrom(msg.sender, address(this), _wethAmt);
		IERC20(outTokenAddr).safeTransferFrom(msg.sender, address(this), _rdntAmt);

		liquidity = _joinPool(_wethAmt, _rdntAmt);
		IERC20 lp = IERC20(lpTokenAddr);
		lp.safeTransfer(msg.sender, liquidity);

		_refundDust(outTokenAddr, wethAddr, msg.sender);
	}

	/**
	 * @notice Sort tokens
	 */
	function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
		if (tokenA == tokenB) revert IdenticalAddresses();
		(token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
		if (token0 == address(0)) revert AddressZero();
	}

	/**
	 * @notice Calculate quote in WETH from token
	 * @param tokenAmount RDNT amount
	 * @return optimalWETHAmount WETH amount
	 */
	function quoteFromToken(uint256 tokenAmount) public view returns (uint256 optimalWETHAmount) {
		uint256 rdntPriceInEth = getPrice();
		uint256 p1 = rdntPriceInEth * 1e10;
		uint256 ethRequiredBeforeWeight = (tokenAmount * p1) / 1e18;
		optimalWETHAmount = ethRequiredBeforeWeight / POOL_WEIGHT;
	}

	/**
	 * @notice Set lockzap contract
	 */
	function setLockZap(address _lockZap) external onlyOwner {
		if (_lockZap == address(0)) revert AddressZero();
		lockZap = _lockZap;
	}

	/**
	 * @notice Calculate tokenAmount from WETH
	 * @param _inToken input token
	 * @param _wethAmount WETH amount
	 * @return tokenAmount token amount
	 */
	function quoteSwap(address _inToken, uint256 _wethAmount) public view override returns (uint256 tokenAmount) {
		IVault.SingleSwap memory singleSwap;
		singleSwap.poolId = poolId;
		singleSwap.kind = IVault.SwapKind.GIVEN_OUT;
		singleSwap.assetIn = IAsset(_inToken);
		singleSwap.assetOut = IAsset(wethAddr);
		singleSwap.amount = _wethAmount;
		singleSwap.userData = abi.encode(0);

		IVault.FundManagement memory funds;
		funds.sender = address(this);
		funds.fromInternalBalance = false;
		funds.recipient = payable(address(this));
		funds.toInternalBalance = false;

		(bool success, bytes memory data) = BALANCER_QUERIES.staticcall(
			abi.encodeCall(IBalancerQueries.querySwap, (singleSwap, funds))
		);
		if (!success) revert QuoteFail();
		uint256 amountIn = abi.decode(data, (uint256));
		return amountIn;
	}

	/**
	 * @notice Swaps tokens like USDC, DAI, USDT, WBTC to WETH
	 * @param _inToken address of the asset to swap
	 * @param _amount the amount of asset to swap
	 * @param _minAmountOut the minimum WETH amount to accept without reverting
	 */
	function swapToWeth(address _inToken, uint256 _amount, uint256 _minAmountOut) external {
		if (msg.sender != lockZap) revert InsufficientPermission();
		if (_inToken == address(0)) revert AddressZero();
		if (_amount == 0) revert ZeroAmount();
		bool isSingleSwap = true;
		if (_inToken == USDT_ADDRESS || _inToken == DAI_ADDRESS) {
			isSingleSwap = false;
		}

		if (!isSingleSwap) {
			uint256 usdcBalanceBefore = IERC20(USDC_ADDRESS).balanceOf(address(this));
			_swap(_inToken, USDC_ADDRESS, _amount, 0, DAI_USDT_USDC_POOL_ID, address(this));
			uint256 usdcBalanceAfter = IERC20(USDC_ADDRESS).balanceOf(address(this));
			_inToken = USDC_ADDRESS;
			_amount = usdcBalanceAfter - usdcBalanceBefore;
		}

		_swap(_inToken, REAL_WETH_ADDR, _amount, _minAmountOut, WBTC_WETH_USDC_POOL_ID, msg.sender);
	}

	/**
	 * @notice Swaps tokens using the Balancer swap function
	 * @param _inToken address of the asset to swap
	 * @param _outToken address of the asset to receieve
	 * @param _amount the amount of asset to swap
	 * @param _minAmountOut the minimum WETH amount to accept without reverting
	 * @param _poolId The ID of the pool to use for swapping
	 * @param _recipient the receiver of the outToken
	 */
	function _swap(
		address _inToken,
		address _outToken,
		uint256 _amount,
		uint256 _minAmountOut,
		bytes32 _poolId,
		address _recipient
	) internal {
		IVault.SingleSwap memory singleSwap;
		singleSwap.poolId = _poolId;
		singleSwap.kind = IVault.SwapKind.GIVEN_IN;
		singleSwap.assetIn = IAsset(_inToken);
		singleSwap.assetOut = IAsset(_outToken);
		singleSwap.amount = _amount;
		singleSwap.userData = abi.encode(0);

		IVault.FundManagement memory funds;
		funds.sender = address(this);
		funds.fromInternalBalance = false;
		funds.recipient = payable(address(_recipient));
		funds.toInternalBalance = false;

		uint256 currentAllowance = IERC20(_inToken).allowance(address(this), vaultAddr);
		if (_amount > currentAllowance) {
			IERC20(_inToken).forceApprove(vaultAddr, _amount);
		}
		IVault(vaultAddr).swap(singleSwap, funds, _minAmountOut, block.timestamp);
	}

	/**
	 * @notice Get swap fee percentage
	 */
	function getSwapFeePercentage() external view returns (uint256 fee) {
		IWeightedPool pool = IWeightedPool(lpTokenAddr);
		fee = pool.getSwapFeePercentage();
	}

	/**
	 * @notice Set swap fee percentage
	 */
	function setSwapFeePercentage(uint256 _fee) external onlyOwner {
		IWeightedPool pool = IWeightedPool(lpTokenAddr);
		pool.setSwapFeePercentage(_fee);
	}
}
