#!/bin/bash
# DDGI validation suite. usage: validate_run.sh [scene ...] (default: all). Env VAL_PV="pvar=value ..." applies to all.
# BOIL: flicker of 12 consecutive frames after 5 s, rms against their mean (0-255) over 2.5 or more than 0.05 percent of pixels over 32.
# LEAK: mean grey of a sealed room's inside, it should be near 0 (the gi only view shows nothing else).
cd "$(dirname "$0")/../../.."
scenes=${@:-slit door emitters crystals seal_box seal_plane seal_lights}
one() {
  s=$1
  rm -rf tmp/val/$s
  VAL_SCENE=$s timeout 120 luajit glw --3d --background --validate lua test/harnesses/ddgi/validate.lua 2>&1 | grep -i "error" | head -3
  [ -f tmp/val/$s/f011.png ] || { echo "$s: no output"; return; }
  # flicker: rms of each frame against the mean of the frames, and how many pixels spike
  score=$(python3 test/harnesses/ddgi/fireflies_score.py tmp/val/$s)
  rms=$(echo "$score" | sed 's/.*rms=\([0-9.]*\).*/\1/')
  spikes=$(echo "$score" | sed 's/.*>32:\([0-9.]*\)%.*/\1/')
  mean=$(magick tmp/val/$s/f011.png -colorspace Gray -format '%[fx:mean]' info:)
  verdict=ok
  case $s in
    seal_*) python3 -c "import sys; sys.exit(0 if $mean < 0.04 else 1)" || verdict=LEAK ;;
  esac
  python3 -c "import sys; sys.exit(0 if $rms < 2.5 and $spikes < 0.05 else 1)" || verdict="$verdict BOIL"
  [[ "$s" == emitters || "$s" == crystals ]] && { python3 -c "import sys; sys.exit(0 if $mean > 0.08 else 1)" || verdict="$verdict DARK"; }
  echo "$s: flicker_rms=$rms spikes>32=${spikes}% mean=$mean $verdict"
}
# scenes run VAL_JOBS (3) at a time, the gpu has room for that many small scenes
for s in $scenes; do
  one $s > tmp/val_$s.txt &
  while [ $(jobs -r | wc -l) -ge ${VAL_JOBS:-3} ]; do sleep 0.2; done
done
wait
for s in $scenes; do cat tmp/val_$s.txt; done
# movement: a box circling a room, the floor behind it against a static box parked in the same place (trail, floor is 0.13 percent)
if [ -z "$1" ]; then
  for speed in 0.02 0.06; do
    r=$(TRAIL_SPEED=$speed test/harnesses/ddgi/trail_run.sh mv$speed | sed 's/.*(\(.*\))/\1/')
    pct=$(python3 -c "print(round($r*100,2))")
    v=ok; python3 -c "import sys; sys.exit(0 if $pct < 0.3 else 1)" || v=TRAIL
    echo "move_box speed=$speed: trail=${pct}% $v"
  done
fi
