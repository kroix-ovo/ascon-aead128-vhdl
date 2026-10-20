"""Concurrent stream scoreboard: no producer/consumer serialization assumptions."""
import hashlib
import json
import os
import random
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from ascon_ref import encrypt
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fetch_vectors import parse_kats


class Stream:
    def __init__(self, dut):
        self.d = dut
        self.cycle = 0
        self.held = None

    async def step(self, **values):
        d = self.d
        await FallingEdge(d.clk_i)
        defaults = dict(rst_i=0, cmd_valid_i=0, in_valid_i=0,
                        tag_in_valid_i=0, out_ready_i=1, tag_out_ready_i=1)
        defaults.update(values)
        for k, v in defaults.items():
            getattr(d, k).value = v
        await Timer(1, unit="ns")
        names = ['cmd_ready_o', 'in_ready_o', 'out_valid_o', 'out_data_o',
                 'out_keep_o', 'out_last_o', 'tag_in_ready_o',
                 'tag_out_valid_o', 'tag_out_o']
        # Synchronous reset has not taken effect before this first edge.
        pre = {n: 0 for n in names} if defaults['rst_i'] else {n: int(getattr(d, n).value) for n in names}
        current = (pre['out_data_o'], pre['out_keep_o'], pre['out_last_o'])
        if self.held is not None and not defaults['rst_i']:
            assert pre['out_valid_o'] and current == self.held, 'stalled output changed'
        self.held = current if pre['out_valid_o'] and not defaults['out_ready_i'] else None
        await RisingEdge(d.clk_i)
        await Timer(1, unit="ns")
        post = {n: int(getattr(d, n).value) for n in
                ['done_o', 'auth_valid_o', 'auth_ok_o', 'commit_o', 'discard_o', 'error_o']}
        self.cycle += 1
        return pre, post

    async def reset(self):
        await self.step(rst_i=1)
        self.held = None
        await self.step(rst_i=1)
        await self.step()
        assert int(self.d.cmd_ready_o.value)
        assert not int(self.d.out_valid_o.value)
        assert not int(self.d.tag_out_valid_o.value)

    async def transaction(self, key, nonce, ad, data, decrypt=False, tag=b'',
                          gaps=False, stalls=False, bad=False, raw=None):
        def phase(kind, payload):
            chunks = [payload[i:i+16] for i in range(0, len(payload), 16)] or [b'']
            return [(kind, int.from_bytes(x, 'little'), (1 << len(x))-1,
                     int(i == len(chunks)-1)) for i, x in enumerate(chunks)]
        beats = raw if raw is not None else phase(0, ad) + phase(1, data)
        sent = 0
        command_sent = False
        received = bytearray()
        got_tag = None
        tag_sent = False
        commit = discard = auth = errors = 0
        accepted_cycles = []
        input_stall = output_stall = 0
        start = self.cycle
        pending = False
        last_output = False
        for t in range(50000):
            # Once valid is offered, hold the entire beat until accepted.
            if command_sent and sent < len(beats) and (pending or not gaps or t % 5 not in (0, 1)):
                pending = True
            controls = dict(cmd_valid_i=int(not command_sent), cmd_decrypt_i=int(decrypt),
                            key_i=int.from_bytes(key, 'little'), nonce_i=int.from_bytes(nonce, 'little'),
                            out_ready_i=int(not stalls or (t % 53 >= 31)),
                            tag_out_ready_i=int(not stalls or t % 7 != 0),
                            tag_in_valid_i=int(decrypt and not tag_sent and t > 9),
                            tag_in_i=int.from_bytes(tag, 'little'))
            if pending:
                k, x, keep, last = beats[sent]
                controls.update(in_valid_i=1, in_kind_i=k, in_data_i=x, in_keep_i=keep, in_last_i=last)
            pre, post = await self.step(**controls)
            if controls['cmd_valid_i'] and pre['cmd_ready_o']:
                command_sent = True
            if pending:
                if pre['in_ready_o']:
                    sent += 1
                    pending = False
                else:
                    input_stall += 1
            if pre['out_valid_o']:
                if controls['out_ready_i']:
                    keep = pre['out_keep_o']
                    assert keep and (keep & (keep+1)) == 0
                    assert not last_output, 'output after last'
                    received += pre['out_data_o'].to_bytes(16, 'little')[:keep.bit_count()]
                    last_output = bool(pre['out_last_o'])
                    accepted_cycles.append(t)
                else:
                    output_stall += 1
            if pre['tag_out_valid_o'] and controls['tag_out_ready_i']:
                assert len(received) == len(data), 'tag preceded output drain'
                got_tag = pre['tag_out_o'].to_bytes(16, 'little')
            if controls['tag_in_valid_i'] and pre['tag_in_ready_o']:
                assert len(received) == len(data), 'tag accepted before output drained'
                tag_sent = True
            commit += post['commit_o']; discard += post['discard_o']
            auth += post['auth_valid_o']; errors += post['error_o']
            if post['auth_valid_o']:
                assert len(received) == len(data)
                assert bool(post['auth_ok_o']) == (not bad)
            if post['done_o']:
                assert errors == int(raw is not None)
                assert commit == int(decrypt and not bad and raw is None)
                assert discard == int(decrypt and (bad or raw is not None))
                assert auth == int(decrypt and raw is None)
                assert not int(self.d.out_valid_o.value)
                return bytes(received), got_tag, dict(cycles=self.cycle-start,
                    first_output_cycle=accepted_cycles[0] if accepted_cycles else None,
                    block_intervals=[b-a for a,b in zip(accepted_cycles,accepted_cycles[1:])],
                    input_stall_cycles=input_stall, output_stall_cycles=output_stall)
        raise AssertionError(f'timeout: sent {sent}/{len(beats)}, received {len(received)}')


@cocotb.test()
async def concurrent_kats_protocol_and_metrics(dut):
    cocotb.start_soon(Clock(dut.clk_i, 10, unit='ns').start())
    s = Stream(dut)
    await s.reset()
    root = Path(__file__).resolve().parents[2]
    vectors = list(parse_kats((root/'verification/vectors/LWC_AEAD_KAT_128_128.txt').read_bytes()))
    if not int(os.getenv('FULL_KAT', '1')):
        vectors = vectors[:8]
    for v in vectors:
        ct, tag, _ = await s.transaction(v['key'], v['nonce'], v['ad'], v['pt'])
        assert (ct, tag) == (v['ct'], v['tag'])
        pt, _, _ = await s.transaction(v['key'], v['nonce'], v['ad'], ct, True, tag)
        assert pt == v['pt']
    rng = random.Random(20261020)
    metrics = []
    for i, size in enumerate([0, 1, 15, 16, 17, 31, 32, 33, 127, 1024, 4096]):
        key, nonce = rng.randbytes(16), (10000+i).to_bytes(16, 'little')
        ad, plain = rng.randbytes(i*3), rng.randbytes(size)
        ct, tag = encrypt(key, nonce, ad, plain)
        for stalls in (False, True):
            # Separate encryption messages use separate nonces.
            n = (20000+i*2+int(stalls)).to_bytes(16, 'little')
            ct, tag = encrypt(key, n, ad, plain)
            actual, actual_tag, measured = await s.transaction(key, n, ad, plain, gaps=stalls, stalls=stalls)
            assert (actual, actual_tag) == (ct, tag)
            pt, _, _ = await s.transaction(key, n, ad, ct, True, tag, gaps=stalls, stalls=stalls)
            assert pt == plain
            metrics.append(dict(bytes=size, stalls=stalls, **measured))
        for field in ('ct', 'ad', 'nonce', 'tag'):
            def flip(b): return bytes([b[0]^1])+b[1:] if b else b'\x01'
            changed = dict(ct=ct, ad=ad, nonce=n, tag=tag)
            changed[field] = flip(changed[field])
            await s.transaction(key, changed['nonce'], changed['ad'], changed['ct'], True,
                                changed['tag'], stalls=True, bad=True)
    # Malformed AD and payload, invalid keep and non-final short/empty beats.
    key=bytes(range(16))
    for i, raw in enumerate([[(1,0,0,1)], [(0,0,5,1)], [(0,0,1,0)],
                             [(0,0,0,1),(1,0,1,0)], [(0,0,0,1),(1,0,5,1)],
                             [(0,0,0,1),(1,0,0,0)]]):
        await s.transaction(key, (30000+i).to_bytes(16,'little'), b'', b'', True, raw=raw, bad=True)
    # Fill queues under backpressure, then reset while data is buffered.
    while not int(dut.cmd_ready_o.value):
        await s.step()
    await s.step(cmd_valid_i=1, cmd_decrypt_i=1, key_i=0, nonce_i=40000)
    phase = 0
    for t in range(150):
        pre, post = await s.step(in_valid_i=1, in_kind_i=int(phase>0), in_data_i=phase,
                         in_keep_i=0 if phase==0 else 65535, in_last_i=int(phase==0), out_ready_i=0)
        if pre['in_ready_o']: phase += 1
        assert not post['commit_o']
    assert int(dut.out_valid_o.value), 'reset fixture never reached buffered output'
    await s.reset()
    ct, tag, _ = await s.transaction(key, (40001).to_bytes(16,'little'), b'', b'after reset')
    assert (ct, tag) == encrypt(key, (40001).to_bytes(16,'little'), b'', b'after reset')
    Path('stream_metrics.json').write_text(json.dumps(dict(official_checks=len(vectors)*2,metrics=metrics),indent=2))
