#!/bin/sh
# shoot.sh tag: open sea shot, env WIND POS ANG FOV SETTLE PVARS OUT
mkdir -p test/harnesses/ocean/cmp
OUT=${OUT:-test/harnesses/ocean/cmp/$1.png} timeout 120 luajit glw --3d --background --validate lua "import('test/harnesses/ocean/shot.lua')" 2>&1 | grep -v "^\s*\[C\]" | grep -i -E "error|fail|\.png" | grep -v kleiner
