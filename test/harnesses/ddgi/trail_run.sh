#!/bin/bash
# DDGI trail benchmark. usage: trail_run.sh label ["pvar=value ..."]
# A 0.8 m box circles a room (0.02 rad a frame on a 2.5 m radius) under a top down orthographic GI-only view, captured on
# frame TRAIL_FRAME (500) and diffed against a static box parked where the moving one is. Prints the rms of the floor
# difference with the box masked out; two static runs differ by about 0.13 percent. tmp/tr_<label>_diff.png shows it x10.
cd "$(dirname "$0")/../../.."
L=$1; export TRAIL_PV="$2"; export TRAIL_EV=${TRAIL_EV:-15.5}; F=${TRAIL_FRAME:-500}; S=${TRAIL_SPEED:-0.02}
read MX MY <<< $(python3 -c "
import math
a=$F*$S
print(int(960+120*2.5*math.cos(a)), int(540+120*2.5*math.sin(a)))")
for m in move static; do TRAIL_MODE=$m TRAIL_OUT=tmp/tr_${L}_$m.png timeout 120 luajit glw --3d --background --validate lua test/harnesses/ddgi/trail.lua >/dev/null 2>&1; done
for m in move static; do magick tmp/tr_${L}_$m.png -fill black -draw "rectangle $((MX-130)),$((MY-130)) $((MX+130)),$((MY+130))" -crop 912x912+504+84 +repage tmp/tr_${L}_${m}_m.png; done
echo "$L trail-metric: $(compare -metric RMSE tmp/tr_${L}_move_m.png tmp/tr_${L}_static_m.png null: 2>&1)"
magick tmp/tr_${L}_move.png tmp/tr_${L}_static.png -compose difference -composite -evaluate Multiply 10 tmp/tr_${L}_diff.png
