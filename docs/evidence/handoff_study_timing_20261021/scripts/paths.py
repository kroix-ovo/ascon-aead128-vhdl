import re,sys,collections,statistics as st
def parse(fn):
    t=open(fn).read(); rows=[]
    for b in t.split('\nSlack')[1:]:
        s=float(re.match(r'\s*\(\w+\)\s*:\s+(-?[\d.]+)ns',b).group(1))
        src=re.search(r'Source:\s+(\S+)',b).group(1); dst=re.search(r'Destination:\s+(\S+)',b).group(1)
        m=re.search(r'Data Path Delay:\s+([\d.]+)ns\s+\(logic ([\d.]+)ns.*route ([\d.]+)ns',b)
        lv=re.search(r'Logic Levels:\s+(\d+)\s*\(?([^)\n]*)',b)
        rows.append((s,src,dst,float(m.group(1)),float(m.group(2)),float(m.group(3)),int(lv.group(1)),lv.group(2)))
    return rows
if __name__=='__main__':
    rows=parse(sys.argv[1]); n=int(sys.argv[2]) if len(sys.argv)>2 else 20
    print(len(rows),'paths; slack',rows[0][0],'..',rows[-1][0])
    g=collections.defaultdict(list)
    for r in rows: g[(re.sub(r'\[\d+\]','[*]',r[1].rsplit('/',1)[0]),re.sub(r'\[\d+\]','[*]',r[2].rsplit('/',1)[0]))].append(r[0])
    for k,v in sorted(g.items(),key=lambda x:min(x[1])): print(len(v),'worst',min(v),k)
    print('mean logic %.3f route %.3f route frac %.3f'%(st.mean(r[4] for r in rows),st.mean(r[5] for r in rows),st.mean(r[5]/r[3] for r in rows)))
    print('levels',collections.Counter(r[6] for r in rows))
    for r in rows[:n]: print(f"{r[0]:.3f} {r[1]} -> {r[2]} dp={r[3]:.3f} logic={r[4]:.3f} route={r[5]:.3f} L={r[6]} ({r[7]})")
