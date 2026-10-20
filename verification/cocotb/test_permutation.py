"""Independent checks at every registered group of permutation rounds."""

import sys
import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verification" / "model"))
from ascon_ref import permutation_trace  # noqa: E402


def pack(words):
    value = 0
    for index, word in enumerate(words):
        value |= word << (64 * index)
    return value


async def run_permutation(dut, words, rounds):
    factor = int(os.environ.get("ROUNDS_PER_CYCLE", "1"))
    dut.state_i.value = pack(words)
    dut.rounds_i.value = rounds
    dut.start_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    dut.start_i.value = 0
    observed = []
    cycles = (rounds + factor - 1) // factor
    for round_index in range(cycles):
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
        observed.append(int(dut.state_o.value))
        if round_index < cycles - 1:
            assert not int(dut.done_o.value), "permutation finished before its final round"
    assert int(dut.done_o.value), "permutation did not finish on its final round"
    return observed


@cocotb.test()
async def p12_and_p8_match_reference(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    dut.rst_i.value = 1
    dut.start_i.value = 0
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    await RisingEdge(dut.clk_i)

    states = [
        [0, 0, 0, 0, 0],
        [0, 1, 2, 3, 4],
        [
            0x0123456789ABCDEF,
            0xFEDCBA9876543210,
            0x0F1E2D3C4B5A6978,
            0x8877665544332211,
            0xA5A5A5A55A5A5A5A,
        ],
    ]
    rng = random.Random(20261020)
    states += [[rng.getrandbits(64) for _ in range(5)] for _ in range(30)]
    for words in states:
        for rounds in range(1, 13):
            factor = int(os.environ.get("ROUNDS_PER_CYCLE", "1"))
            trace = permutation_trace(words, rounds)
            expected = [pack(trace[min(i + factor, rounds) - 1]) for i in range(0, rounds, factor)]
            observed = await run_permutation(dut, words, rounds)
            for round_index, (actual_state, expected_state) in enumerate(
                zip(observed, expected, strict=True), start=1
            ):
                assert actual_state == expected_state, (
                    f"p{rounds} round {round_index} mismatch: "
                    f"expected {expected_state:080x}, got {actual_state:080x}"
                )
