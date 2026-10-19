#!/usr/bin/env bash
# usage: run.sh label map ["pvar=value ..."]   one process of map_perf.lua (see there for the env vars)
cd "$(dirname "$0")/../../.."
echo "=== $1  $2  [$3]"
MP_MAP="$2" MP_PV="$3" timeout ${MP_TIMEOUT:-600} luajit glw --3d --background lua test/harnesses/perf/map_perf.lua 2>&1 | sed -E "s/^[^ ]*\.lua:[0-9]+ //" | grep -a "^MP\|rror"
