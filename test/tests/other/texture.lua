local T = import("test/environment.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")

T.Test2D("texture bindless index reuse after release", function()
	local pipeline = render2d.pipeline
	T(pipeline)["~="](nil)
	local slot = pipeline.pipeline.bindless.textures
	local start_index = slot.next_index
	local textures = {}

	for i = 1, 10 do
		local tex = Texture.New{width = 1, height = 1}
		pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	T(slot.next_index)["=="](start_index + 10)

	for _, tex in ipairs(textures) do
		tex:Remove()
	end

	system.SetFrameNumber(system.GetFrameNumber() + 100)
	textures = {}

	for i = 1, 10 do
		local tex = Texture.New{width = 1, height = 1}
		pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	T(slot.next_index)["=="](start_index + 10)
	local one_more = Texture.New{width = 1, height = 1}
	pipeline:GetTextureIndex(one_more)
	T(slot.next_index)["=="](start_index + 11)
end)
