// SPDX-License-Identifier: MIT
pragma solidity 0.8.12;

import {OFTV2} from "@layerzerolabs/solidity-examples/contracts/token/oft/v2/OFTV2.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IPriceProvider} from "../../interfaces/IPriceProvider.sol";

/// @title Radiant token contract with OFT integration
/// @author Radiant Devs
contract RadiantOFT is OFTV2, Pausable, ReentrancyGuard {
	/// @notice bridge fee reciever
	address private treasury;

	/// @notice Fee ratio for bridging, in bips
	uint256 public feeRatio;

	/// @notice Divisor for fee ratio, 100%
	uint256 public constant FEE_DIVISOR = 10000;

	/// @notice Max reasonable fee, 1%
	uint256 public constant MAX_REASONABLE_FEE = 100;

	/// @notice PriceProvider, for RDNT price in native fee calc
	IPriceProvider public priceProvider;

	/// @notice Decimals for OFTV2
	uint8 public constant SHARED_DECIMALS = 8;

	/// @notice Emitted when fee ratio is updated
	event FeeRatioUpdated(uint256 indexed fee);

	/// @notice Emitted when PriceProvider is updated
	event PriceProviderUpdated(IPriceProvider indexed priceProvider);

	/// @notice Emitted when Treasury is updated
	event TreasuryUpdated(address indexed treasury);

	error AmountTooSmall();

	/// @notice Error message emitted when the provided ETH does not cover the bridge fee
	error InsufficientETHForFee();

	/// @notice Emitted when null address is set
	error AddressZero();

	/// @notice Emitted when ratio is invalid
	error InvalidRatio();

	/**
	 * @notice Create RadiantOFT
	 * @param _tokenName token name
	 * @param _symbol token symbol
	 * @param _endpoint LZ endpoint for network
	 * @param _dao DAO address, for initial mint
	 * @param _treasury Treasury address, for fee recieve
	 * @param _mintAmt Mint amount
	 */
	constructor(
		string memory _tokenName,
		string memory _symbol,
		address _endpoint,
		address _dao,
		address _treasury,
		uint256 _mintAmt
	) OFTV2(_tokenName, _symbol, SHARED_DECIMALS, _endpoint) {
		if (_endpoint == address(0)) revert AddressZero();
		if (_dao == address(0)) revert AddressZero();
		if (_treasury == address(0)) revert AddressZero();

		treasury = _treasury;

		if (_mintAmt != 0) {
			_mint(_dao, _mintAmt);
		}
	}

	/**
	 * @notice Burn tokens.
	 * @param _amount to burn
	 */
	function burn(uint256 _amount) public {
		_burn(_msgSender(), _amount);
	}

	/**
	 * @notice Pause bridge operation.
	 */
	function pause() public onlyOwner {
		_pause();
	}

	/**
	 * @notice Unpause bridge operation.
	 */
	function unpause() public onlyOwner {
		_unpause();
	}

	/**
	 * @notice Returns LZ fee + Bridge fee
	 * @dev overrides default OFT estimate fee function to add native fee
	 * @param _dstChainId dest LZ chain id
	 * @param _toAddress to addr on dst chain
	 * @param _amount amount to bridge
	 * @param _useZro use ZRO token, someday ;)
	 * @param _adapterParams LZ adapter params
	 */
	function estimateSendFee(
		uint16 _dstChainId,
		bytes32 _toAddress,
		uint256 _amount,
		bool _useZro,
		bytes calldata _adapterParams
	) public view override returns (uint256 nativeFee, uint256 zroFee) {
		(nativeFee, zroFee) = super.estimateSendFee(_dstChainId, _toAddress, _amount, _useZro, _adapterParams);
		nativeFee = nativeFee + getBridgeFee(_amount);
	}

	function _updatePrice() internal {
		if (address(priceProvider) != address(0)) {
			priceProvider.update();
		}
	}

	/**
	 * @notice Returns amount after dust
	 * @dev overrides default OFT _send function to add native fee
	 * @param _from from addr
	 * @param _dstChainId dest LZ chain id
	 * @param _toAddress to addr on dst chain
	 * @param _amount amount to bridge
	 * @param _refundAddress refund addr
	 * @param _zroPaymentAddress use ZRO token, someday ;)
	 * @param _adapterParams LZ adapter params
	 */
	function _send(
		address _from,
		uint16 _dstChainId,
		bytes32 _toAddress,
		uint256 _amount,
		address payable _refundAddress,
		address _zroPaymentAddress,
		bytes memory _adapterParams
	) internal override nonReentrant whenNotPaused returns (uint256 amount) {
		_updatePrice();

		(amount, ) = _removeDust(_amount);
		uint256 fee = getBridgeFee(amount);
		if (msg.value < fee) revert InsufficientETHForFee();

		_checkAdapterParams(_dstChainId, PT_SEND, _adapterParams, NO_EXTRA_GAS);

		if (amount == 0) revert AmountTooSmall();
		_debitFrom(_from, _dstChainId, _toAddress, amount); // amount returned should not have dust

		bytes memory lzPayload = _encodeSendPayload(_toAddress, _ld2sd(amount));
		_lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value - fee);

		if (fee > 0) {
			Address.sendValue(payable(treasury), fee);
		}

		emit SendToChain(_dstChainId, _from, _toAddress, amount);
	}

	/**
	 * @notice Bridge token and execute calldata on destination chain
	 * @dev overrides default OFT _sendAndCall function to add native fee
	 * @param _from from addr
	 * @param _dstChainId dest LZ chain id
	 * @param _toAddress to addr on dst chain
	 * @param _amount amount to bridge
	 * @param _payload calldata to execute on dst chain
	 * @param _dstGasForCall amount of gas to use on dst chain
	 * @param _refundAddress refund addr
	 * @param _zroPaymentAddress use ZRO token, someday ;)
	 * @param _adapterParams LZ adapter params
	 */
	function _sendAndCall(
		address _from,
		uint16 _dstChainId,
		bytes32 _toAddress,
		uint _amount,
		bytes memory _payload,
		uint64 _dstGasForCall,
		address payable _refundAddress,
		address _zroPaymentAddress,
		bytes memory _adapterParams
	) internal override nonReentrant whenNotPaused returns (uint amount) {
		_updatePrice();

		(amount, ) = _removeDust(_amount);
		uint256 fee = getBridgeFee(amount);
		if (msg.value < fee) revert InsufficientETHForFee();

		_checkAdapterParams(_dstChainId, PT_SEND_AND_CALL, _adapterParams, _dstGasForCall);

		if (amount == 0) revert AmountTooSmall();
		_debitFrom(_from, _dstChainId, _toAddress, amount);

		// encode the msg.sender into the payload instead of _from
		bytes memory lzPayload = _encodeSendAndCallPayload(
			msg.sender,
			_toAddress,
			_ld2sd(amount),
			_payload,
			_dstGasForCall
		);
		_lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value - fee);

		if (fee > 0) {
			Address.sendValue(payable(treasury), fee);
		}

		emit SendToChain(_dstChainId, _from, _toAddress, amount);
	}

	/**
	 * @notice overrides default OFT _debitFrom function to make pauseable
	 * @param _from from addr
	 * @param _dstChainId dest LZ chain id
	 * @param _toAddress to addr on dst chain
	 * @param _amount amount to bridge
	 */
	function _debitFrom(
		address _from,
		uint16 _dstChainId,
		bytes32 _toAddress,
		uint256 _amount
	) internal override whenNotPaused returns (uint256) {
		return super._debitFrom(_from, _dstChainId, _toAddress, _amount);
	}

	/**
	 * @notice Bridge fee amount
	 * @param _rdntAmount amount for bridge
	 * @return bridgeFee calculated bridge fee
	 */
	function getBridgeFee(uint256 _rdntAmount) public view returns (uint256 bridgeFee) {
		if (address(priceProvider) == address(0)) {
			return 0;
		}
		uint256 priceInEth = priceProvider.getTokenPrice();
		uint256 priceDecimals = priceProvider.decimals();
		uint256 rdntInEth = (_rdntAmount * priceInEth * (10 ** 18)) / (10 ** priceDecimals) / (10 ** decimals());
		bridgeFee = (rdntInEth * feeRatio) / FEE_DIVISOR;
	}

	/**
	 * @notice Set fee info
	 * @param _feeRatio ratio
	 */
	function setFeeRatio(uint256 _feeRatio) external onlyOwner {
		if (_feeRatio > MAX_REASONABLE_FEE) revert InvalidRatio();
		feeRatio = _feeRatio;
		emit FeeRatioUpdated(_feeRatio);
	}

	/**
	 * @notice Set price provider
	 * @param _priceProvider address
	 */
	function setPriceProvider(IPriceProvider _priceProvider) external onlyOwner {
		if (address(_priceProvider) == address(0)) revert AddressZero();
		priceProvider = _priceProvider;
		emit PriceProviderUpdated(_priceProvider);
	}

	/**
	 * @notice Set Treasury
	 * @param _treasury address
	 */
	function setTreasury(address _treasury) external onlyOwner {
		if (_treasury == address(0)) revert AddressZero();
		treasury = _treasury;
		emit TreasuryUpdated(_treasury);
	}
}
