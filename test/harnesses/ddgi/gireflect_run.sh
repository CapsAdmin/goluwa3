#!/bin/bash
# usage: gireflect_run.sh label view [lit|gi] ["pvar=value ..."]
# view: firefly plane leak outside (or 1-4). saves GIR_FRAMES (12) consecutive frames of the gi_reflections scene and prints flicker and the mean grey.
# env: GIR_WARM (600) GIR_FRAMES (12) GIR_EV, see gireflect.lua
cd "$(dirname "$0")/../../.."
label=$1; view=$2; mode=${3:-gi}; pv=$4
out=tmp/gir/$label
rm -rf $out
gi=1; [ "$mode" = lit ] && gi=0
GIR_FRAMES=${GIR_FRAMES:-12} GIR_VIEW=$view GIR_GI=$gi GIR_OUT=$out GIR_PV="$pv" timeout 300 luajit glw --3d --background --validate lua test/harnesses/ddgi/gireflect.lua 2>&1 | grep -i "error" | head -3
[ -f $out/f000.png ] || { echo "$label: no output"; exit 1; }
last=$(ls $out/f*.png | tail -1)
score=$(python3 test/harnesses/ddgi/fireflies_score.py $out | sed 's/ max=.*//')
echo "$score"
echo "   $label meanlum $(magick $last -colorspace Gray -format '%[fx:mean]' info:)"
