// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice The subset of the OP Stack surface this track reads. Signatures are copied from the
///         deployed contracts (contracts-bedrock v3.x); declaring them locally keeps the repo free
///         of a vendored copy of the monorepo and makes every call explicit.
interface IStandardBridge {
    function messenger() external view returns (address);
    function otherBridge() external view returns (address);
    function paused() external view returns (bool);
    function version() external view returns (string memory);

    function bridgeETH(uint32 _minGasLimit, bytes calldata _extraData) external payable;
    function bridgeETHTo(address _to, uint32 _minGasLimit, bytes calldata _extraData) external payable;
    function finalizeBridgeETH(address _from, address _to, uint256 _amount, bytes calldata _extraData)
        external
        payable;
    function finalizeBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _extraData
    ) external;
}

interface ICrossDomainMessenger {
    function OTHER_MESSENGER() external view returns (address);
    function otherMessenger() external view returns (address);
    function xDomainMessageSender() external view returns (address);
    function paused() external view returns (bool);
    function version() external view returns (string memory);
    function messageNonce() external view returns (uint256);
    function successfulMessages(bytes32 _hash) external view returns (bool);
    function failedMessages(bytes32 _hash) external view returns (bool);

    function baseGas(bytes calldata _message, uint32 _minGasLimit) external view returns (uint64);

    function sendMessage(address _target, bytes calldata _message, uint32 _minGasLimit) external payable;

    function relayMessage(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _minGasLimit,
        bytes calldata _message
    ) external payable;
}

interface IOptimismPortal {
    function l2Sender() external view returns (address);
    function paused() external view returns (bool);
    function guardian() external view returns (address);
    function systemConfig() external view returns (address);
    function disputeGameFactory() external view returns (address);
    function superchainConfig() external view returns (address);
    function respectedGameType() external view returns (uint32);
    function proofMaturityDelaySeconds() external view returns (uint256);
    function disputeGameFinalityDelaySeconds() external view returns (uint256);
    function version() external view returns (string memory);
}

interface ISuperchainConfig {
    function paused() external view returns (bool);
    function guardian() external view returns (address);
}

interface ISystemConfig {
    function paused() external view returns (bool);
    function l1CrossDomainMessenger() external view returns (address);
    function gasLimit() external view returns (uint64);
}

interface IDisputeGameFactory {
    function gameCount() external view returns (uint256);
    function gameImpls(uint32 _gameType) external view returns (address);
    function respectedGameType() external view returns (uint32);
}

interface IProxyAdmin {
    function owner() external view returns (address);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
    function symbol() external view returns (string memory);
}

interface IOptimismMintableERC20 is IERC20Metadata {
    function l1Token() external view returns (address);
    function remoteToken() external view returns (address);
    function bridge() external view returns (address);
}
