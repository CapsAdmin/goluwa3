#!/bin/sh
# layouts as "levels:grid:samples", default is the set that was compared on 2026-10-14
cd "$(dirname "$0")/../../.."
LAYOUTS=${LAYOUTS:-"8:4:65 8:8:65 8:6:65 7:6:65 7:8:65 6:8:65"}
for layout in $LAYOUTS; do
	LEVELS=${layout%%:*}
	rest=${layout#*:}
	GRID=${rest%%:*}
	SAMPLES=${rest#*:}
	LEVELS=$LEVELS GRID=$GRID SAMPLES=$SAMPLES timeout 150 luajit glw --3d --background lua "./test/harnesses/terrain/layout.lua" 2>&1 | grep "^.*LAYOUT" | sed 's/^.*LAYOUT/LAYOUT/'
done
