"""Show the instruction window around PUSH4s that do not produce a selector hit."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from evmlab import disasm, selectors  # noqa: E402

code = Path(sys.argv[1]).read_bytes()
body, _ = disasm.strip_metadata(code)
instrs = disasm.decode(body)

hits = {h.push_offset for h in selectors.extract(instrs)}
shown = 0
for i, ins in enumerate(instrs):
    if ins.op != 0x63 or ins.offset in hits:
        continue
    window = instrs[i : i + 10]
    if not any(w.op == 0x14 for w in window):
        continue
    print(f"--- PUSH4 0x{ins.imm.hex()} at {ins.offset:#06x}")
    for w in window:
        print(f"    {w.text()}")
    shown += 1
    if shown >= 6:
        break
