"""Decode a physical ILA capture; do not treat a programming receipt as a pass."""
import argparse
import csv
import hashlib
import json
from pathlib import Path


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('directory',type=Path)
    p.add_argument('--period-ns',type=float,required=True)
    p.add_argument('--expected-cycles',type=int,default=1161)
    p.add_argument('--expected-last-case',type=int,default=17)
    p.add_argument('--expected-demo-cycles',type=int,default=274)
    a=p.parse_args()
    capture=a.directory/'capture.csv'
    with capture.open(newline='') as f:
        reader=csv.DictReader(f);radix=next(reader)
        fields=['done','pass','fail','test_case[7:0]','cycles[31:0]',
                'auto_done','auto_pass','auto_fail','auto_case[2:0]','auto_cycles[31:0]']
        assert all(radix[n]=='HEX' for n in fields)
        records=[{n:int(row[n],16) for n in fields} for row in reader]
    assert len(records)==1024
    assert all(r==records[0] for r in records), 'Unstable latched result'
    r=records[0]
    assert r['done']==1 and r['pass']==1 and r['fail']==0
    assert r['test_case[7:0]']==a.expected_last_case
    assert r['cycles[31:0]']==a.expected_cycles, 'Hardware cycle count differs from simulated selftest'
    assert r['auto_done']==1 and r['auto_pass']==1 and r['auto_fail']==0
    assert r['auto_case[2:0]']==7 and r['auto_cycles[31:0]']==a.expected_demo_cycles
    result=dict(demo_cases=8,demo_cycles=r['auto_cycles[31:0]'],result='PASS',origin='Physical FPGA ILA capture over JTAG',samples=len(records),
        cases=a.expected_last_case+1,cycles=r['cycles[31:0]'],nominal_clock_hz=1e9/a.period_ns,
        nominal_selftest_microseconds=r['cycles[31:0]']*a.period_ns/1000,
        raw=r,capture_sha256=hashlib.sha256(capture.read_bytes()).hexdigest(),
        device_receipt=(a.directory/'device.txt').read_text(),
        scope='Bounded hardware fixtures, reset recovery, stalls, authentication and quarantine; all eight original demo vector/mode pairs; full weight payload verified separately in simulation')
    (a.directory/'decoded.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':main()
