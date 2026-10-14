#!/bin/sh
# renders the views of views.lua over scene.lua, one png each into storage/logs/scatter_<PREFIX>_<name>.png
# SET=crysis_forest PREFIX=forest test/harnesses/scatter/run.sh
cd "$(dirname "$0")/../../.."
SCENE=test/harnesses/scatter/scene.lua VIEWS=test/harnesses/scatter/views.lua timeout 240 luajit glw --3d --background --validate lua "./test/harnesses/scatter/seq.lua" 2>&1 | grep -v "^\[shader\]\|^\[pipeline\]"
