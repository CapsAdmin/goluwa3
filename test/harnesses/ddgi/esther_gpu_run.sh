#!/bin/bash
# usage: esther_gpu_run.sh label ["pvar=value ..."]  gpu time of the esther cave view per group and scope, with what each scope worked on
# (the map needs the Dear Esther mount). one process, about 30 s of which the map load is most
cd "$(dirname "$0")/../../.."
echo "=== $1  [$2]"
EG_PV="$2" EG_SECONDS=${EG_SECONDS:-4} EG_TOP=${EG_TOP:-9} timeout 300 luajit glw --3d --background lua test/harnesses/ddgi/esther_gpu.lua 2>&1 | grep -a "GPU\|rror" | sed 's/^[^ ]*esther_gpu.lua:[0-9]* //'
