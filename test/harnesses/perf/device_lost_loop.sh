#!/bin/bash
# usage: [SCRIPT=file.lua] [INSTANCES=2] [SCENE=alpine|esther|quarry] [SECS=13] device_lost_loop.sh [runs per instance]
# loads the scene over and over in INSTANCES processes at once with GOLUWA_CHECKPOINTS=1 and stops starting new runs as soon as
# one run dies, keeping its log in tmp/vram/lost_<instance>_<run>.log (the fault report and the checkpoints the queue had reached
# are in it). the device is lost in about one run of ten here, see docs/debugging-and-profiling.md "Device lost"
cd "$(dirname "$0")/../../.."
mkdir -p tmp/vram
rm -f tmp/vram/loop_stop tmp/vram/loop_ok_*
instance() {
	for i in $(seq 1 ${RUNS}); do
		[ -e tmp/vram/loop_stop ] && return
		GOLUWA_CHECKPOINTS=1 SECONDS=${SECS:-13} SCENE=${SCENE:-alpine} timeout 100 luajit glw --3d --hdr --background --validate lua "${SCRIPT:-./test/harnesses/perf/vram_dump.lua}" > tmp/vram/cur_$1.log 2>&1
		code=$?

		if [ $code -ne 0 ]; then
			cp tmp/vram/cur_$1.log tmp/vram/lost_$1_$i.log
			echo "instance $1 run $i died (exit $code), log in tmp/vram/lost_$1_$i.log"
			touch tmp/vram/loop_stop
			return
		fi

		echo "instance $1 run $i ok"
		touch tmp/vram/loop_ok_$1_$i
	done
}
RUNS=${1:-60}
for n in $(seq 1 ${INSTANCES:-2}); do
	instance $n &
done
wait
echo "clean runs: $(ls tmp/vram/loop_ok_* 2>/dev/null | wc -l)"
