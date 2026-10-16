#!/bin/sh
# a shot of foliage models on a ground: shot.sh out.png "path;path" x,y,z pitch,yaw,roll [fov]
# SPACING=3 COLUMNS=4 test/harnesses/foliage/shot.sh tmp/rocks.png "models/foliage/rocks/boulder_a.lua" 0,2.5,7 -15,0,0
cd "$(dirname "$0")/../../.."
MODEL="$2" timeout 90 luajit glw --3d --background --validate shot "$1" --setup test/harnesses/foliage/scene.lua --pos "$3" --ang "$4" --fov "${5:-60}" --settle 2 2>&1 | grep -i "error\|saved\|built\|fail"
