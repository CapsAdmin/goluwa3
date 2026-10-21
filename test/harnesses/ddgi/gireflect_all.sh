#!/bin/bash
# usage: gireflect_all.sh label [lit|gi] ["pvar=value ..."]   one frame of every room of the gi_reflections scene (run 3 at a time),
# tmp/gir/<label>_<room>/f000.png, a contact sheet in tmp/gir/<label>_sheet.png, and the mean grey of each
cd "$(dirname "$0")/../../.."
label=$1; mode=${2:-lit}; pv=$3
rooms=${GIR_ROOMS:-cornell tunnel stage bleed partition partition_lit hall tower lamp spot neighbours corridor desk emitter cornell_room tiny_emitter moving spot_mover cave}
for r in $rooms; do
  GIR_WARM=${GIR_WARM:-500} GIR_FRAMES=1 test/harnesses/ddgi/gireflect_run.sh ${label}_$r $r $mode "$pv" > tmp/gir/${label}_$r.txt 2>&1 &
  while [ $(jobs -r | wc -l) -ge ${GIR_JOBS:-3} ]; do sleep 0.3; done
done
wait
for r in $rooms; do echo "$r $(grep meanlum tmp/gir/${label}_$r.txt | sed 's/.*meanlum //')"; done
montage $(for r in $rooms; do echo tmp/gir/${label}_$r/f000.png; done) -tile 4x -geometry 480x270+2+2 -label '%d' tmp/gir/${label}_sheet.png 2>/dev/null
