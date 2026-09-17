"""Cocotb verification for the streaming Ascon-AEAD128 core."""

import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "verification" / "model"))
from ascon_ref import decrypt, encrypt  # noqa: E402


def lane_int(data: bytes) -> int:
    return int.from_bytes(data.ljust(16, b"\x00"), "little")


async def reset(dut):
    dut.rst_i.value = 1
    dut.cmd_valid_i.value = 0
    dut.in_valid_i.value = 0
    dut.tag_in_valid_i.value = 0
    dut.out_ready_i.value = 1
    dut.tag_out_ready_i.value = 1
    await RisingEdge(dut.clk_i)
    await RisingEdge(dut.clk_i)
    dut.rst_i.value = 0
    await RisingEdge(dut.clk_i)


async def command(dut, decrypt_mode: bool, key: bytes, nonce: bytes):
    while not int(dut.cmd_ready_o.value):
        await RisingEdge(dut.clk_i)
    dut.cmd_decrypt_i.value = int(decrypt_mode)
    dut.key_i.value = int.from_bytes(key, "little")
    dut.nonce_i.value = int.from_bytes(nonce, "little")
    dut.cmd_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    dut.cmd_valid_i.value = 0


async def send_phase(dut, kind: int, data: bytes):
    blocks = [data[i : i + 16] for i in range(0, len(data), 16)]
    if not blocks:
        blocks = [b""]
    for index, block in enumerate(blocks):
        last = index == len(blocks) - 1
        while not int(dut.in_ready_o.value):
            await RisingEdge(dut.clk_i)
        dut.in_kind_i.value = kind
        dut.in_data_i.value = lane_int(block)
        dut.in_keep_i.value = (1 << len(block)) - 1
        dut.in_last_i.value = int(last)
        dut.in_valid_i.value = 1
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
        dut.in_valid_i.value = 0


async def send_raw_beat(dut, kind: int, data: bytes, keep: int, last: bool):
    """Send one deliberately hand-built beat for protocol-error tests."""
    while not int(dut.in_ready_o.value):
        await RisingEdge(dut.clk_i)
    dut.in_kind_i.value = kind
    dut.in_data_i.value = lane_int(data)
    dut.in_keep_i.value = keep
    dut.in_last_i.value = int(last)
    dut.in_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    status = {
        "error": bool(int(dut.error_o.value)),
        "discard": bool(int(dut.discard_o.value)),
    }
    dut.in_valid_i.value = 0
    return status


async def collect_payload(dut, expected_length: int, random_stalls: bool = False) -> bytes:
    result = bytearray()
    rng = random.Random(0xA5C0)
    for _cycle in range(2000):
        if len(result) >= expected_length:
            break
        dut.out_ready_i.value = 0 if random_stalls and rng.randrange(4) == 0 else 1
        # Sample the transfer just before the active edge.  Sampling after the
        # edge can miss a valid pulse because the RTL clears it on that edge.
        await Timer(1, unit="ns")
        if int(dut.out_valid_o.value) and int(dut.out_ready_i.value):
            keep = int(dut.out_keep_o.value)
            count = keep.bit_count()
            result += int(dut.out_data_o.value).to_bytes(16, "little")[:count]
        await RisingEdge(dut.clk_i)
    else:
        raise AssertionError(
            f"payload timeout: received {len(result)} of {expected_length} bytes; "
            f"valid={dut.out_valid_o.value} ready={dut.out_ready_i.value} "
            f"busy={dut.busy_o.value} tag_ready={dut.tag_in_ready_o.value}"
        )
    dut.out_ready_i.value = 1
    return bytes(result)


async def wait_tag(dut) -> bytes:
    for _cycle in range(2000):
        if int(dut.tag_out_valid_o.value):
            break
        await RisingEdge(dut.clk_i)
    else:
        raise AssertionError("tag output timeout")
    tag = int(dut.tag_out_o.value).to_bytes(16, "little")
    await RisingEdge(dut.clk_i)
    return tag


async def encrypt_dut(dut, key: bytes, nonce: bytes, ad: bytes, pt: bytes):
    await command(dut, False, key, nonce)
    await send_phase(dut, 0, ad)
    ct_task = cocotb.start_soon(collect_payload(dut, len(pt), random_stalls=True))
    await send_phase(dut, 1, pt)
    ct = await ct_task
    tag = await wait_tag(dut)
    return ct, tag


async def decrypt_dut(
    dut,
    key: bytes,
    nonce: bytes,
    ad: bytes,
    ct: bytes,
    tag: bytes,
    tag_delay: int = 0,
):
    await command(dut, True, key, nonce)
    await send_phase(dut, 0, ad)
    pt_task = cocotb.start_soon(collect_payload(dut, len(ct), random_stalls=True))
    await send_phase(dut, 1, ct)
    pt = await pt_task
    while not int(dut.tag_in_ready_o.value):
        await RisingEdge(dut.clk_i)
    for _ in range(tag_delay):
        assert int(dut.busy_o.value)
        assert int(dut.tag_in_ready_o.value)
        assert not int(dut.auth_valid_o.value)
        assert not int(dut.done_o.value)
        await RisingEdge(dut.clk_i)
    dut.tag_in_i.value = int.from_bytes(tag, "little")
    dut.tag_in_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    assert int(dut.auth_valid_o.value), "authentication result was not marked valid"
    auth_ok = bool(int(dut.auth_ok_o.value))
    commit = bool(int(dut.commit_o.value))
    discard = bool(int(dut.discard_o.value))
    dut.tag_in_valid_i.value = 0
    return pt, auth_ok, commit, discard


async def assert_clean_empty_transaction(dut, key: bytes, nonce: bytes):
    """Prove that a completed failure did not contaminate the next command."""
    expected_ct, expected_tag = encrypt(key, nonce, b"", b"")
    actual_ct, actual_tag = await encrypt_dut(dut, key, nonce, b"", b"")
    assert actual_ct == expected_ct
    assert actual_tag == expected_tag


def parse_kats(path: Path):
    record = {}
    for line in path.read_text().splitlines() + [""]:
        if not line.strip():
            if record:
                ct_tag = bytes.fromhex(record["CT"])
                yield {
                    "count": int(record["Count"]),
                    "key": bytes.fromhex(record["Key"]),
                    "nonce": bytes.fromhex(record["Nonce"]),
                    "pt": bytes.fromhex(record["PT"]),
                    "ad": bytes.fromhex(record["AD"]),
                    "ct": ct_tag[:-16],
                    "tag": ct_tag[-16:],
                }
                record = {}
        else:
            key, value = line.split(" = ", 1)
            record[key] = value


@cocotb.test()
async def official_and_boundary_vectors(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)

    kat_path = ROOT / "verification" / "vectors" / "LWC_AEAD_KAT_128_128.txt"
    all_kats = list(parse_kats(kat_path))
    requested = os.getenv("KAT_LIMIT")
    if requested:
        all_kats = all_kats[: int(requested)]
    else:
        # Default local run covers every boundary through 33 bytes in each
        # dimension plus selected multi-block cases.  FULL_KAT=1 runs all.
        if os.getenv("FULL_KAT") != "1":
            chosen = []
            lengths = {0, 1, 7, 8, 15, 16, 17, 31, 32, 33}
            for vector in all_kats:
                if len(vector["pt"]) in lengths and len(vector["ad"]) in lengths:
                    chosen.append(vector)
            all_kats = chosen

    for vector in all_kats:
        expected_ct, expected_tag = encrypt(
            vector["key"], vector["nonce"], vector["ad"], vector["pt"]
        )
        assert expected_ct == vector["ct"]
        assert expected_tag == vector["tag"]
        actual_ct, actual_tag = await encrypt_dut(
            dut, vector["key"], vector["nonce"], vector["ad"], vector["pt"]
        )
        assert actual_ct == vector["ct"], f"ciphertext mismatch in KAT {vector['count']}"
        assert actual_tag == vector["tag"], f"tag mismatch in KAT {vector['count']}"

        actual_pt, auth_ok, commit, discard = await decrypt_dut(
            dut, vector["key"], vector["nonce"], vector["ad"], vector["ct"], vector["tag"]
        )
        assert actual_pt == vector["pt"]
        assert auth_ok and commit and not discard


@cocotb.test()
async def corrupted_tag_discards_plaintext(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    ad = b"undergraduate research"
    pt = b"authenticated plaintext must not commit"
    ct, tag = encrypt(key, nonce, ad, pt)
    bad_tag = bytes([tag[0] ^ 1]) + tag[1:]
    actual_pt, auth_ok, commit, discard = await decrypt_dut(
        dut, key, nonce, ad, ct, bad_tag
    )
    assert actual_pt == pt
    assert not auth_ok and not commit and discard
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    assert not int(dut.auth_valid_o.value), "auth_valid_o must be a one-cycle event"
    await assert_clean_empty_transaction(dut, key, nonce)


@cocotb.test()
async def malformed_streams_report_error(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    key = bytes(range(16))
    nonce = bytes(range(16, 32))

    await reset(dut)
    await command(dut, False, key, nonce)
    status = await send_raw_beat(dut, 0, b"bad", 0b0101, True)
    assert status["error"] and not status["discard"]
    await assert_clean_empty_transaction(dut, key, nonce)

    await command(dut, True, key, nonce)
    status = await send_raw_beat(dut, 1, b"payload", 0x7F, True)
    assert status["error"] and status["discard"]
    await assert_clean_empty_transaction(dut, key, nonce)

    await command(dut, False, key, nonce)
    status = await send_raw_beat(dut, 0, b"short", 0x003F, False)
    assert status["error"]
    await assert_clean_empty_transaction(dut, key, nonce)


@cocotb.test()
async def wrong_phase_and_held_extra_beats_are_rejected(dut):
    """Reject AD after the payload phase opens, including a beat held early."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    key = bytes(range(16))
    nonce = bytes(range(16, 32))

    await command(dut, False, key, nonce)
    await send_phase(dut, 0, b"")
    status = await send_raw_beat(dut, 0, b"late AD", 0x007F, True)
    assert status["error"]
    await assert_clean_empty_transaction(dut, key, nonce)

    # Accept a final full AD block, then hold another AD beat while both p8
    # operations run.  The held beat becomes invalid when MSG_WAIT raises
    # ready, so it must cause an error rather than silently entering a phase.
    await command(dut, False, key, nonce)
    await send_raw_beat(dut, 0, bytes(range(16)), 0xFFFF, True)
    dut.in_kind_i.value = 0
    dut.in_data_i.value = lane_int(b"held extra beat")
    dut.in_keep_i.value = 0xFFFF
    dut.in_last_i.value = 1
    dut.in_valid_i.value = 1
    while not int(dut.in_ready_o.value):
        await RisingEdge(dut.clk_i)
        await Timer(1, unit="ns")
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    assert int(dut.error_o.value)
    dut.in_valid_i.value = 0
    await assert_clean_empty_transaction(dut, key, nonce)


@cocotb.test()
async def outputs_remain_stable_during_backpressure(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    await command(dut, False, key, nonce)
    await send_phase(dut, 0, b"")

    dut.out_ready_i.value = 0
    payload = b"stalled output"
    await send_phase(dut, 1, payload)
    while not int(dut.out_valid_o.value):
        await RisingEdge(dut.clk_i)
    first = (
        int(dut.out_data_o.value),
        int(dut.out_keep_o.value),
        int(dut.out_last_o.value),
    )
    for _ in range(7):
        await RisingEdge(dut.clk_i)
        assert int(dut.out_valid_o.value)
        assert first == (
            int(dut.out_data_o.value),
            int(dut.out_keep_o.value),
            int(dut.out_last_o.value),
        )
    dut.out_ready_i.value = 1
    await RisingEdge(dut.clk_i)

    dut.tag_out_ready_i.value = 0
    while not int(dut.tag_out_valid_o.value):
        await RisingEdge(dut.clk_i)
    first_tag = int(dut.tag_out_o.value)
    for _ in range(7):
        await RisingEdge(dut.clk_i)
        assert int(dut.tag_out_valid_o.value)
        assert int(dut.tag_out_o.value) == first_tag
    dut.tag_out_ready_i.value = 1


@cocotb.test()
async def reset_aborts_an_active_transaction(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    await command(dut, False, bytes(range(16)), bytes(range(16, 32)))
    assert int(dut.busy_o.value)
    dut.rst_i.value = 1
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    assert not int(dut.busy_o.value)
    assert int(dut.cmd_ready_o.value)
    assert not int(dut.out_valid_o.value)
    assert not int(dut.tag_out_valid_o.value)
    dut.rst_i.value = 0


@cocotb.test()
async def reset_clears_each_major_controller_phase(dut):
    """Reset initialization, AD, output, finalization, and tag-wait storage."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    await reset(dut)

    async def abort_and_recheck():
        await reset(dut)
        assert not int(dut.busy_o.value)
        assert int(dut.cmd_ready_o.value)
        assert not int(dut.out_valid_o.value)
        assert not int(dut.tag_out_valid_o.value)
        await assert_clean_empty_transaction(dut, key, nonce)

    # Initialization p12.
    await command(dut, False, key, nonce)
    await abort_and_recheck()

    # Associated-data p8.
    await command(dut, False, key, nonce)
    await send_raw_beat(dut, 0, bytes(range(16)), 0xFFFF, False)
    assert not int(dut.in_ready_o.value)
    await abort_and_recheck()

    # Payload output held by backpressure.
    await command(dut, False, key, nonce)
    await send_phase(dut, 0, b"")
    dut.out_ready_i.value = 0
    await send_phase(dut, 1, b"payload")
    while not int(dut.out_valid_o.value):
        await RisingEdge(dut.clk_i)
    await abort_and_recheck()

    # Finalization p12, immediately after an empty payload marker.
    await command(dut, False, key, nonce)
    await send_phase(dut, 0, b"")
    await send_phase(dut, 1, b"")
    assert int(dut.busy_o.value) and not int(dut.tag_out_valid_o.value)
    await abort_and_recheck()

    # Decryption tag wait.
    await command(dut, True, key, nonce)
    await send_phase(dut, 0, b"")
    await send_phase(dut, 1, b"")
    while not int(dut.tag_in_ready_o.value):
        await RisingEdge(dut.clk_i)
    await abort_and_recheck()


@cocotb.test()
async def delayed_tag_and_authentication_timing(dut):
    """The core may wait for a tag; auth_valid is asserted only on acceptance."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    ad = b"tag delay"
    plaintext = b"quarantined until authenticated"
    ciphertext, tag = encrypt(key, nonce, ad, plaintext)
    actual, auth_ok, commit, discard = await decrypt_dut(
        dut, key, nonce, ad, ciphertext, tag, tag_delay=11
    )
    assert actual == plaintext
    assert auth_ok and commit and not discard
    await RisingEdge(dut.clk_i)
    await Timer(1, unit="ns")
    assert not int(dut.auth_valid_o.value)
    assert not int(dut.auth_ok_o.value), "zeroization must clear stored auth state"


@cocotb.test()
async def changed_authenticated_inputs_are_rejected(dut):
    """A tag from one transaction must not authenticate changed inputs."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    key = bytes(range(16))
    nonce = bytes(range(16, 32))
    ad = b"associated data"
    plaintext = b"quarantined plaintext"
    ciphertext, tag = encrypt(key, nonce, ad, plaintext)
    cases = [
        (bytes([key[0] ^ 1]) + key[1:], nonce, ad, ciphertext),
        (key, bytes([nonce[0] ^ 1]) + nonce[1:], ad, ciphertext),
        (key, nonce, bytes([ad[0] ^ 1]) + ad[1:], ciphertext),
        (key, nonce, ad, bytes([ciphertext[0] ^ 1]) + ciphertext[1:]),
    ]
    for changed_key, changed_nonce, changed_ad, changed_ct in cases:
        _pt, auth_ok, commit, discard = await decrypt_dut(
            dut, changed_key, changed_nonce, changed_ad, changed_ct, tag
        )
        assert not auth_ok and not commit and discard
        await assert_clean_empty_transaction(dut, key, nonce)


@cocotb.test()
async def deterministic_randomized_differential_cases(dut):
    """Exercise longer messages that are outside the official 0..32 KAT grid."""
    cocotb.start_soon(Clock(dut.clk_i, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(0xA5C02026)
    lengths = [(0, 48), (3, 64), (16, 47), (17, 65), (48, 1), (63, 80)]
    for ad_length, message_length in lengths:
        key = rng.randbytes(16)
        nonce = rng.randbytes(16)
        ad = rng.randbytes(ad_length)
        plaintext = rng.randbytes(message_length)
        expected_ciphertext, expected_tag = encrypt(key, nonce, ad, plaintext)
        actual_ciphertext, actual_tag = await encrypt_dut(
            dut, key, nonce, ad, plaintext
        )
        assert actual_ciphertext == expected_ciphertext
        assert actual_tag == expected_tag
        actual_plaintext, auth_ok, commit, discard = await decrypt_dut(
            dut, key, nonce, ad, actual_ciphertext, actual_tag
        )
        assert actual_plaintext == plaintext
        assert auth_ok and commit and not discard
