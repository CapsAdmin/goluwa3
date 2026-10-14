#!/bin/sh
# shoot.sh tag [preset] [views]: renders views into cmp/<tag>_N.png
mkdir -p test/harnesses/clouds/cmp
SUN_ELEV=${SUN_ELEV:-35} CLOUDS=${2:-cumulus} OUT=test/harnesses/clouds/cmp/$1_ VIEWS="${3:-0,2600,0,2,0,60;0,4200,0,-6,70,60;0,3000,0,0,200,60}" EV=${EV:-13} timeout 120 luajit glw --3d --background --validate lua "import('test/harnesses/clouds/scene.lua') import('test/harnesses/clouds/views.lua')" 2>&1 | grep -v "^\s*\[C\]" | head -15
