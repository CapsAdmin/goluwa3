local T = import("test/environment.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")

T.Test2D("texture bindless index reuse with __gc", function()
	local pipeline = render2d.pipeline
	T(pipeline)["~="](nil)
	local start_index = pipeline.pipeline.next_texture_index
	collectgarbage("stop")
	local textures = {}

	for i = 1, 10 do
		local tex = Texture.New{width = 1, height = 1}
		local index = pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	T(pipeline.pipeline.next_texture_index)["=="](start_index + 10)

	for _, tex in ipairs(textures) do
		if tex.__gc then tex:__gc() else tex:Remove() end
	end

	textures = {}

	for i = 1, 10 do
		local tex = Texture.New{width = 1, height = 1}
		local index = pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	T(pipeline.pipeline.next_texture_index)["=="](start_index + 10)
	local one_more = Texture.New{width = 1, height = 1}
	pipeline:GetTextureIndex(one_more)
	T(pipeline.pipeline.next_texture_index)["=="](start_index + 11)
	collectgarbage("restart")
end)
