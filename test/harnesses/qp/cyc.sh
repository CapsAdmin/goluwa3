#!/bin/bash
cd /home/caps/projects/goluwa3
VK_INSTANCE_LAYERS="" QP_MODES="$1" QP_SCOPES="${2:-gpu_frame,ddgi_shade,ddgi_resolve,gbuffer}" timeout 500 luajit glw --hdr --3d lua test/harnesses/qp/cycle.lua 2>&1 | grep -E "RESULT|rror"
