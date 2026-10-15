#!/bin/sh
# writes the path tracer's reference for the fit: tmp/fogref/sun<elevation>_vis<visibility>.txt, 15 views each (about 3 minutes)
# SUNS="60 25" sh test/harnesses/fog/fit/reference.sh
mkdir -p tmp/fogref
for sun in ${SUNS:-60 25}; do
  for v in 0 300 1000 2000 5000 20000; do
    f=tmp/fogref/sun${sun}_vis${v}.txt
    [ -s $f ] && continue
    SUN=$sun FOG=$v ELEVS=2,5,10,25,60 AZ=0,90,180 MC=3000 timeout 600 luajit glw --3d --background --validate lua "import('test/harnesses/fog/sky.lua')" 2>&1 | grep -E "sky.lua:94" | awk '{print $2, $3, $4, $5}' > $f
  done
done
