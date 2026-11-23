"""Opcode names for the EVM (Cancun and later, including PUSH0/MCOPY/TLOAD/TSTORE)."""

NAMES = {
    0x00: "STOP", 0x01: "ADD", 0x02: "MUL", 0x03: "SUB", 0x04: "DIV",
    0x05: "SDIV", 0x06: "MOD", 0x07: "SMOD", 0x08: "ADDMOD", 0x09: "MULMOD",
    0x0A: "EXP", 0x0B: "SIGNEXTEND",
    0x10: "LT", 0x11: "GT", 0x12: "SLT", 0x13: "SGT", 0x14: "EQ",
    0x15: "ISZERO", 0x16: "AND", 0x17: "OR", 0x18: "XOR", 0x19: "NOT",
    0x1A: "BYTE", 0x1B: "SHL", 0x1C: "SHR", 0x1D: "SAR",
    0x20: "KECCAK256",
    0x30: "ADDRESS", 0x31: "BALANCE", 0x32: "ORIGIN", 0x33: "CALLER",
    0x34: "CALLVALUE", 0x35: "CALLDATALOAD", 0x36: "CALLDATASIZE",
    0x37: "CALLDATACOPY", 0x38: "CODESIZE", 0x39: "CODECOPY", 0x3A: "GASPRICE",
    0x3B: "EXTCODESIZE", 0x3C: "EXTCODECOPY", 0x3D: "RETURNDATASIZE",
    0x3E: "RETURNDATACOPY", 0x3F: "EXTCODEHASH",
    0x40: "BLOCKHASH", 0x41: "COINBASE", 0x42: "TIMESTAMP", 0x43: "NUMBER",
    0x44: "PREVRANDAO", 0x45: "GASLIMIT", 0x46: "CHAINID", 0x47: "SELFBALANCE",
    0x48: "BASEFEE", 0x49: "BLOBHASH", 0x4A: "BLOBBASEFEE",
    0x50: "POP", 0x51: "MLOAD", 0x52: "MSTORE", 0x53: "MSTORE8",
    0x54: "SLOAD", 0x55: "SSTORE", 0x56: "JUMP", 0x57: "JUMPI", 0x58: "PC",
    0x59: "MSIZE", 0x5A: "GAS", 0x5B: "JUMPDEST", 0x5C: "TLOAD", 0x5D: "TSTORE",
    0x5E: "MCOPY", 0x5F: "PUSH0",
    0xA0: "LOG0", 0xA1: "LOG1", 0xA2: "LOG2", 0xA3: "LOG3", 0xA4: "LOG4",
    0xF0: "CREATE", 0xF1: "CALL", 0xF2: "CALLCODE", 0xF3: "RETURN",
    0xF4: "DELEGATECALL", 0xF5: "CREATE2", 0xFA: "STATICCALL",
    0xFD: "REVERT", 0xFE: "INVALID", 0xFF: "SELFDESTRUCT",
}


def name_of(op: int) -> str:
    """Human name for an opcode byte, including PUSH/DUP/SWAP/LOG ranges."""
    if op in NAMES:
        return NAMES[op]
    if 0x60 <= op <= 0x7F:
        return f"PUSH{op - 0x5F}"
    if 0x80 <= op <= 0x8F:
        return f"DUP{op - 0x7F}"
    if 0x90 <= op <= 0x9F:
        return f"SWAP{op - 0x8F}"
    if 0xA0 <= op <= 0xA4:
        return f"LOG{op - 0xA0}"
    return f"UNKNOWN_0x{op:02x}"


def push_size(op: int) -> int:
    """Number of immediate bytes following the opcode (0 for non-PUSH)."""
    if 0x60 <= op <= 0x7F:
        return op - 0x5F
    return 0
