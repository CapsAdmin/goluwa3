#!/bin/bash
# usage: gireflect_ref.sh view ["pvar=value ..."]   the reference of gireflect_err.sh: the mean of GIR_FRAMES (120) GI-only frames GIR_GAP (20) apart
cd "$(dirname "$0")/../../.."
view=$1; pv=$2
out=tmp/gir/ref_$view
rm -rf $out
GIR_WARM=${GIR_WARM:-900} GIR_FRAMES=${GIR_FRAMES:-120} GIR_GAP=${GIR_GAP:-20} GIR_VIEW=$view GIR_GI=1 GIR_OUT=$out GIR_PV="$pv" timeout 600 luajit glw --3d --background --validate lua test/harnesses/ddgi/gireflect.lua 2>&1 | grep -i "error" | head -3
magick $out/f*.png -evaluate-sequence mean $out/mean.png
echo "reference tmp/gir/ref_$view/mean.png from $(ls $out/f*.png | wc -l) frames"
