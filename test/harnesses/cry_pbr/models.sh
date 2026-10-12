#!/bin/bash
# usage: cry_pbr_models.sh TAG [indices...]
tag=$1; shift
n=18
idx=${@:-$(seq 1 $n)}
for i in $idx; do
  echo "=== [$i/$n] ==="
  ONLY=$i TAG=$tag timeout 90 luajit glw --3d --background --validate lua ./test/harnesses/cry_pbr/models.lua 2>&1 | grep -E "harnesses/cry_pbr/models.lua|ERROR|error:" | grep -v "proxy" | uniq -c | head -25
done
