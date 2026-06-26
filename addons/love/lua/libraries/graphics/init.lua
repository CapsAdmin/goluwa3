local love = ... or _G.love
local line = import("lua/line.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local env_loaded_modules = {
	"addons/love/lua/libraries/graphics/transform.lua",
	"addons/love/lua/libraries/graphics/state.lua",
	"addons/love/lua/libraries/graphics/color.lua",
	"addons/love/lua/libraries/graphics/points.lua",
	"addons/love/lua/libraries/graphics/line_state.lua",
	"addons/love/lua/libraries/graphics/info.lua",
	"addons/love/lua/libraries/graphics/scissor.lua",
	"addons/love/lua/libraries/graphics/shapes.lua",
	"addons/love/lua/libraries/graphics/reset.lua",
}
local post_installer_env_loaded_modules = {
	"addons/love/lua/libraries/graphics/quad.lua",
	"addons/love/lua/libraries/graphics/image.lua",
	"addons/love/lua/libraries/graphics/volume_image.lua",
	"addons/love/lua/libraries/graphics/canvas.lua",
	"addons/love/lua/libraries/graphics/filter.lua",
	"addons/love/lua/libraries/graphics/text.lua",
	"addons/love/lua/libraries/graphics/sprite_batch.lua",
	"addons/love/lua/libraries/graphics/mesh.lua",
	"addons/love/lua/libraries/graphics/shader.lua",
	"addons/love/lua/libraries/graphics/stencil.lua",
	"addons/love/lua/libraries/graphics/draw.lua",
}
shared.Get(love)

for _, path in ipairs(env_loaded_modules) do
	line.LoadLoveLibrary(love, path)
end

for _, path in ipairs(post_installer_env_loaded_modules) do
	line.LoadLoveLibrary(love, path)
end

return love.graphics
