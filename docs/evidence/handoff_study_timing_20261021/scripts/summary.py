import json,glob,os,re,sys
B=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def cyc(r,b): return -(-8//r)+(3 if b else 4)
rows=[]
for f in sorted(glob.glob(B+'/*/implementation.json')):
    n=os.path.basename(os.path.dirname(f))
    try: j=json.load(open(f))
    except Exception: continue
    u=open(os.path.join(os.path.dirname(f),'utilization.txt')).read() if os.path.exists(os.path.join(os.path.dirname(f),'utilization.txt')) else ''
    lut=re.search(r'\| Slice LUTs\s+\|\s+(\d+)',u); ff=re.search(r'\| Slice Registers\s+\|\s+(\d+)',u)
    if 'rpc' not in j: 
        rows.append((n,'route_stream',j)); continue
    P=float(j['period_ns']); w=float(j['all_wns_ns']); r=int(j['rpc']); b=j['buffered'] in (True,'true')
    eff=P-w; c=cyc(r,b)
    extra=' '.join(f"{k}={j[k]}" for k in ('place','route','opt','physopt','postroute_physopt','retiming','io','overconstrain') if str(j[k]) not in ('Default','none','0'))
    print(f"{n:28s} r={r} buf={int(b)} P={P:6.3f} WNS={w:7.3f} WHS={float(j['all_whs_ns']):6.3f} r2r={float(j['reg2reg_setup_slack_ns']):7.3f} P-WNS={eff:6.3f} ({1000/eff:6.1f}MHz) LUT={lut.group(1) if lut else '?':>5} FF={ff.group(1) if ff else '?':>5} cyc/blk={c} MB/s@P={16e3/(c*P):6.1f} lvl={j['worst_levels']} {j['worst_start'].split('/')[-2] if '/' in j['worst_start'] else j['worst_start']}->{j['worst_end'].split('/')[-2] if '/' in j['worst_end'] else j['worst_end']} {extra} t={j['runtime_s']}s")
