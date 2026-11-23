"""Linear-sweep disassembly for EVM runtime bytecode.

The decoder is deliberately conservative: it walks the instruction stream, consumes PUSH
immediates, and reports truncated immediates instead of guessing. Metadata appended by solc is
stripped before decoding when the CBOR trailer can be identified.
"""

from dataclasses import dataclass
from typing import Optional

from .opcodes import name_of, push_size


@dataclass(frozen=True)
class Instruction:
    offset: int
    op: int
    name: str
    imm: bytes

    @property
    def imm_int(self) -> Optional[int]:
        if not self.imm:
            return None
        return int.from_bytes(self.imm, "big")

    def text(self) -> str:
        if self.imm:
            return f"{self.offset:06x}: {self.name} 0x{self.imm.hex()}"
        return f"{self.offset:06x}: {self.name}"


@dataclass(frozen=True)
class Metadata:
    metadata_bytes: int
    payload_offset: int
    cbor_magic: int


def strip_metadata(code: bytes) -> tuple[bytes, Optional[Metadata]]:
    """Remove the solc CBOR trailer when present.

    solc appends: <cbor map><2-byte big-endian length>. The map starts with a CBOR map header
    (0xa1..0xa5). We only strip when both the length and the header are consistent, so random
    bytecode ending in a plausible length is not silently truncated.
    """
    n = len(code)
    if n < 4:
        return code, None
    length = int.from_bytes(code[-2:], "big")
    start = n - 2 - length
    if length == 0 or start <= 0 or start >= n - 2:
        return code, None
    if not 0xA1 <= code[start] <= 0xA5:
        return code, None
    return code[:start], Metadata(
        metadata_bytes=n - start,
        payload_offset=start,
        cbor_magic=code[start],
    )


def decode(code: bytes, limit: Optional[int] = None) -> list[Instruction]:
    """Decode runtime bytecode into instructions."""
    out: list[Instruction] = []
    i = 0
    n = len(code)
    while i < n:
        if limit is not None and len(out) >= limit:
            break
        op = code[i]
        size = push_size(op)
        imm = code[i + 1 : i + 1 + size]
        out.append(Instruction(offset=i, op=op, name=name_of(op), imm=imm))
        i += 1 + size
    return out


def histogram(instrs: list[Instruction]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for ins in instrs:
        counts[ins.name] = counts.get(ins.name, 0) + 1
    return dict(sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))


def summary(code: bytes) -> dict:
    """One-call overview used by the CLI and by the case reports."""
    body, meta = strip_metadata(code)
    instrs = decode(body)
    return {
        "size": len(code),
        "code_size": len(body),
        "metadata_bytes": meta.metadata_bytes if meta else 0,
        "instructions": len(instrs),
        "opcodes": histogram(instrs),
        "jumpdests": sum(1 for i in instrs if i.op == 0x5B),
        "truncated_push": any(
            len(i.imm) != push_size(i.op) for i in instrs if i.op >= 0x60
        ),
    }


def load_code(path) -> bytes:
    """Read runtime bytecode from a raw `.bin` or from a hex dump (`cast code` output, `0x…`).

    Hex text is accepted so a sample can live in the repository as readable text and still be fed
    to every command; anything that does not look like hex is treated as raw bytes.
    """
    raw = path.read_bytes()
    head = raw.lstrip()[:2]
    if head == b"0x" or head == b"0X":
        raw = raw.lstrip()[2:]
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError:
        return raw
    compact = "".join(text.split())
    if len(compact) < 2 or len(compact) % 2 or any(c not in "0123456789abcdefABCDEF" for c in compact):
        return raw
    return bytes.fromhex(compact)
