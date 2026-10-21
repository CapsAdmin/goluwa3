#!/bin/bash
# usage: gireflect_gpu.sh view ["pvar=value ..."]   gpu time of a gi_reflections view per group and scope (no validation layers, one process, about 20 s)
cd "$(dirname "$0")/../../.."
echo "=== $1  [$2]"
GIR_WARM=${GIR_WARM:-400} GIR_GPU=${GIR_GPU:-4} GIR_GI=0 GIR_VIEW=$1 GIR_PV="$2" timeout 200 luajit glw --3d --background lua test/harnesses/ddgi/gireflect.lua 2>&1 | grep -a "GPU\|rror" | sed 's/^[^ ]*gireflect.lua:[0-9]* //'
