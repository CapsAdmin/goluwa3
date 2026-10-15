#!/bin/sh
# usage: sh test/harnesses/fog/fit/compare.sh sun vis...   compares the engine to tmp/fogref/sun<sun>_vis<v>.txt
sun=$1; shift
for v in "$@"; do
  SUN=$sun FOG=$v ELEVS=2,5,10,25,60 AZ=0,90,180 MC=100 timeout 300 luajit glw --3d --background --validate lua "import('test/harnesses/fog/sky.lua')" 2>&1 | grep -E "sky.lua:94" | awk '{print $2, $3, $4}' > tmp/fogref/eng_sun${sun}_vis${v}.txt
  python3 - $sun $v <<'P'
import sys, math
sun, v = sys.argv[1], sys.argv[2]
ref = {}
for l in open(f'tmp/fogref/sun{sun}_vis{v}.txt'):
    e,a,eng,mc = l.split(); ref[(e,a)] = float(mc)
rows=[]; s=0; n=0
for l in open(f'tmp/fogref/eng_sun{sun}_vis{v}.txt'):
    e,a,eng = l.split()
    if (e,a) in ref and not (int(e) >= int(sun)-3 and a == '0'):
        r = float(eng)/ref[(e,a)]; rows.append(f'{e}/{a} {r:.2f}'); s += math.log(r)**2; n += 1
print(f'vis {v}: rms {math.sqrt(s/n):.3f}  ' + '  '.join(rows))
P
done
