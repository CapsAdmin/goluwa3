#!/bin/sh
# cmpsky.sh a b: sky region (top 600 rows) difference between two bench images: RMSE %, mean and max level difference of 255
cd test/harnesses/clouds/cmp
magick $1.png -crop 1920x600+0+0 +repage /tmp/claude-1000/-home-caps-projects-goluwa3/0760a252-192c-4816-a67b-3b28724885bd/scratchpad/ska.png
magick $2.png -crop 1920x600+0+0 +repage /tmp/claude-1000/-home-caps-projects-goluwa3/0760a252-192c-4816-a67b-3b28724885bd/scratchpad/skb.png
S=/tmp/claude-1000/-home-caps-projects-goluwa3/0760a252-192c-4816-a67b-3b28724885bd/scratchpad
r=$(magick compare -metric RMSE $S/ska.png $S/skb.png null: 2>&1 | sed 's/.*(\(.*\))/\1/')
d=$(magick $S/ska.png $S/skb.png -compose difference -composite -format "mean %[fx:mean*255] max %[fx:maxima*255]" info:)
echo "sky $1 vs $2: rmse $r  $d"
