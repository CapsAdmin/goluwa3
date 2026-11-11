if not CLIENT or not AUDIO or not RENDER_3D then return end

import("lua/ambience.lua").SetSource("wind", import("lua/world_wind.lua").Create)
