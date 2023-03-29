// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "../../dependencies/openzeppelin/upgradeability/Initializable.sol";
import "../../dependencies/openzeppelin/upgradeability/OwnableUpgradeable.sol";

import "../../interfaces/IMiddleFeeDistribution.sol";
import "../../interfaces/IMultiFeeDistribution.sol";
import "../../interfaces/IMintableToken.sol";
import "../../interfaces/IAaveOracle.sol";
import "../../interfaces/IAToken.sol";
import "../../interfaces/IChainlinkAggregator.sol";

/// @title Fee distributor inside
/// @author Radiant
/// @dev All function calls are currently implemented without side effects
contract MiddleFeeDistribution is IMiddleFeeDistribution, Initializable, OwnableUpgradeable {
	using SafeMath for uint256;
	using SafeERC20 for IERC20;

	/// @notice RDNT token
	IMintableToken public rdntToken;

	/// @notice Fee distributor contract for earnings and RDNT lockings
	IMultiFeeDistribution public multiFeeDistribution;

	/// @notice Reward ratio for operation expenses
	uint256 public override operationExpenseRatio;

	uint256 public constant RATIO_DIVISOR = 10000;

	uint8 public constant DECIMALS = 18;

	mapping(address => bool) public override isRewardToken;

	/// @notice Operation Expense account
	address public override operationExpenses;

	/// @notice Admin address
	address public admin;

	// AAVE Oracle address
	address internal _aaveOracle;

	/********************** Events ***********************/

	/// @notice Emitted when ERC20 token is recovered
	event Recovered(address token, uint256 amount);

	/// @notice Emitted when reward token is forwarded
	event ForwardReward(address token, uint256 amount);

	/// @notice Emitted when OpEx info is updated
	event SetOperationExpenses(address opEx, uint256 ratio);

	/// @notice Emitted when operation expenses is set
	event OperationExpensesUpdated(address _operationExpenses, uint256 _operationExpenseRatio);

	event NewTransferAdded(address indexed asset, uint256 lpUsdValue);

	/**
	 * @dev Throws if called by any account other than the admin or owner.
	 */
	modifier onlyAdminOrOwner() {
		require(admin == _msgSender() || owner() == _msgSender(), "caller is not the admin or owner");
		_;
	}

	function initialize(
		address _rdntToken,
		address aaveOracle,
		IMultiFeeDistribution _multiFeeDistribution
	) public initializer {
		require(_rdntToken != address(0), "rdntToken is 0 address");
		require(aaveOracle != address(0), "aaveOracle is 0 address");
		__Ownable_init();

		rdntToken = IMintableToken(_rdntToken);
		_aaveOracle = aaveOracle;
		multiFeeDistribution = _multiFeeDistribution;

		admin = msg.sender;
	}

	/**
	 * @notice Set operation expenses account
	 */
	function setOperationExpenses(address _operationExpenses, uint256 _operationExpenseRatio) external onlyOwner {
		require(_operationExpenseRatio <= RATIO_DIVISOR, "Invalid ratio");
		require(_operationExpenses != address(0), "operationExpenses is 0 address");
		operationExpenses = _operationExpenses;
		operationExpenseRatio = _operationExpenseRatio;
		emit OperationExpensesUpdated(_operationExpenses, _operationExpenseRatio);
	}

	function setAdmin(address _configurator) external onlyOwner {
		require(_configurator != address(0), "configurator is 0 address");
		admin = _configurator;
	}

	/**
	 * @notice Add a new reward token to be distributed to stakers
	 */
	function addReward(address _rewardsToken) external override onlyAdminOrOwner {
		multiFeeDistribution.addReward(_rewardsToken);
		isRewardToken[_rewardsToken] = true;
	}

	/**
	 * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
	 */
	function forwardReward(address[] memory _rewardTokens) external override {
		require(msg.sender == address(multiFeeDistribution),"!mfd");

		for (uint256 i = 0; i < _rewardTokens.length; i += 1) {
			uint256 total = IERC20(_rewardTokens[i]).balanceOf(address(this));

			if (operationExpenses != address(0) && operationExpenseRatio != 0) {
				uint256 opExAmount = total.mul(operationExpenseRatio).div(RATIO_DIVISOR);
				if (opExAmount != 0) {
					IERC20(_rewardTokens[i]).safeTransfer(operationExpenses, opExAmount);
				}
				total = total.sub(opExAmount);
			}
			total = IERC20(_rewardTokens[i]).balanceOf(address(this));
			IERC20(_rewardTokens[i]).safeTransfer(address(multiFeeDistribution), total);

			emitNewTransferAdded(_rewardTokens[i], total);
		}
	}

	function getRdntTokenAddress() external view override returns (address) {
		return address(rdntToken);
	}

	function getMultiFeeDistributionAddress() external view override returns (address) {
		return address(multiFeeDistribution);
	}

	/**
	 * @notice Returns lock information of a user.
	 * @dev It currently returns just MFD infos.
	 */
	function lockedBalances(
		address user
	)
		external
		view
		override
		returns (
			uint256 total,
			uint256 unlockable,
			uint256 locked,
			uint256 lockedWithMultiplier,
			LockedBalance[] memory lockData
		)
	{
		return multiFeeDistribution.lockedBalances(user);
	}

	function emitNewTransferAdded(address asset, uint256 lpReward) internal {
		if (asset != address(rdntToken)) {
			address underlying = IAToken(asset).UNDERLYING_ASSET_ADDRESS();
			uint256 assetPrice = IAaveOracle(_aaveOracle).getAssetPrice(underlying);
			address sourceOfAsset = IAaveOracle(_aaveOracle).getSourceOfAsset(underlying);
			uint8 priceDecimal = IChainlinkAggregator(sourceOfAsset).decimals();
			uint8 assetDecimals = IERC20Metadata(asset).decimals();
			uint256 lpUsdValue = assetPrice.mul(lpReward).mul(10 ** DECIMALS).div(10 ** priceDecimal).div(
				10 ** assetDecimals
			);
			emit NewTransferAdded(asset, lpUsdValue);
		}
	}

	/**
	 * @notice Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
	 */
	function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
		IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
		emit Recovered(tokenAddress, tokenAmount);
	}
}
