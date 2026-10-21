#!/bin/bash
# usage: gireflect_err.sh label view [lit|gi] ["pvar=value ..."]   error of GI-only frames spread over time against a reference mean image
# (tmp/gir/ref_<view>/mean.png, made by gireflect_ref.sh): rms (0-255 grey) of each of GIR_FRAMES (8) frames GIR_GAP (25) apart, and their mean.
# The error holds the flicker and the slow blotches both, which 12 consecutive frames do not show.
cd "$(dirname "$0")/../../.."
label=$1; view=$2; pv=$4; mode=${3:-gi}
out=tmp/gir/$label
rm -rf $out
gi=1; [ "$mode" = lit ] && gi=0
GIR_FRAMES=${GIR_FRAMES:-8} GIR_GAP=${GIR_GAP:-25} GIR_VIEW=$view GIR_GI=$gi GIR_OUT=$out GIR_PV="$pv" timeout 300 luajit glw --3d --background --validate lua test/harnesses/ddgi/gireflect.lua 2>&1 | grep -i "error" | head -3
ref=${GIR_REF:-tmp/gir/ref_$view/mean.png}
python3 - $out $ref <<'PY'
import subprocess, sys, glob
d, ref = sys.argv[1], sys.argv[2]
frames = sorted(glob.glob(d + "/f*.png"))
errs = []
for f in frames:
    raw = subprocess.run(["magick", f, ref, "-compose", "difference", "-composite", "-colorspace", "Gray", "-depth", "8", "gray:-"], capture_output=True, check=True).stdout
    errs.append((sum(b * b for b in raw) / len(raw)) ** 0.5)
mean = subprocess.run(["magick", "-size", "1x1", "xc:black"] + [] , capture_output=True)
lum = subprocess.run(["magick", frames[-1], "-colorspace", "Gray", "-format", "%[fx:mean]", "info:"], capture_output=True, check=True).stdout.decode()
print(f"{d}: err_rms mean={sum(errs)/len(errs):.2f} max={max(errs):.2f} meanlum={float(lum):.4f}")
PY
