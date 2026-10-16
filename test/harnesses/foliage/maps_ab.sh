#!/bin/sh
# maps_ab.sh out_prefix: three shots of the same close up, with the normal maps, without and with flat roughness
cd "$(dirname "$0")/../../.."
export MODEL="${MODEL:-models/foliage/rocks/boulder_a.lua;models/foliage/rocks/mossy_boulder_a.lua;models/foliage/plants/stump_a.lua;models/foliage/plants/bush_a.lua}"
export SPACING="${SPACING:-2.2}"
run() {
	timeout 90 luajit glw --3d --background --validate shot "$1" --setup test/harnesses/foliage/maps_ab.lua --pos "${POS:-0,1.3,3.2}" --ang "${ANG:--18,0,0}" --fov 60 --ev "${EV:-14}" --settle 3 2>&1 | grep -i "error\|saved"
}
run "$1_on.png"
NORMALS=0 run "$1_off.png"
ROUGHNESS=flat run "$1_flat.png"
