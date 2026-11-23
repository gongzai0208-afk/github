// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

interface ILegacyMintableERC20 {
    function l1Token() external view returns (address);
    function l2Bridge() external view returns (address);
    function mint(address _to, uint256 _amount) external;
    function burn(address _from, uint256 _amount) external;
}

interface IOptimismMintableERC20 {
    function remoteToken() external view returns (address);
    function bridge() external view returns (address);
    function mint(address _to, uint256 _amount) external;
    function burn(address _from, uint256 _amount) external;
}

/// @notice A token that answers the two interfaces the standard bridge accepts for a mintable
///         counterpart, with `mint` restricted to the bridge. Deployed inside the PoC so the mint
///         path can run without touching a third-party token; the asset is therefore not real, the
///         authorisation is.
contract MintableToken {
    string public name = "Aliased Mint";
    string public symbol = "mALIAS";
    uint8 public constant decimals = 18;

    address public immutable remoteToken;
    address public immutable bridge;
    address public immutable l1Token;
    address public immutable l2Bridge;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address _remoteToken, address _bridge) {
        remoteToken = _remoteToken;
        l1Token = _remoteToken;
        bridge = _bridge;
        l2Bridge = _bridge;
    }

    function supportsInterface(bytes4 _id) external pure returns (bool) {
        return _id == 0x01ffc9a7 || _id == type(ILegacyMintableERC20).interfaceId
            || _id == type(IOptimismMintableERC20).interfaceId;
    }

    function mint(address _to, uint256 _amount) external {
        require(msg.sender == bridge, "only bridge");
        totalSupply += _amount;
        balanceOf[_to] += _amount;
    }

    function burn(address _from, uint256 _amount) external {
        require(msg.sender == bridge, "only bridge");
        balanceOf[_from] -= _amount;
        totalSupply -= _amount;
    }
}
