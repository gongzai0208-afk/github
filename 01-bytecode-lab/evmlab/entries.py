"""First-pass entry table for a dispatcher: which selector goes where, and what the callee touches.

solc emits a small stub per external function (ABI decoding, then `PUSH2 body JUMP`); the body is
laid out elsewhere. Analysing the stub alone reports nothing useful, so this module follows the
stub's final jump and bounds the body by the next body start.

This is triage, not proof. A guard signal means the body *mentions* a caller comparison early; it
does not mean access control is correct. The table exists to decide which function to read next,
and to make "we looked at all N entries" checkable.
"""

from dataclasses import dataclass

from . import disasm, selectors

CALL_OPS = {0xF0, 0xF1, 0xF2, 0xF4, 0xF5, 0xFA}
LOG_RANGE = range(0xA0, 0xA5)


@dataclass(frozen=True)
class Entry:
    selector: int
    dest: int
    body: int
    stub_window: int
    body_window: int
    caller_compare: bool
    address_literal: bool
    sload_early: int
    sstore: int
    external_calls: int
    logs: int
    reverts: int

    @property
    def hex(self) -> str:
        return f"0x{self.selector:08x}"

    def row(self) -> str:
        flags = []
        if self.caller_compare:
            flags.append("caller?")
        if self.address_literal:
            flags.append("addr-literal")
        return (
            f"| `{self.hex}` | 0x{self.dest:04x} | 0x{self.body:04x} | {self.body_window} | "
            f"{', '.join(flags) or '-'} | {self.sload_early} | {self.sstore} | "
            f"{self.external_calls} | {self.logs} | {self.reverts} |"
        )


def _body_target(instrs: list[disasm.Instruction], start: int, end: int) -> int | None:
    """Last `PUSH2 x JUMP` inside the stub gives the body offset."""
    for k in range(end - 1, start, -1):
        if instrs[k].op == 0x56 and k - 1 >= start and instrs[k - 1].op == 0x61:
            if instrs[k - 1].imm:
                return int.from_bytes(instrs[k - 1].imm, "big")
    return None


def _signals(instrs: list[disasm.Instruction], start: int, end: int) -> dict:
    window = instrs[start:end]
    head = window[:60]
    caller_compare = False
    address_literal = False
    for k, ins in enumerate(head):
        if ins.op == 0x33:  # CALLER
            if any(n.op == 0x14 for n in head[k + 1 : k + 6]):
                caller_compare = True
        if ins.op in (0x73, 0x7F):  # PUSH20 / PUSH32 used as an address literal
            if any(n.op == 0x14 for n in head[k + 1 : k + 4]):
                address_literal = True
    return {
        "caller_compare": caller_compare,
        "address_literal": address_literal,
        "sload_early": sum(1 for i in head[:40] if i.op == 0x54),
        "sstore": sum(1 for i in window if i.op == 0x55),
        "external_calls": sum(1 for i in window if i.op in CALL_OPS),
        "logs": sum(1 for i in window if i.op in LOG_RANGE),
        "reverts": sum(1 for i in window if i.op == 0xFD),
    }


def build(instrs: list[disasm.Instruction]) -> list[Entry]:
    hits = selectors.unique(selectors.extract(instrs))
    by_offset = {ins.offset: idx for idx, ins in enumerate(instrs)}
    raw: list[tuple[int, int, int, int | None]] = []  # dest, selector, stub index
    for sel, group in hits.items():
        dest = group[0].dest
        if dest is None or dest not in by_offset:
            continue
        raw.append((dest, sel, by_offset[dest], None))
    raw.sort()

    # Resolve bodies first so each body can be bounded by the next one.
    resolved = []
    for n, (dest, sel, idx, _) in enumerate(raw):
        stub_end = raw[n + 1][2] if n + 1 < len(raw) else len(instrs)
        body = _body_target(instrs, idx, stub_end)
        resolved.append((dest, sel, idx, stub_end, body))

    body_starts = sorted({b for *_, b in resolved if b is not None and b in by_offset})
    entries: list[Entry] = []
    for dest, sel, idx, stub_end, body in resolved:
        if body is None or body not in by_offset:
            body_idx, body_end = idx, stub_end
            body = dest
        else:
            body_idx = by_offset[body]
            later = [b for b in body_starts if b > body]
            body_end = by_offset[later[0]] if later else len(instrs)
        entries.append(
            Entry(
                selector=sel,
                dest=dest,
                body=body,
                stub_window=stub_end - idx,
                body_window=body_end - body_idx,
                **_signals(instrs, body_idx, max(body_end, body_idx + 1)),
            )
        )
    return entries


def table(entries: list[Entry]) -> str:
    lines = [
        "| selector | stub | body | body instrs | guard signals | sload | sstore | calls | logs | revert |",
        "|---|---:|---:|---:|---|---:|---:|---:|---:|---:|",
    ]
    lines.extend(e.row() for e in entries)
    lines.append("")
    lines.append(f"{len(entries)} entries with a resolvable jump target.")
    return "\n".join(lines)
