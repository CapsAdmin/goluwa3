#!/bin/sh
# bench.sh tag: one frozen cloud view, writes cmp/<tag>.png and prints the GPU time of the cloud passes
mkdir -p test/harnesses/clouds/cmp
NOGROUND=1 CLOUDS=${CLOUDS:-mixed} SUN_ELEV=${SUN_ELEV:-40} SUN_AZ=${SUN_AZ:-110} OUT=test/harnesses/clouds/cmp/$1.png timeout 150 luajit glw --3d --background lua "import('test/harnesses/clouds/bench.lua')" 2>&1 | grep -E "CAPTURE|SAVED|GPU |rror" | grep -v kleiner
