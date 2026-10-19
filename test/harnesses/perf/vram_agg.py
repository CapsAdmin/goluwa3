import re,sys
rows=[]
for l in open(sys.argv[1], errors='replace'):
    m=re.match(r'\s*([\d.]+) (MiB|GiB)\s+[\d.]+%\s+x(\d+)\s+(.*)',l)
    if m:
        v=float(m.group(1))*(1024 if m.group(2)=='GiB' else 1)
        rows.append((v,int(m.group(3)),m.group(4)))
tot=sum(r[0] for r in rows)
cats={}
for v,c,n in rows:
    mm=re.match(r'(.*?) framebuffer color',n)
    if mm: k='fb:'+mm.group(1)
    elif n.startswith('texture '): k='texture'
    else: k=re.sub(r' \[type \d+\]','',n)
    cats[k]=cats.get(k,0)+v
fb=sum(v for k,v in cats.items() if k.startswith('fb:'))
print("total %.0f MiB, framebuffers %.0f MiB" % (tot,fb))
for k,v in sorted(cats.items(),key=lambda x:-x[1])[:int(sys.argv[2]) if len(sys.argv)>2 else 30]:
    print(f"{v:9.1f} {k}")
