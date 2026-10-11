#!/bin/sh
# renders the comparison set into test/harnesses/clouds/cmp/$1_*.png and a contact sheet $1.jpg
tag=$1
mkdir -p test/harnesses/clouds/cmp
shoot() { # preset out views
	SUN_ELEV=${SUN_ELEV:-35} CLOUDS=$1 OUT=test/harnesses/clouds/cmp/${tag}_$2_ VIEWS="$3" EV=${EV:-13} timeout 120 luajit glw --3d lua "import('test/harnesses/clouds/scene.lua') import('test/harnesses/clouds/views.lua')" 2>&1 | grep -iA3 "error" | head -5
}
shoot cumulus cu "0,2,0,10,0;0,2,0,40,180,60;0,1200,-3000,5,10,50"
shoot congestus cg "0,2,0,12,40,60"
SUN_ELEV=12 shoot stratocumulus sc "0,2,0,10,0"
shoot altocumulus ac "0,2,0,35,0"
magick montage test/harnesses/clouds/cmp/${tag}_cu_1.png test/harnesses/clouds/cmp/${tag}_cu_2.png test/harnesses/clouds/cmp/${tag}_cu_3.png test/harnesses/clouds/cmp/${tag}_cg_1.png test/harnesses/clouds/cmp/${tag}_sc_1.png test/harnesses/clouds/cmp/${tag}_ac_1.png -tile 3x2 -geometry 960x540+4+4 -quality 88 test/harnesses/clouds/cmp/${tag}.jpg
