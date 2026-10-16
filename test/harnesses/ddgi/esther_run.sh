#!/bin/bash
# usage: esther_run.sh label ["pvar=value ..."]  flicker of the esther crystal cave view (the map needs the Dear Esther mount)
cd "$(dirname "$0")/../../.."
rm -rf tmp/est/$1
EST_OUT=tmp/est/$1 EST_PV="$2" timeout 400 luajit glw --3d --background --validate lua test/harnesses/ddgi/esther.lua 2>&1 | grep -i "error" | head -3
python3 test/harnesses/ddgi/fireflies_score.py tmp/est/$1 | sed 's/ max=.*//'
echo "   meanlum $(magick tmp/est/$1/f011.png -colorspace Gray -format '%[fx:mean]' info:)"
