import unittest
from pathlib import Path

from evmlab import disasm, entries, selectors

HERE = Path(__file__).resolve().parent
CASE = HERE.parent / "cases" / "redbelly" / "artifacts"

# 42-byte runtime code with no metadata; the disassembly in the case notes has 36 instructions.
AMOY = bytes.fromhex(
    "60205f8037346020525f51465f5260405f2054585460205114911416366020141615602157005b5f80fd"
)


class TestDisasm(unittest.TestCase):
    def test_amoy_instruction_count(self):
        instrs = disasm.decode(AMOY)
        self.assertEqual(len(instrs), 36)
        self.assertEqual(instrs[0].name, "PUSH1")
        self.assertEqual(instrs[0].imm, b"\x20")
        self.assertEqual(instrs[-1].name, "REVERT")
        self.assertTrue(any(i.op == 0x5B for i in instrs))

    def test_push_immediate_consumed(self):
        instrs = disasm.decode(bytes.fromhex("7f" + "11" * 32 + "00"))
        self.assertEqual(instrs[0].name, "PUSH32")
        self.assertEqual(len(instrs[0].imm), 32)
        self.assertEqual(instrs[1].name, "STOP")

    def test_truncated_push_is_reported(self):
        instrs = disasm.decode(bytes.fromhex("62aabb"))
        self.assertEqual(instrs[0].name, "PUSH3")
        self.assertEqual(len(instrs[0].imm), 2)  # short, but not invented

    def test_strip_metadata(self):
        payload = bytes.fromhex("a2646970667358221220") + b"\x00" * 32
        code = b"\x60\x00\x60\x00" + payload + len(payload).to_bytes(2, "big")
        body, meta = disasm.strip_metadata(code)
        self.assertEqual(body, b"\x60\x00\x60\x00")
        self.assertIsNotNone(meta)
        self.assertEqual(meta.metadata_bytes, len(payload) + 2)

    def test_no_false_metadata_strip(self):
        body, meta = disasm.strip_metadata(AMOY)
        self.assertEqual(body, AMOY)
        self.assertIsNone(meta)


class TestSelectors(unittest.TestCase):
    def test_solc_shape(self):
        code = bytes.fromhex("63aabbccdd146010 57".replace(" ", ""))
        hits = selectors.extract(disasm.decode(code))
        self.assertEqual([h.hex for h in hits], ["0xaabbccdd"])

    def test_vyper_shape(self):
        code = bytes.fromhex("806311223344146020 57".replace(" ", ""))
        hits = selectors.extract(disasm.decode(code))
        self.assertEqual([h.hex for h in hits], ["0x11223344"])

    def test_lookahead_stops_at_terminator(self):
        # PUSH4, STOP, EQ, JUMPI: the block ends before the comparison, so no hit.
        code = bytes.fromhex("63aabbccdd00146010 57".replace(" ", ""))
        self.assertEqual(selectors.extract(disasm.decode(code)), [])

    def test_dedup(self):
        one = "63aabbccdd14601057"
        code = bytes.fromhex(one + one)
        hits = selectors.extract(disasm.decode(code))
        self.assertEqual(len(hits), 2)
        self.assertEqual(len(selectors.unique(hits)), 1)


class TestSample(unittest.TestCase):
    """The committed sample: samples/Dispatcher.sol compiled to hex text in samples/Dispatcher.bin."""

    SAMPLE = HERE.parent / "samples" / "Dispatcher.bin"

    EXPECTED = {
        "0x18178358",  # poke()
        "0x3fa4f245",  # value()
        "0x55241077",  # setValue(uint256)
        "0x8da5cb5b",  # owner()
        "0xd63a8e11",  # allowed(address)
        "0xff9913e8",  # allow(address)
    }

    def _table(self):
        code = disasm.load_code(self.SAMPLE)
        body, _ = disasm.strip_metadata(code)
        return {f"0x{e.selector:08x}": e for e in entries.build(disasm.decode(body))}

    def test_sample_is_hex_text_and_decodes(self):
        raw = self.SAMPLE.read_bytes()
        self.assertTrue(raw[:1].decode("ascii").isalnum(), "sample should be committed as hex")
        code = disasm.load_code(self.SAMPLE)
        self.assertEqual(len(code), 615)
        self.assertIsNotNone(disasm.strip_metadata(code)[1])

    def test_every_selector_is_recovered(self):
        code = disasm.load_code(self.SAMPLE)
        body, _ = disasm.strip_metadata(code)
        found = {f"0x{sel:08x}" for sel in selectors.unique(selectors.extract(disasm.decode(body)))}
        self.assertEqual(found, self.EXPECTED)

    def test_guards_land_on_the_right_entries(self):
        table = self._table()
        self.assertTrue(table["0x55241077"].caller_compare, "setValue should look guarded")
        self.assertTrue(table["0xff9913e8"].caller_compare, "allow should look guarded")
        self.assertFalse(table["0x18178358"].caller_compare, "poke is unguarded")


class TestEntries(unittest.TestCase):
    def test_target_and_body(self):
        # PUSH4 aabbccdd EQ PUSH2 0x0010 JUMPI, padding, then JUMPDEST SSTORE at 0x10
        code = bytes.fromhex("63aabbccdd1461001057" + "00" * 6 + "5b55")
        found = entries.build(disasm.decode(code))
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0].dest, 0x10)
        self.assertEqual(found[0].selector, 0xAABBCCDD)
        self.assertEqual(found[0].sstore, 1)
        self.assertFalse(found[0].caller_compare)

    def test_caller_guard_signal(self):
        # dispatch to 0x0b, then JUMPDEST CALLER PUSH20 <addr> EQ PUSH2 ... JUMPI in the body
        code = (
            bytes.fromhex("63aabbccdd1461000b57" + "00" + "5b" + "33" + "73" + "11" * 20)
            + bytes.fromhex("1461001157" + "00")
        )
        found = entries.build(disasm.decode(code))
        self.assertEqual(len(found), 1)
        self.assertTrue(found[0].caller_compare)
        self.assertTrue(found[0].address_literal)


if __name__ == "__main__":
    unittest.main()
