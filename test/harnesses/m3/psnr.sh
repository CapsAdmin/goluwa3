#!/bin/sh
# usage: psnr.sh dir tagA tagB
d=$1; a=$2; b=$3
for v in spawn0 spawn90 spawn180 spawn270 down45 up225 fwd0 fwd180; do
  printf "%-10s " $v
  compare -metric PSNR $d/${a}_$v.png $d/${b}_$v.png null: 2>&1
  echo
done
