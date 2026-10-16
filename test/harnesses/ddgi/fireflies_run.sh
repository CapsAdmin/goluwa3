#!/bin/bash
# DDGI flicker benchmark. usage: fireflies_run.sh label scene(sun|lamp) ["pvar=value ..."]
# Captures FLY_FRAMES (40) consecutive GI-only frames of a static room after FLY_WARM (60) frames, every cascade updating
# every frame (FLY_DEFAULT_INTERVALS=1 keeps the real intervals, use FLY_WARM=300 FLY_FRAMES=130 then, the far
# cascades only update every 4 to 64 frames), ambient occlusion off, then scores each frame against the mean of the frames (flicker, in 0-255 grey).
# Output frames go to tmp/fly/<label>_<scene>. A single lamp run varies a lot between runs (rms 3.5 to 5.1 for the same
# settings), repeat it. Always check the mean luminance too, a lower flicker that darkens the room is bias, not a win.
cd "$(dirname "$0")/../../.."
rm -rf tmp/fly/$1_$2
FLY_SCENE=$2 FLY_OUT=tmp/fly/$1_$2 FLY_PV="$3" FLY_FRAMES=${FLY_FRAMES:-40} FLY_WARM=${FLY_WARM:-60} timeout 300 luajit glw --3d --background --validate lua test/harnesses/ddgi/fireflies.lua 2>&1 | grep -i "error" | head -5
python3 test/harnesses/ddgi/fireflies_score.py tmp/fly/$1_$2
echo "   meanlum $(magick tmp/fly/$1_$2/mean.png -colorspace Gray -format '%[fx:mean]' info:)"
