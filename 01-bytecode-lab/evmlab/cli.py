"""Command line entry point: python -m evmlab <command>."""

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

from . import disasm, entries, report, selectors


def cmd_disasm(args: argparse.Namespace) -> int:
    code = disasm.load_code(Path(args.file))
    body, meta = disasm.strip_metadata(code)
    instrs = disasm.decode(body, limit=args.limit)
    if meta:
        print(f"; metadata stripped: {meta.metadata_bytes} bytes at 0x{meta.payload_offset:x}")
    for ins in instrs:
        print(ins.text())
    if args.limit and args.limit < len(disasm.decode(body)):
        print(f"; truncated at {args.limit} instructions")
    return 0


def cmd_selectors(args: argparse.Namespace) -> int:
    code = disasm.load_code(Path(args.file))
    body, _ = disasm.strip_metadata(code)
    hits = selectors.extract(disasm.decode(body))
    if args.json:
        print(json.dumps([h.hex for h in hits], indent=2))
        return 0
    for hit in hits:
        print(f"{hit.hex}  push@0x{hit.push_offset:04x}  jumpi@0x{hit.jumpi_offset:04x}")
    print(f"; {len(selectors.unique(hits))} distinct")
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    payload = report.analyse_file(Path(args.file))
    if args.json:
        print(json.dumps(payload, indent=2))
        return 0
    print(f"file        {payload['file']}")
    print(f"sha256      {payload['sha256']}")
    print(f"size        {payload['size']} bytes ({payload['metadata_bytes']} metadata)")
    print(f"instrs      {payload['instructions']} ({payload['jumpdests']} JUMPDEST)")
    print(f"selectors   {payload['selector_count']}")
    for sel in payload["selectors"]:
        print(f"  {sel['selector']}  x{sel['occurrences']}")
    return 0


def cmd_entries(args: argparse.Namespace) -> int:
    code = disasm.load_code(Path(args.file))
    body, _ = disasm.strip_metadata(code)
    table = entries.build(disasm.decode(body))
    if args.json:
        print(json.dumps([asdict(e) for e in table], indent=2))
        return 0
    print(entries.table(table))
    return 0


def cmd_scan(args: argparse.Namespace) -> int:
    scan = report.scan_dir(Path(args.directory))
    if args.out:
        report.write_json(scan, Path(args.out))
    print(report.markdown_table(scan))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="evmlab")
    sub = p.add_subparsers(dest="command", required=True)

    d = sub.add_parser("disasm", help="decode runtime bytecode")
    d.add_argument("file")
    d.add_argument("--limit", type=int, default=None)
    d.set_defaults(func=cmd_disasm)

    s = sub.add_parser("selectors", help="recover dispatcher selectors")
    s.add_argument("file")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_selectors)

    r = sub.add_parser("report", help="one-file summary")
    r.add_argument("file")
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=cmd_report)

    sc = sub.add_parser("scan", help="summarise a directory of .bin files")
    sc.add_argument("directory")
    sc.add_argument("--out", default=None)
    sc.set_defaults(func=cmd_scan)

    en = sub.add_parser("entries", help="entry table: selector, target, guard signals")
    en.add_argument("file")
    en.add_argument("--json", action="store_true")
    en.set_defaults(func=cmd_entries)

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
