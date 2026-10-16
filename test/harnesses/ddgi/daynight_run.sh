#!/bin/bash
# How fast the gi follows the sun going down. usage: daynight_run.sh label ["pvar=value ..."]
# 30 frames 6 apart (about 3 s) after the sun leaves at 5 s, default update intervals. Prints the room's mean grey per
# frame as percent of the first frame and the seconds (at 60 fps) until it is within 10 percent of the last frame.
cd "$(dirname "$0")/../../.."
rm -rf tmp/val/dn_$1
VAL_SCENE=daynight VAL_OUT=tmp/val/dn_$1 VAL_FRAMES=30 VAL_STRIDE=6 VAL_PV="$2" VAL_EV=11 timeout 200 luajit glw --3d --background --validate lua test/harnesses/ddgi/validate.lua 2>&1 | grep -i error | head
python3 - "$1" <<'PY'
import subprocess, sys
label = sys.argv[1]
means = []
for i in range(30):
    out = subprocess.run(["magick", f"tmp/val/dn_{label}/f{i:03d}.png", "-colorspace", "Gray", "-format", "%[fx:mean]", "info:"], capture_output=True, text=True).stdout
    means.append(float(out))
first, last = means[0], means[-1]
settle = next((i for i in range(30) if all(abs(m - last) <= 0.1 * max(first - last, 1e-6) for m in means[i:])), 29)
print(f"{label}: first={first:.3f} last={last:.3f} settle={settle * 6 / 60:.2f}s  " + " ".join(f"{100 * (m - last) / max(first - last, 1e-6):.0f}" for m in means[::3]))
PY
