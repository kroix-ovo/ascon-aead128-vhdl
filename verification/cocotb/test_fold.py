"""Intermediate-state checks for the folded-absorb core (G_FOLDED_ABSORB, GHDL only).

Every clock, the test samples the single internal state register and the
registered round constants of ascon_aead128_fold.  The constants say which
group the clock runs, so each registered group can be checked against the
independent Python round function:

* a 3-round group must equal three reference rounds with the expected
  constants (p12: F0/E1/D2, C3/B4/A5, 96/87/78, 69/5A/4B; p8: B4/A5/96,
  87/78/69),
* the 2-round p8 tail (5A, 4B) must equal two reference rounds, changed only
  in the rate (folded absorb, padding), in words 2-3 (finalization key) and
  in the domain-separation bit,
* groups must appear in order: p12 = four groups, p8 = two groups plus tail.

Whole-message results are checked against the reference model as well.
"""

import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verification" / "model"))
from ascon_ref import IV, RC, _round, decrypt, encrypt  # noqa: E402

MASK64 = (1 << 64) - 1
P12 = [RC[0], RC[3], RC[6], RC[9]]
P8 = [RC[4], RC[7]]
TAIL = RC[10]
# Bits a tail clock may change after two rounds: rate (absorb, pad),
# words 2 and 3 (key before finalization) and the DSEP bit 319.
TAIL_MASK = ((1 << 128) - 1) | (((1 << 128) - 1) << 128) | (1 << 319)


def words(value):
    return [(value >> (64 * i)) & MASK64 for i in range(5)]


def pack(ws):
    return sum(w << (64 * i) for i, w in enumerate(ws))


def rounds(value, first_constant_index, count):
    s = words(value)
    for i in range(count):
        _round(s, RC[first_constant_index + i])
    return pack(s)


class Monitor:
    def __init__(self, dut):
        core = dut.fold_g.fold_u
        self.s = core.s_reg
        self.rc = (core.rc0, core.rc1, core.rc2)
        self.groups = {"r3": 0, "tail": 0, "p12": 0, "p8": 0}
        self.expect = None   # next group constant within a permutation
        self.prev = None

    def sample(self):
        return int(self.s.value), tuple(int(r.value) for r in self.rc)

    def check(self, before, after):
        state, rc = before
        new_state = after[0]
        if rc[0] == 0:
            assert self.expect is None, f"permutation interrupted, expected group {self.expect:02X}"
            return
        if self.expect is not None:
            assert rc[0] == self.expect, f"group order: expected {self.expect:02X}, got {rc[0]:02X}"
        if rc[0] == TAIL:
            assert rc[1] == RC[11]
            delta = new_state ^ rounds(state, 10, 2)
            assert delta & ~TAIL_MASK == 0, f"tail changed capacity bits {delta & ~TAIL_MASK:080x}"
            self.groups["tail"] += 1
            self.groups["p8"] += 1
            self.expect = None
            return
        index = RC.index(rc[0])
        assert rc[1] == RC[index + 1] and rc[2] == RC[index + 2]
        assert new_state == rounds(state, index, 3), (
            f"3-round group {rc[0]:02X} mismatch: expected {rounds(state, index, 3):080x}, got {new_state:080x}")
        self.groups["r3"] += 1
        if rc[0] in P12:
            position = P12.index(rc[0])
            if position == 3:
                self.groups["p12"] += 1
                self.expect = None
            else:
                self.expect = P12[position + 1]
        else:
            self.expect = P8[1] if rc[0] == P8[0] else TAIL


async def run_message(dut, mon, key, nonce, ad, data, decrypt_mode, tag, rng, stall):
    def phase(kind, payload):
        chunks = [payload[i:i + 16] for i in range(0, len(payload), 16)] or [b""]
        return [(kind, int.from_bytes(c, "little"), (1 << len(c)) - 1, int(i == len(chunks) - 1))
                for i, c in enumerate(chunks)]
    beats = phase(0, ad) + phase(1, data)
    sent, out, command_sent, tag_done = 0, bytearray(), False, False
    got_tag, auth_ok, commit, discard = None, None, 0, 0
    pending = False
    for _ in range(20000):
        await FallingEdge(dut.clk_i)
        offer = command_sent and sent < len(beats) and (pending or not stall or rng.random() < 0.6)
        pending = offer
        dut.cmd_valid_i.value = int(not command_sent)
        dut.cmd_decrypt_i.value = int(decrypt_mode)
        dut.key_i.value = int.from_bytes(key, "little")
        dut.nonce_i.value = int.from_bytes(nonce, "little")
        dut.in_valid_i.value = int(offer)
        if offer:
            kind, x, keep, last = beats[sent]
            dut.in_kind_i.value = kind
            dut.in_data_i.value = x
            dut.in_keep_i.value = keep
            dut.in_last_i.value = last
        ready = int(not stall or rng.random() < 0.5)
        dut.out_ready_i.value = ready
        dut.tag_out_ready_i.value = ready
        dut.tag_in_valid_i.value = int(decrypt_mode and command_sent and not tag_done)
        dut.tag_in_i.value = int.from_bytes(tag, "little")
        await Timer(1, unit="ns")
        before = mon.sample()
        hs_cmd = not command_sent and int(dut.cmd_ready_o.value)
        hs_in = offer and int(dut.in_ready_o.value)
        if int(dut.out_valid_o.value) and ready:
            keep = int(dut.out_keep_o.value)
            out += int(dut.out_data_o.value).to_bytes(16, "little")[:keep.bit_count()]
        if int(dut.tag_out_valid_o.value) and ready:
            got_tag = int(dut.tag_out_o.value).to_bytes(16, "little")
            tag_done = True
        if decrypt_mode and command_sent and not tag_done and int(dut.tag_in_ready_o.value):
            tag_done = True
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
        after = mon.sample()
        mon.check(before, after)
        if hs_cmd:
            command_sent = True
            k0, k1 = (int.from_bytes(key[i:i + 8], "little") for i in (0, 8))
            n0, n1 = (int.from_bytes(nonce[i:i + 8], "little") for i in (0, 8))
            assert after[0] == pack([IV, k0, k1, n0, n1]), "initial state load mismatch"
        if hs_in:
            sent += 1
            pending = False
        if int(dut.auth_valid_o.value):
            auth_ok = bool(int(dut.auth_ok_o.value))
        commit += int(dut.commit_o.value)
        discard += int(dut.discard_o.value)
        assert not int(dut.error_o.value)
        if int(dut.done_o.value):
            dut.in_valid_i.value = 0
            dut.tag_in_valid_i.value = 0
            return bytes(out), got_tag, auth_ok, commit, discard
    raise AssertionError("message timeout")


@cocotb.test()
async def fold_groups_match_reference_rounds(dut):
    assert os.getenv("FOLDED", "0") == "1", "run with --folded"
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    dut.cmd_valid_i.value = 0
    dut.in_valid_i.value = 0
    dut.tag_in_valid_i.value = 0
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    mon = Monitor(dut)
    rng = random.Random(0xF01D)
    cases = [(a, p) for a in (0, 1, 15, 16, 17, 32, 33) for p in (0, 1, 15, 16, 17, 32, 48, 63)]
    nonce_counter = 0x464F4C4400000000
    for i, (ad_len, pt_len) in enumerate(cases):
        key = rng.randbytes(16)
        nonce_counter += 1
        nonce = nonce_counter.to_bytes(16, "little")
        ad, pt = rng.randbytes(ad_len), rng.randbytes(pt_len)
        ct, tag = encrypt(key, nonce, ad, pt)
        stall = i % 3 == 2
        got, got_tag, _, _, _ = await run_message(dut, mon, key, nonce, ad, pt, False, b"\0" * 16, rng, stall)
        assert (got, got_tag) == (ct, tag), f"encrypt mismatch ad={ad_len} pt={pt_len}"
        got, _, ok, commit, discard = await run_message(dut, mon, key, nonce, ad, ct, True, tag, rng, stall)
        assert got == pt and ok and commit == 1 and discard == 0
        bad = bytes([tag[0] ^ 0x80]) + tag[1:]
        got, _, ok, commit, discard = await run_message(dut, mon, key, nonce, ad, ct, True, bad, rng, stall)
        assert got == decrypt(key, nonce, ad, ct, bad)[0] and ok is False and commit == 0 and discard == 1
    dut._log.info("checked groups: %s", mon.groups)
    # Three transactions per case, each with two p12 and one p8 per padded
    # AD block (none for empty AD) and per full payload block.
    expected_p8 = 3 * sum((a // 16 + 1 if a else 0) + p // 16 for a, p in cases)
    assert mon.groups["p12"] == 2 * 3 * len(cases)
    assert mon.groups["p8"] == expected_p8 and mon.groups["tail"] == expected_p8
    assert mon.groups["r3"] == 4 * mon.groups["p12"] + 2 * mon.groups["p8"]


@cocotb.test()
async def mid_stream_error_discards_queued_plaintext(dut):
    """A malformed beat behind queued provisional plaintext (two queued output beats,
    sink stalled): nothing escapes after
    the error, discard is raised with it, commit never happens, and the next
    command (accepted in the clock that shows done_o) is clean."""
    assert os.getenv("FOLDED", "0") == "1", "run with --folded"
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    dut.cmd_valid_i.value = 0
    dut.in_valid_i.value = 0
    dut.tag_in_valid_i.value = 0
    dut.out_ready_i.value = 0
    dut.tag_out_ready_i.value = 0
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    key, nonce = bytes(range(16)), (0x4552524F52).to_bytes(16, "little")
    _, tag = encrypt(key, nonce, b"", bytes(64))
    beats = [(0, 0, 0, 1)] + [(1, 0x1111 * (i + 1), 0xFFFF, 0) for i in range(2)] + [(0, 0xBAD, 0xFFFF, 1)]
    sent, accepted, error_seen, discard_seen, commit_seen, valid_after_error = 0, False, False, False, False, 0
    for t in range(200):
        await FallingEdge(dut.clk_i)
        dut.cmd_valid_i.value = int(not accepted)
        dut.cmd_decrypt_i.value = 1
        dut.key_i.value = int.from_bytes(key, "little")
        dut.nonce_i.value = int.from_bytes(nonce, "little")
        dut.tag_in_i.value = int.from_bytes(tag, "little")
        dut.tag_in_valid_i.value = int(accepted)
        offer = accepted and sent < len(beats)
        dut.in_valid_i.value = int(offer)
        if offer:
            kind, x, keep, last = beats[sent]
            dut.in_kind_i.value, dut.in_data_i.value, dut.in_keep_i.value, dut.in_last_i.value = kind, x, keep, last
        dut.out_ready_i.value = 0
        await Timer(1, unit="ns")
        if error_seen and int(dut.out_valid_o.value):
            valid_after_error += 1
        queued_before = int(dut.out_valid_o.value)
        assert not int(dut.tag_in_ready_o.value), "tag accepted while plaintext is queued or after an error"
        hs_cmd = not accepted and int(dut.cmd_ready_o.value)
        hs_in = offer and int(dut.in_ready_o.value)
        done_now = int(dut.done_o.value)
        if done_now:
            assert int(dut.cmd_ready_o.value), "fold core accepts a command in the done clock"
            break
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
        accepted = accepted or bool(hs_cmd)
        sent += int(bool(hs_in))
        if int(dut.error_o.value):
            error_seen = True
            discard_seen = bool(int(dut.discard_o.value))
            assert not int(dut.out_valid_o.value), "queued plaintext still offered after the error"
            assert queued_before, "fixture did not queue plaintext before the malformed beat"
        commit_seen |= bool(int(dut.commit_o.value))
    else:
        raise AssertionError("no done after the malformed beat")
    assert sent == len(beats) and error_seen and discard_seen and not commit_seen and valid_after_error == 0
    dut.in_valid_i.value = 0
    dut.tag_in_valid_i.value = 0
    dut.out_ready_i.value = 1
    dut.tag_out_ready_i.value = 1
    mon = Monitor(dut)
    nonce2 = (0x4552524F53).to_bytes(16, "little")
    got, got_tag, _, _, _ = await run_message(dut, mon, key, nonce2, b"", b"clean", False, b"\0" * 16,
                                              random.Random(1), False)
    assert (got, got_tag) == encrypt(key, nonce2, b"", b"clean")
