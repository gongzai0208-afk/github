#!/usr/bin/env python3
"""Verify the Sepolia deployment on Etherscan through the v2 API.

Why not `forge verify-contract`: on some Windows setups forge's etherscan path fails before it
reaches the network (svm/user-data directory, `os error 5`), and it hides which step failed. This
script builds the standard-json input itself from `out/build-info`, so the compiler settings are the
ones the contracts were actually built with, and every error is printed verbatim.

    export ETHERSCAN_API_KEY=...        # or put it in .env (gitignored)
    python scripts/verify_sepolia.py

Run `forge build --build-info` first if `out/build-info` is missing or stale.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
API = "https://api.etherscan.io/v2/api"
CHAIN_ID = "11155111"

DEPLOYER = "0x37e6af63B03525e9140bdc09679EaB4EB2ab5a73"
ZERO = "0x0000000000000000000000000000000000000000"

TUSD = "0x535C69CC15541F87a0B5e0496F863A6F7B3869b8"
TWETH = "0x745A7e61745A62398F9DeA155feD14483938f1eC"
FEED = "0x88B071954C869311BA674F6ea876870Ac84a5949"
ORACLE = "0xE567dB9926b81E486edF81767AbD19F79CB58d2A"
MODEL = "0x45894fefCf1e9f152ff21209522F7E4849874270"
TIMELOCK = "0x766f66E14cc918f67508Bd22Fe8b78B1b8b6b2a4"
POOL = "0x678377b69DbC206F30D40Fba48B21006c750AA35"

CONTRACTS = [
    {
        "name": "tUSD",
        "address": TUSD,
        "source": "test/mocks/MockERC20.sol",
        "contract": "MockERC20",
        "sig": "constructor(string,string,uint8)",
        "args": ["Test USD", "tUSD", "18"],
    },
    {
        "name": "tWETH",
        "address": TWETH,
        "source": "test/mocks/MockERC20.sol",
        "contract": "MockERC20",
        "sig": "constructor(string,string,uint8)",
        "args": ["Test WETH", "tWETH", "18"],
    },
    {
        "name": "MockFeed",
        "address": FEED,
        "source": "test/mocks/MockFeeds.sol",
        "contract": "MockFeed",
        "sig": None,
        "args": [],
    },
    {
        "name": "TwapOracle",
        "address": ORACLE,
        "source": "src/TwapOracle.sol",
        "contract": "TwapOracle",
        "sig": "constructor(address,address,address,address,uint256,uint256,uint256,uint256,uint256)",
        # owner, feeder, feed, sequencer (none), window 60s, heartbeat 1h, maxAge 1h,
        # maxDeviation 5%, sequencer grace 30min
        "args": [DEPLOYER, DEPLOYER, FEED, ZERO, "60", "3600", "3600", "50000000000000000", "1800"],
    },
    {
        "name": "InterestModel",
        "address": MODEL,
        "source": "src/InterestModel.sol",
        "contract": "InterestModel",
        "sig": "constructor(uint256,uint256,uint256,uint256)",
        "args": ["0", "50000000000000000", "500000000000000000", "800000000000000000"],
    },
    {
        "name": "Timelock",
        "address": TIMELOCK,
        "source": "src/Timelock.sol",
        "contract": "Timelock",
        "sig": "constructor(address,uint256)",
        "args": [DEPLOYER, "86400"],
    },
    {
        "name": "LendingPool",
        "address": POOL,
        "source": "src/LendingPool.sol",
        "contract": "LendingPool",
        "sig": "constructor(address,address,address,address,address)",
        "args": [TUSD, TWETH, ORACLE, MODEL, TIMELOCK],
    },
]

IMPORT_RE = re.compile(r"""import\s+(?:[^;"']*?\sfrom\s+)?["']([^"']+)["']""")


def resolve_key(cli_key: str | None) -> str | None:
    if cli_key:
        return cli_key
    env_key = os.environ.get("ETHERSCAN_API_KEY", "").strip()
    if env_key:
        return env_key
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            match = re.match(r"\s*ETHERSCAN_API_KEY\s*=\s*(.+)", line)
            if match:
                return match.group(1).strip().strip('"').strip("'")
    return None


def load_build_info() -> dict:
    files = sorted((ROOT / "out" / "build-info").glob("*.json"), key=lambda p: p.stat().st_size)
    if not files:
        raise SystemExit("out/build-info is empty: run `forge build --build-info` first")
    with files[-1].open(encoding="utf-8") as handle:
        data = json.load(handle)
    if "input" not in data:
        raise SystemExit("build-info has no `input`: rerun `forge build --build-info`")
    return data


def normalize_import(current: str, raw: str, remappings: list[str]) -> str:
    for mapping in remappings:
        prefix, _, target = mapping.partition("=")
        if prefix and raw.startswith(prefix):
            return target + raw[len(prefix) :]
    if raw.startswith("."):
        parts = (os.path.dirname(current) + "/" + raw).split("/")
        out: list[str] = []
        for part in parts:
            if part in ("", "."):
                continue
            if part == "..":
                if out:
                    out.pop()
            else:
                out.append(part)
        return "/".join(out)
    return raw.lstrip("/")


def closure(build: dict, entry: str) -> dict:
    sources = build["input"]["sources"]
    if entry not in sources:
        raise SystemExit(f"`{entry}` is not in the build-info sources")
    remappings = build["input"]["settings"].get("remappings") or []

    seen: set[str] = set()
    queue = [entry]
    while queue:
        path = queue.pop()
        if path in seen:
            continue
        if path not in sources:
            raise SystemExit(f"missing source `{path}` while walking imports")
        seen.add(path)
        for raw in IMPORT_RE.findall(sources[path]["content"]):
            target = normalize_import(path, raw, remappings)
            if target not in seen:
                queue.append(target)
    return {path: {"content": sources[path]["content"]} for path in sorted(seen)}


def compiler_version(build: dict, solc: str | None) -> str:
    long_version = build.get("solcLongVersion") or build.get("solcVersion") or "0.8.25"
    if "+commit." in long_version:
        return "v" + long_version.split(".")[0] + "." + long_version.split(".")[1] + "+commit." + long_version.split("+commit.")[1]
    binary = solc or "solc"
    try:
        out = subprocess.run([binary, "--version"], capture_output=True, text=True, encoding="utf-8").stdout
        match = re.search(r"Version:\s*(\d+\.\d+\.\d+)\+commit\.([0-9a-f]+)", out)
        if match:
            return f"v{match.group(1)}+commit.{match.group(2)}"
    except OSError:
        pass
    # solc 0.8.25's canonical commit; the only version this deployment uses.
    if long_version.startswith("0.8.25"):
        return "v0.8.25+commit.b61c2a91"
    raise SystemExit(f"cannot determine the commit hash for solc {long_version}; pass --solc")


def encode_args(cast: str, contract: dict) -> str | None:
    if not contract["sig"]:
        return None
    result = subprocess.run(
        [cast, "abi-encode", contract["sig"], *contract["args"]],
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    )
    encoded = result.stdout.strip()
    if result.returncode != 0 or not encoded.startswith("0x"):
        raise SystemExit(f"abi-encode failed for {contract['name']}: {result.stderr.strip()}")
    return encoded[2:]


def post(payload: dict) -> dict:
    body = urllib.parse.urlencode(payload).encode()
    request = urllib.request.Request(f"{API}?chainid={CHAIN_ID}", data=body)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as error:
        return {"status": "0", "message": "HTTPError", "result": error.read().decode(errors="replace")}
    except urllib.error.URLError as error:
        return {"status": "0", "message": "URLError", "result": str(error)}


def is_verified(address: str, key: str) -> bool:
    url = (
        f"{API}?chainid={CHAIN_ID}&module=contract&action=getsourcecode"
        f"&address={address}&apikey={key}"
    )
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            data = json.loads(response.read().decode())
        return bool(data["result"][0].get("SourceCode"))
    except Exception:  # noqa: BLE001 - a failed status probe is not a verification failure
        return False


def wait_for(key: str, guid: str, timeout: float = 600.0) -> tuple[bool, str]:
    """Etherscan queues submissions; a pending result is not a failure, only a slow one."""
    deadline = time.time() + timeout
    last = ""
    while time.time() < deadline:
        time.sleep(10)
        reply = post({"module": "contract", "action": "checkverifystatus", "guid": guid, "apikey": key})
        last = str(reply.get("result", ""))
        if last.startswith("Pass"):
            return True, last
        if last.startswith("Fail") or "already verified" in last.lower():
            return last.startswith("Fail") is False, last
        if "Pending" not in last and "Queue" not in last and "In progress" not in last:
            return False, last
    return False, f"timeout, last result: {last}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--api-key")
    parser.add_argument("--cast", default="cast")
    parser.add_argument("--solc", default=os.environ.get("SOLC"))
    parser.add_argument("--only", help="verify a single contract by name")
    parser.add_argument("--status", action="store_true", help="only report which contracts are verified")
    args = parser.parse_args()

    key = resolve_key(args.api_key)
    if not key:
        print("no API key: set ETHERSCAN_API_KEY, pass --api-key, or add it to .env", file=sys.stderr)
        return 2

    if args.status:
        for contract in CONTRACTS:
            mark = "verified" if is_verified(contract["address"], key) else "-"
            print(f"  {contract['name']:<14} {contract['address']}  {mark}")
        return 0

    build = load_build_info()
    version = compiler_version(build, args.solc)
    print(f"solc {version}, build-info {build.get('id', '?')}")

    todo = CONTRACTS
    if args.only:
        todo = [c for c in CONTRACTS if c["name"].lower() == args.only.lower()]
        if not todo:
            print(f"unknown contract {args.only!r}", file=sys.stderr)
            return 2

    ok: list[str] = []
    failed: list[str] = []
    for contract in todo:
        print(f"\n==> {contract['name']}  {contract['address']}", flush=True)
        settings = dict(build["input"]["settings"])
        settings.pop("outputSelection", None)
        standard = {
            "language": "Solidity",
            "sources": closure(build, contract["source"]),
            "settings": settings,
        }
        payload = {
            "module": "contract",
            "action": "verifysourcecode",
            "apikey": key,
            "codeformat": "solidity-standard-json-input",
            "sourceCode": json.dumps(standard),
            "contractaddress": contract["address"],
            "contractname": f"{contract['source']}:{contract['contract']}",
            "compilerversion": version,
        }
        encoded = encode_args(args.cast, contract)
        if encoded:
            payload["constructorArguements"] = encoded

        reply = post(payload)
        result = str(reply.get("result", ""))
        if reply.get("status") != "1":
            if "already verified" in result.lower():
                print("    already verified")
                ok.append(contract["name"])
            else:
                print(f"    submit rejected: {reply.get('message')}: {result}")
                failed.append(contract["name"])
            continue

        verified, message = wait_for(key, result)
        if not verified and is_verified(contract["address"], key):
            verified, message = True, "verified (queue outlived the poll window)"
        print(f"    {message}")
        (ok if verified else failed).append(contract["name"])

    print("\n=== summary ===")
    for contract in todo:
        mark = "ok" if contract["name"] in ok else "FAILED"
        print(f"  {contract['name']:<14} {contract['address']}  {mark}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
