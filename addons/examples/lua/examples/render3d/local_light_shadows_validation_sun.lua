_G.LOCAL_LIGHT_SHADOWS_VALIDATION_MODE = "sun"
local ok, err = pcall(import, "addons/game/lua/scenes/local_light_shadows_validation.lua")
_G.LOCAL_LIGHT_SHADOWS_VALIDATION_MODE = nil

if not ok then error(err) end
