// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

/// @notice Delayed executor. Ownership of the lending pool sits here, so every parameter change
///         is queued publicly and can only run after `delay`.
contract Timelock {
    address public owner;
    address public pendingOwner;
    uint256 public delay;

    mapping(bytes32 => uint256) public eta;
    uint256 public nonce;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DelayChanged(uint256 oldDelay, uint256 newDelay);
    event Queued(bytes32 indexed id, address target, uint256 value, bytes data, uint256 eta);
    event Cancelled(bytes32 indexed id);
    event Executed(bytes32 indexed id, address target, uint256 value, bytes data);

    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_OWNER");
        _;
    }

    constructor(address owner_, uint256 delay_) {
        require(owner_ != address(0), "OWNER");
        require(delay_ >= 1 hours, "DELAY_TOO_SHORT");
        owner = owner_;
        delay = delay_;
    }

    receive() external payable {}

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OWNER");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NOT_PENDING");
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }

    function setDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= 1 hours, "DELAY_TOO_SHORT");
        emit DelayChanged(delay, newDelay);
        delay = newDelay;
    }

    function queue(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes32 id) {
        id = keccak256(abi.encode(target, value, data, nonce++));
        uint256 readyAt = block.timestamp + delay;
        eta[id] = readyAt;
        emit Queued(id, target, value, data, readyAt);
    }

    function cancel(bytes32 id) external onlyOwner {
        require(eta[id] != 0, "UNKNOWN");
        delete eta[id];
        emit Cancelled(id);
    }

    function execute(bytes32 id, address target, uint256 value, bytes calldata data) external payable onlyOwner {
        require(eta[id] != 0, "UNKNOWN");
        require(block.timestamp >= eta[id], "TOO_EARLY");
        delete eta[id];
        (bool ok, ) = target.call{value: value}(data);
        require(ok, "CALL_FAILED");
        emit Executed(id, target, value, data);
    }
}
