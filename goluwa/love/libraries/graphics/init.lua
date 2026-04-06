local love = ... or _G.love
local line = import("goluwa/love/line.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local env_loaded_modules = {
	"goluwa/love/libraries/graphics/frame.lua",
	"goluwa/love/libraries/graphics/transform.lua",
	"goluwa/love/libraries/graphics/state.lua",
	"goluwa/love/libraries/graphics/color.lua",
	"goluwa/love/libraries/graphics/points.lua",
	"goluwa/love/libraries/graphics/line_state.lua",
	"goluwa/love/libraries/graphics/info.lua",
	"goluwa/love/libraries/graphics/scissor.lua",
	"goluwa/love/libraries/graphics/shapes.lua",
	"goluwa/love/libraries/graphics/reset.lua",
}
local post_installer_env_loaded_modules = {
	"goluwa/love/libraries/graphics/quad.lua",
	"goluwa/love/libraries/graphics/image.lua",
	"goluwa/love/libraries/graphics/volume_image.lua",
	"goluwa/love/libraries/graphics/canvas.lua",
	"goluwa/love/libraries/graphics/filter.lua",
	"goluwa/love/libraries/graphics/text.lua",
	"goluwa/love/libraries/graphics/sprite_batch.lua",
	"goluwa/love/libraries/graphics/mesh.lua",
	"goluwa/love/libraries/graphics/shader.lua",
	"goluwa/love/libraries/graphics/stencil.lua",
	"goluwa/love/libraries/graphics/draw.lua",
}
shared.Get(love)

for _, path in ipairs(env_loaded_modules) do
	line.LoadLoveLibrary(love, path)
end

for _, path in ipairs(post_installer_env_loaded_modules) do
	line.LoadLoveLibrary(love, path)
end

return love.graphics
