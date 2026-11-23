"""Recover 4-byte selectors from a compiler-generated dispatcher.

Two shapes are common:

    PUSH4 <sel> ... EQ ... PUSHn <dest> JUMPI       (solc, older style)
    DUP1 PUSH4 <sel> ... EQ ... PUSHn <dest> JUMPI  (Vyper and some solc outputs)

Rather than matching one shape, we take every PUSH4 immediate and require an EQ and a JUMPI
within a short window without crossing a terminator. That covers both and stays readable.
"""

from dataclasses import dataclass

from .disasm import Instruction

# Instructions that end a basic block; a lookahead never crosses one.
TERMINATORS = {0x00, 0x56, 0x5B, 0xF3, 0xFD, 0xFE}


@dataclass(frozen=True)
class SelectorHit:
    selector: int
    push_offset: int
    jumpi_offset: int
    distance: int
    dest: int | None = None

    @property
    def hex(self) -> str:
        return f"0x{self.selector:08x}"


def extract(instrs: list[Instruction], lookahead: int = 8) -> list[SelectorHit]:
    hits: list[SelectorHit] = []
    n = len(instrs)
    for i, ins in enumerate(instrs):
        if ins.op != 0x63 or len(ins.imm) != 4:
            continue
        seen_eq = False
        for j in range(i + 1, min(i + lookahead, n)):
            op = instrs[j].op
            if op == 0x14:  # EQ
                seen_eq = True
            elif op == 0x57 and seen_eq:  # JUMPI
                dest = None
                if j - 1 > i and instrs[j - 1].op in (0x60, 0x61, 0x62):
                    if instrs[j - 1].imm:
                        dest = int.from_bytes(instrs[j - 1].imm, "big")
                hits.append(
                    SelectorHit(
                        selector=int.from_bytes(ins.imm, "big"),
                        push_offset=ins.offset,
                        jumpi_offset=instrs[j].offset,
                        distance=j - i,
                        dest=dest,
                    )
                )
                break
            elif op in TERMINATORS:
                break
    return hits


def unique(hits: list[SelectorHit]) -> dict[int, list[SelectorHit]]:
    """Group hits by selector, preserving first-seen order."""
    grouped: dict[int, list[SelectorHit]] = {}
    for hit in hits:
        grouped.setdefault(hit.selector, []).append(hit)
    return grouped
