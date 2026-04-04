local love = ... or _G.love
local ctx = assert(loadfile("goluwa/love/libraries/graphics/shared.lua"))(love)
local modules = {
	"frame",
	"filter",
	"quad",
	"transform",
	"state",
	"color",
	"points",
	"text",
	"line_state",
	"canvas",
	"image",
	"volume_image",
	"stencil",
	"draw",
	"shader",
	"info",
	"scissor",
	"shapes",
	"mesh",
	"sprite_batch",
	"reset",
}

for _, module_name in ipairs(modules) do
	assert(loadfile("goluwa/love/libraries/graphics/" .. module_name .. ".lua"))()(ctx)
end

return love.graphics
