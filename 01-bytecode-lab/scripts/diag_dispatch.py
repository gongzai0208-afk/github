"""Diagnostic: how far is each PUSH4 from its EQ, and why misses happen."""

import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from evmlab import disasm, selectors  # noqa: E402

code = Path(sys.argv[1]).read_bytes()
body, _ = disasm.strip_metadata(code)
instrs = disasm.decode(body)

push4 = [i for i, ins in enumerate(instrs) if ins.op == 0x63]
eqs = {i for i, ins in enumerate(instrs) if ins.op == 0x14}

dist = Counter()
for i in push4:
    for j in range(i + 1, min(i + 24, len(instrs))):
        if j in eqs:
            dist[j - i] += 1
            break
        if instrs[j].op in (0x00, 0x56, 0x5B, 0xF3, 0xFD, 0xFE):
            dist["terminator"] += 1
            break
    else:
        dist["none"] = dist.get("none", 0) + 1

print("push4:", len(push4), "eq:", len(eqs))
for k, v in sorted(dist.items(), key=lambda kv: str(kv[0])):
    print(f"  distance {k}: {v}")

print("distinct push4:", len({int.from_bytes(i.imm, "big") for i in instrs if i.op == 0x63}))
for la in (8, 12, 16, 20):
    hits = selectors.extract(instrs, lookahead=la)
    print(f"lookahead {la}: {len(hits)} hits, {len(selectors.unique(hits))} distinct")
