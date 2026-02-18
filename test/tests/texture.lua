local T = require("test.environment")
local render2d = require("render2d.render2d")
local Texture = require("render.texture")

T.Test("texture bindless index reuse with __gc", function()
	local render = require("render.render")
	render.Initialize({headless = true})
	render2d.Initialize()
	local pipeline = render2d.pipeline
	T(pipeline)["~="](nil)
	local start_index = pipeline.pipeline.next_texture_index
	collectgarbage("stop")
	local textures = {}

	for i = 1, 10 do
		local tex = Texture.New({width = 1, height = 1})
		local index = pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	T(pipeline.pipeline.next_texture_index)["=="](start_index + 10)

	for _, tex in ipairs(textures) do
		-- The user specifically asked to call :__gc() manually
		-- In this engine, __gc is set to remove_callback which calls :Remove()
		if tex.__gc then tex:__gc() else tex:Remove() end
	end

	textures = {}

	-- Indices should now be in the free list.
	-- Let's verify we can reuse them.
	for i = 1, 10 do
		local tex = Texture.New({width = 1, height = 1})
		local index = pipeline:GetTextureIndex(tex)
		table.insert(textures, tex)
	end

	-- next_texture_index should NOT have increased because we reused from free list
	T(pipeline.pipeline.next_texture_index)["=="](start_index + 10)
	-- If we add one more, it should increase
	local one_more = Texture.New({width = 1, height = 1})
	pipeline:GetTextureIndex(one_more)
	T(pipeline.pipeline.next_texture_index)["=="](start_index + 11)
	collectgarbage("restart")
end)
