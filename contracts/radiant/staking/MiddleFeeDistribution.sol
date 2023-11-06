// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {RecoverERC20} from "../libraries/RecoverERC20.sol";
import {IMiddleFeeDistribution} from "../../interfaces/IMiddleFeeDistribution.sol";
import {IMultiFeeDistribution} from "../../interfaces/IMultiFeeDistribution.sol";
import {IMintableToken} from "../../interfaces/IMintableToken.sol";
import {IAaveOracle} from "../../interfaces/IAaveOracle.sol";
import {IAToken} from "../../interfaces/IAToken.sol";
import {IChainlinkAggregator} from "../../interfaces/IChainlinkAggregator.sol";
import {IAaveProtocolDataProvider} from "../../interfaces/IAaveProtocolDataProvider.sol";

/// @title Fee distributor inside
/// @author Radiant
contract MiddleFeeDistribution is IMiddleFeeDistribution, Initializable, OwnableUpgradeable, RecoverERC20 {
	using SafeERC20 for IERC20;

	/// @notice RDNT token
	IMintableToken public rdntToken;

	/// @notice Fee distributor contract for earnings and RDNT lockings
	IMultiFeeDistribution public multiFeeDistribution;

	/// @notice Reward ratio for operation expenses
	uint256 public operationExpenseRatio;

	uint256 public constant RATIO_DIVISOR = 10000;

	uint8 public constant DECIMALS = 18;

	mapping(address => bool) public isRewardToken;

	/// @notice Operation Expense account
	address public operationExpenses;

	/// @notice Admin address
	address public admin;

	// AAVE Oracle address
	address internal _aaveOracle;

	// AAVE Protocol Data Provider address
	IAaveProtocolDataProvider public aaveProtocolDataProvider;

	/********************** Events ***********************/

	/// @notice Emitted when reward token is forwarded
	event ForwardReward(address indexed token, uint256 amount);

	/// @notice Emitted when operation expenses is set
	event OperationExpensesUpdated(address indexed _operationExpenses, uint256 _operationExpenseRatio);

	event NewTransferAdded(address indexed asset, uint256 lpUsdValue);

	event AdminUpdated(address indexed _configurator);

	event RewardsUpdated(address indexed _rewardsToken);

	event ProtocolDataProviderUpdated(address indexed _providerAddress);

	/********************** Errors ***********************/

	error ZeroAddress();

	error IncompatibleToken();

	error InvalidRatio();

	error NotMFD();

	error InsufficientPermission();

	/**
	 * @dev Throws if called by any account other than the admin or owner.
	 */
	modifier onlyAdminOrOwner() {
		if (admin != _msgSender() && owner() != _msgSender()) revert InsufficientPermission();
		_;
	}

	constructor() {
		_disableInitializers();
	}

	/**
	 * @notice Initializer
	 * @param rdntToken_ RDNT address
	 * @param aaveOracle_ Aave oracle address
	 * @param multiFeeDistribution_ Multi fee distribution contract
	 */
	function initialize(
		IMintableToken rdntToken_,
		address aaveOracle_,
		IMultiFeeDistribution multiFeeDistribution_,
		IAaveProtocolDataProvider aaveProtocolDataProvider_
	) public initializer {
		if (aaveOracle_ == address(0)) revert ZeroAddress();
		if (address(rdntToken_) == address(0)) revert ZeroAddress();
		if (address(multiFeeDistribution_) == address(0)) revert ZeroAddress();
		if (address(aaveProtocolDataProvider_) == address(0)) revert ZeroAddress();

		__Ownable_init();

		rdntToken = rdntToken_;
		_aaveOracle = aaveOracle_;
		multiFeeDistribution = multiFeeDistribution_;
		aaveProtocolDataProvider = aaveProtocolDataProvider_;

		admin = msg.sender;
	}

	/**
	 * @notice Set operation expenses account
	 * @param _operationExpenses Address to receive operation expenses
	 * @param _operationExpenseRatio Proportion of operation expense
	 */
	function setOperationExpenses(address _operationExpenses, uint256 _operationExpenseRatio) external onlyOwner {
		if (_operationExpenseRatio > RATIO_DIVISOR) revert InvalidRatio();
		if (_operationExpenses == address(0)) revert ZeroAddress();
		operationExpenses = _operationExpenses;
		operationExpenseRatio = _operationExpenseRatio;
		emit OperationExpensesUpdated(_operationExpenses, _operationExpenseRatio);
	}

	/**
	 * @notice Sets pool configurator as admin.
	 * @param _configurator Configurator address
	 */
	function setAdmin(address _configurator) external onlyOwner {
		if (_configurator == address(0)) revert ZeroAddress();
		admin = _configurator;
		emit AdminUpdated(_configurator);
	}

	/**
	 * @notice Set the Protocol Data Provider address
	 * @param _providerAddress The address of the protocol data provider contract
	 */
	function setProtocolDataProvider(IAaveProtocolDataProvider _providerAddress) external onlyOwner {
		if (address(_providerAddress) == address(0)) revert ZeroAddress();
		aaveProtocolDataProvider = _providerAddress;
		emit ProtocolDataProviderUpdated(address(_providerAddress));
	}

	/**
	 * @notice Add a new reward token to be distributed to stakers
	 * @param _rewardsToken address of the reward token
	 */
	function addReward(address _rewardsToken) external onlyAdminOrOwner {
		if (msg.sender != admin) {
			try IAToken(_rewardsToken).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
				(address aTokenAddress, , ) = aaveProtocolDataProvider.getReserveTokensAddresses(underlying);
				if (aTokenAddress == address(0)) revert IncompatibleToken();
			} catch {
				// _rewardsToken is not an rToken, do nothing
			}
		}
		multiFeeDistribution.addReward(_rewardsToken);
		isRewardToken[_rewardsToken] = true;
		emit RewardsUpdated(_rewardsToken);
	}

	/**
	 * @notice Remove an existing reward token
	 */
	function removeReward(address _rewardsToken) external onlyAdminOrOwner {
		if (_rewardsToken == address(0)) revert ZeroAddress();
		multiFeeDistribution.removeReward(_rewardsToken);
		isRewardToken[_rewardsToken] = false;
		emit RewardsUpdated(_rewardsToken);
	}

	/**
	 * @notice Run by MFD to pull pending platform revenue
	 * @param _rewardTokens an array of reward token addresses
	 */
	function forwardReward(address[] memory _rewardTokens) external {
		if (msg.sender != address(multiFeeDistribution)) revert NotMFD();

		uint256 length = _rewardTokens.length;
		for (uint256 i = 0; i < length; ) {
			address rewardToken = _rewardTokens[i];
			uint256 total = IERC20(rewardToken).balanceOf(address(this));

			if (operationExpenses != address(0) && operationExpenseRatio != 0) {
				uint256 opExAmount = (total * operationExpenseRatio) / RATIO_DIVISOR;
				if (opExAmount != 0) {
					IERC20(rewardToken).safeTransfer(operationExpenses, opExAmount);
				}
			}

			total = IERC20(rewardToken).balanceOf(address(this));
			IERC20(rewardToken).safeTransfer(address(multiFeeDistribution), total);

			if (rewardToken == address(rdntToken)) {
				multiFeeDistribution.vestTokens(address(multiFeeDistribution), total, false);
			}

			emit ForwardReward(rewardToken, total);

			_emitNewTransferAdded(rewardToken, total);
			unchecked {
				i++;
			}
		}
	}

	/**
	 * @notice Returns RDNT token address.
	 * @return RDNT token address
	 */
	function getRdntTokenAddress() external view returns (address) {
		return address(rdntToken);
	}

	/**
	 * @notice Returns MFD address.
	 * @return MFD address
	 */
	function getMultiFeeDistributionAddress() external view returns (address) {
		return address(multiFeeDistribution);
	}

	/**
	 * @notice Emit event for new asset reward
	 * @param asset address of transfer assset
	 * @param lpReward amount of rewards
	 */
	function _emitNewTransferAdded(address asset, uint256 lpReward) internal {
		uint256 lpUsdValue;
		if (asset != address(rdntToken)) {
			address assetAddress;

			try IAToken(asset).UNDERLYING_ASSET_ADDRESS() returns (address underlyingAddress) {
				assetAddress = underlyingAddress;
			} catch {
				assetAddress = asset;
			}

			uint256 assetPrice = IAaveOracle(_aaveOracle).getAssetPrice(assetAddress);
			address sourceOfAsset = IAaveOracle(_aaveOracle).getSourceOfAsset(assetAddress);

			uint8 priceDecimals;
			try IChainlinkAggregator(sourceOfAsset).decimals() returns (uint8 decimals) {
				priceDecimals = decimals;
			} catch {
				priceDecimals = 8;
			}

			// note using original asset arg here, so it uses the rToken
			uint8 assetDecimals = IERC20Metadata(asset).decimals();
			lpUsdValue = (assetPrice * lpReward * (10 ** DECIMALS)) / (10 ** priceDecimals) / (10 ** assetDecimals);
			emit NewTransferAdded(asset, lpUsdValue);
		}
	}

	/**
	 * @notice Added to support recovering any ERC20 tokens inside the contract
	 * @param tokenAddress address of erc20 token to recover
	 * @param tokenAmount amount to recover
	 */
	function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
		_recoverERC20(tokenAddress, tokenAmount);
	}
}
