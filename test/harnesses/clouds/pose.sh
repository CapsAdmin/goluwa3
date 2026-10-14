#!/bin/sh
# pose.sh tag [preset]: the cumulus reference view from the 2026-10-14 comparison
mkdir -p test/harnesses/clouds/cmp
POS=-5363.360352,21.450281,-3751.188232 ANG=0.801335,2.961323,-0.078362 FOV=0.90595243589077 SUN=-0.154420,0.808937,0.512134,0.243913 CLOUDS=${2:-cumulus} EV=${EV:-14} OUT=test/harnesses/clouds/cmp/$1.png timeout 120 luajit glw --3d --background --validate lua "import('test/harnesses/clouds/pose.lua')" 2>&1 | grep -v "^\s*\[C\]" | grep -i -E "error|fail|pose.png" | grep -v kleiner
