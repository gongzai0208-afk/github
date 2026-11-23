"""Reporting helpers: one contract, or a directory of them, to JSON and Markdown."""

import hashlib
import json
from pathlib import Path

from . import disasm, selectors


def analyse_file(path: Path) -> dict:
    code = disasm.load_code(path)
    body, meta = disasm.strip_metadata(code)
    instrs = disasm.decode(body)
    hits = selectors.extract(instrs)
    grouped = selectors.unique(hits)
    # Two different populations matter, and conflating them gives a wrong recall number:
    # `push4_constants` is every distinct 4-byte constant (binary-search pivots, custom-error
    # selectors, literals); `selector_count` is only constants guarded by EQ + JUMPI.
    push4_constants = {
        int.from_bytes(i.imm, "big") for i in instrs if i.op == 0x63 and len(i.imm) == 4
    }
    return {
        "file": path.name,
        "sha256": hashlib.sha256(code).hexdigest(),
        "size": len(code),
        "code_size": len(body),
        "metadata_bytes": meta.metadata_bytes if meta else 0,
        "instructions": len(instrs),
        "jumpdests": sum(1 for i in instrs if i.op == 0x5B),
        "selector_count": len(grouped),
        "push4_constants": len(push4_constants),
        "selectors": [
            {
                "selector": f"0x{sel:08x}",
                "occurrences": len(items),
                "first_push_offset": items[0].push_offset,
            }
            for sel, items in grouped.items()
        ],
        "opcode_histogram": disasm.histogram(instrs),
    }


def scan_dir(directory: Path) -> dict:
    results = [analyse_file(p) for p in sorted(directory.glob("*.bin"))]
    total = sum(r["size"] for r in results)
    all_selectors = {
        s["selector"] for r in results for s in r["selectors"]
    }
    return {
        "directory": str(directory),
        "files": len(results),
        "total_bytes": total,
        "distinct_selectors": len(all_selectors),
        "distinct_push4_constants": sum(r["push4_constants"] for r in results),
        "contracts": results,
    }


def write_json(payload: dict, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def markdown_table(scan: dict) -> str:
    lines = [
        "| contract | bytes | metadata | instrs | push4 consts | eq-guarded |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for r in scan["contracts"]:
        lines.append(
            f"| `{r['file']}` | {r['size']} | {r['metadata_bytes']} | "
            f"{r['instructions']} | {r['push4_constants']} | {r['selector_count']} |"
        )
    lines.append("")
    lines.append(
        f"Total {scan['total_bytes']} bytes across {scan['files']} files; "
        f"{scan['distinct_selectors']} distinct eq-guarded selectors, "
        f"{scan['distinct_push4_constants']} distinct PUSH4 constants (summed per file)."
    )
    return "\n".join(lines)
