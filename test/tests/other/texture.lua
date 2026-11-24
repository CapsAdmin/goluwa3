local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")

T.Test("texture bindless index reuse after release", function()
	local pipeline
	local slot
	local start_index

	test_render.Draw2D(function()
		pipeline = render2d.pipeline
		T(pipeline)["~="](nil)
		slot = pipeline.pipeline.bindless.textures
		start_index = slot.next_index
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
	end)

	render.GetDevice():WaitIdle()
	system.SetFrameNumber(system.GetFrameNumber() + 100)

	test_render.Draw2D(function()
		for i = 1, 10 do
			pipeline:GetTextureIndex(Texture.New{width = 1, height = 1})
		end

		T(slot.next_index)["=="](start_index + 10)
		pipeline:GetTextureIndex(Texture.New{width = 1, height = 1})
		T(slot.next_index)["=="](start_index + 11)
	end)
end)
