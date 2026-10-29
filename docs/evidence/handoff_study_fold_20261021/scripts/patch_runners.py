"""One-off patcher (fold study): add the u3-fold variant / --folded flag to the weight runners.
Byte-level replacements keep the CRLF working-copy line endings."""
from pathlib import Path
import sys

ROOT = Path(sys.argv[1])


def patch(rel, reps):
    p = ROOT / rel
    d = p.read_bytes()
    for a, b in reps:
        assert d.count(a) == 1, (rel, a, d.count(a))
        d = d.replace(a, b)
    p.write_bytes(d)
    print('patched', rel)


BS = b'\\'
STAGE = sys.argv[2] if len(sys.argv) > 2 else 'runners'
if STAGE == 'runners':
  patch('verification/compare_stream.py', [
    (b"choices=['baseline','u3','u3-buffered'], default=['baseline','u3','u3-buffered'])",
     b"choices=['baseline','u3','u3-buffered','u3-fold'], default=['baseline','u3','u3-buffered'])"),
    (b"    for variant,rpc,buffered in [('baseline',1,False),('u3',3,False),('u3-buffered',3,True)]:\r\n        if variant not in args.variants: continue\r\n",
     b"    for variant,rpc,buffered in [('baseline',1,False),('u3',3,False),('u3-buffered',3,True),('u3-fold',3,True)]:\r\n        if variant not in args.variants: continue\r\n        folded = variant=='u3-fold'  # G_FOLDED_ABSORB single-state-register core\r\n"),
    (b"            if buffered:command+=['--buffering']\r\n",
     b"            if buffered:command+=['--buffering']\r\n            if folded:command+=['--folded']\r\n"),
    (b"+' -gG_BUFFERING_ENABLE='+str(buffered).lower()+' --assert-level=error" + BS + b"n').encode())",
     b"+' -gG_BUFFERING_ENABLE='+str(buffered).lower()+(' -gG_FOLDED_ABSORB=true' if folded else '')+' --assert-level=error" + BS + b"n').encode())"),
    (b"rounds_per_cycle=rpc,buffering=buffered,nonce_id=nonce,",
     b"rounds_per_cycle=rpc,buffering=buffered,folded_absorb=folded,nonce_id=nonce,"),
])
if STAGE == 'runners':
  patch('verification/simulate_weight_file.py', [
    (b"    p.add_argument('--buffering', action='store_true')\r\n",
     b"    p.add_argument('--buffering', action='store_true')\r\n    p.add_argument('--folded', action='store_true', help='G_FOLDED_ABSORB (needs --rounds-per-cycle 3 --buffering)')\r\n"),
    (b"set buffered [lindex $argv 3]\r\n", b"set buffered [lindex $argv 3]\r\nset folded [lindex $argv 4]\r\n"),
    (b"set_property generic [list G_RUN_DIR=$run_dir G_ROUNDS_PER_CYCLE=$rpc G_BUFFERING_ENABLE=$buffered] [get_filesets sim_1]",
     b"set_property generic [list G_RUN_DIR=$run_dir G_ROUNDS_PER_CYCLE=$rpc G_BUFFERING_ENABLE=$buffered G_FOLDED_ABSORB=$folded] [get_filesets sim_1]"),
    (b"rounds_per_cycle=args.rounds_per_cycle, buffering=args.buffering, message_partition",
     b"rounds_per_cycle=args.rounds_per_cycle, buffering=args.buffering, folded_absorb=args.folded, message_partition"),
    (b"str(args.rounds_per_cycle),str(args.buffering).lower()]",
     b"str(args.rounds_per_cycle),str(args.buffering).lower(),str(args.folded).lower()]"),
])


if STAGE == 'adapter':
    patch('verification/simulate_adapter.py', [
        (b"    parser.add_argument('--nonce-base', type=int, required=True, help='Unused public test nonce range (four messages)')\r\n",
         b"    parser.add_argument('--nonce-base', type=int, required=True, help='Unused public test nonce range (four messages)')\r\n"
         b"    parser.add_argument('--candidate', choices=['u3-buffered', 'u3-fold'], default='u3-buffered',\r\n"
         b"                        help='Accelerated configuration compared with the baseline (u3-fold = G_FOLDED_ABSORB)')\r\n"),
        (b"                    '--variants', 'baseline', 'u3-buffered', '--nonce-base', str(args.nonce_base)], check=True)\r\n",
         b"                    '--variants', 'baseline', args.candidate, '--nonce-base', str(args.nonce_base)], check=True)\r\n"),
        (b"    for variant in ['baseline', 'u3-buffered']:\r\n", b"    for variant in ['baseline', args.candidate]:\r\n"),
        (b"    candidate = full['u3-buffered']['cycles']['ENCRYPT']\r\n", b"    candidate = full[args.candidate]['cycles']['ENCRYPT']\r\n"),
        (b"    result.update(clock_hz=100_000_000, result='PASS', payload_sha256=digest,\r\n",
         b"    result.update(clock_hz=100_000_000, result='PASS', payload_sha256=digest, candidate=args.candidate,\r\n"),
    ])
