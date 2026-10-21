"""Cycle-count regression for the documented core configurations.

Offset 0 is the clock in which the command handshake happens.  "cycles" is
the offset of the clock in which done_o is high, the convention used by
tb_weight_file and the handoff-study traffic bench.  Source and sink are
always ready (or the sink follows the stated pattern), the decryption tag is
offered from the first clock after the command, and every transaction is
checked against the reference model.  Unknown configurations are measured and
logged but not asserted.
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
from ascon_ref import encrypt  # noqa: E402

CONFIG = (int(os.getenv("ROUNDS_PER_CYCLE", "1")), os.getenv("BUFFERING", "0") == "1",
          os.getenv("FOLDED", "0") == "1")
# (ad bytes, payload bytes, sink stall period) -> (cycles, first output offset,
# last output offset, median output interval).  Measured in GHDL; the u1, u3
# and u3-buffered values equal the handoff-study baseline evidence.
EXPECTED = {
    (1, False, False): {(0, 0, 0): (34, None, None, None), (0, 1024, 0): (801, 17, 773, 12),
                        (27, 1024, 0): (822, 38, 794, 12), (0, 1000, 0): (779, 17, 761, 12)},
    (3, False, False): {(0, 0, 0): (18, None, None, None), (0, 1024, 0): (465, 9, 450, 7),
                        (27, 1024, 0): (476, 20, 461, 7), (0, 1000, 0): (453, 9, 443, 7)},
    (3, True, False): {(0, 0, 0): (18, None, None, None), (0, 1024, 0): (401, 10, 388, 6),
                       (27, 1024, 0): (412, 21, 399, 6), (0, 1000, 0): (391, 10, 382, 6),
                       (0, 1024, 2): (401, 11, 389, 6)},
    (3, True, True): {(0, 0, 0): (13, None, None, None), (0, 1024, 0): (205, 6, 195, 3),
                      (27, 1024, 0): (211, 12, 201, 3), (0, 1000, 0): (199, 6, 192, 3),
                      (0, 1024, 2): (205, 7, 195, 2)},
}


def beats(ad, data):
    def phase(kind, payload):
        chunks = [payload[i:i + 16] for i in range(0, len(payload), 16)] or [b""]
        return [(kind, int.from_bytes(c, "little"), (1 << len(c)) - 1, int(i == len(chunks) - 1))
                for i, c in enumerate(chunks)]
    return phase(0, ad) + phase(1, data)


async def measure(dut, decrypt_mode, key, nonce, ad, data, tag, stall_period):
    while not int(dut.cmd_ready_o.value):
        await RisingEdge(dut.clk_i)
    bs = beats(ad, data)
    sent, out, outs, tag_done, accepted = 0, bytearray(), [], False, False
    got_tag = commit = None
    for t in range(100000):
        await FallingEdge(dut.clk_i)
        dut.cmd_valid_i.value = int(not accepted)
        dut.cmd_decrypt_i.value = int(decrypt_mode)
        dut.key_i.value = int.from_bytes(key, "little")
        dut.nonce_i.value = int.from_bytes(nonce, "little")
        offer = accepted and sent < len(bs)
        dut.in_valid_i.value = int(offer)
        if offer:
            kind, x, keep, last = bs[sent]
            dut.in_kind_i.value, dut.in_data_i.value = kind, x
            dut.in_keep_i.value, dut.in_last_i.value = keep, last
        ready = int(stall_period == 0 or t % stall_period != 0)
        dut.out_ready_i.value = ready
        dut.tag_out_ready_i.value = int(not tag_done)
        dut.tag_in_valid_i.value = int(decrypt_mode and accepted and not tag_done)
        dut.tag_in_i.value = int.from_bytes(tag, "little")
        await Timer(1, unit="ns")
        if int(dut.done_o.value):
            dut.in_valid_i.value = 0
            dut.tag_in_valid_i.value = 0
            dut.cmd_valid_i.value = 0
            return t, outs, bytes(out), got_tag, commit
        if not accepted:
            assert t == 0 and int(dut.cmd_ready_o.value)
            accepted = True
        elif offer and int(dut.in_ready_o.value):
            sent += 1
        if int(dut.out_valid_o.value) and ready:
            keep = int(dut.out_keep_o.value)
            out += int(dut.out_data_o.value).to_bytes(16, "little")[:keep.bit_count()]
            outs.append(t)
        if int(dut.tag_out_valid_o.value) and not tag_done:
            got_tag, tag_done = int(dut.tag_out_o.value).to_bytes(16, "little"), True
        if decrypt_mode and accepted and not tag_done and int(dut.tag_in_ready_o.value):
            tag_done = True
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
        if int(dut.commit_o.value):
            commit = True
        if int(dut.discard_o.value) or int(dut.error_o.value):
            commit = False
    raise AssertionError("timeout")


@cocotb.test()
async def cycle_counts_match_documented_values(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    dut.cmd_valid_i.value = 0
    dut.in_valid_i.value = 0
    dut.tag_in_valid_i.value = 0
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    await RisingEdge(dut.clk_i)
    rng = random.Random(0xC1C1E5)
    table = EXPECTED.get(CONFIG)
    if table is None:
        dut._log.warning("no expected cycle table for configuration %s; measuring only", CONFIG)
    cases = sorted(table) if table else [(0, 0, 0), (0, 1024, 0), (27, 1024, 0), (0, 1000, 0)]
    nonce_base = 0x4359434C45000000
    for index, (ad_len, pt_len, stall) in enumerate(cases):
        key, ad, pt = rng.randbytes(16), rng.randbytes(ad_len), rng.randbytes(pt_len)
        nonce = (nonce_base + index).to_bytes(16, "little")
        ct, tag = encrypt(key, nonce, ad, pt)
        for decrypt_mode, data in ((False, pt), (True, ct)):
            cycles, outs, got, got_tag, commit = await measure(dut, decrypt_mode, key, nonce, ad, data, tag, stall)
            if decrypt_mode:
                assert got == pt and commit is True
            else:
                assert got == ct and got_tag == tag
            intervals = sorted(b - a for a, b in zip(outs, outs[1:]))
            median = intervals[len(intervals) // 2] if intervals else None
            measured = (cycles, outs[0] if outs else None, outs[-1] if outs else None, median)
            dut._log.info("config=%s ad=%d pt=%d sink_stall_period=%d %s: cycles=%d first_out=%s last_out=%s "
                          "median_interval=%s", CONFIG, ad_len, pt_len, stall,
                          "decrypt" if decrypt_mode else "encrypt", *measured)
            if table:
                assert measured == table[(ad_len, pt_len, stall)], (
                    f"cycle regression for {CONFIG} {(ad_len, pt_len, stall)}: expected "
                    f"{table[(ad_len, pt_len, stall)]}, measured {measured}")
