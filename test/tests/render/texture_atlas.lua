local T = require("test.environment")
local TextureAtlas = require("render.texture_atlas")
local Texture = require("render.texture")
local render = require("render.render")

T.Test("Texture Atlas bin packing and management", function()
	render.Initialize({headless = true})
	local atlas = TextureAtlas.New(512, 512, "linear", "r8g8b8a8_unorm")
	atlas:SetPadding(2)
	T(atlas.width)["=="](512)
	T(atlas.height)["=="](512)
	-- Create some fake textures to insert
	local tex1 = Texture.New({width = 30, height = 30})
	local tex2 = Texture.New({width = 60, height = 20})
	atlas:Insert("id1", {w = 30, h = 30, texture = tex1})
	atlas:Insert("id2", {w = 60, h = 20, texture = tex2})
	-- Build the atlas
	atlas:Build()
	-- Verify UVs
	local uv1, w1, h1 = atlas:GetNormalizedUV("id1")
	T(w1)["=="](30)
	T(h1)["=="](30)
	T(#uv1)["=="](4)
	local uv2, w2, h2 = atlas:GetNormalizedUV("id2")
	T(w2)["=="](60)
	T(h2)["=="](20)
	-- Check that they don't overlap in the atlas
	-- We can't easily check actual pixel content in headless transfer-only mode without more effort,
	-- but we can check the calculated rects.
	local data1 = atlas.textures["id1"]
	local data2 = atlas.textures["id2"]

	local function rects_overlap(r1, r2)
		return r1.x < r2.x + r2.w and
			r1.x + r1.w > r2.x and
			r1.y < r2.y + r2.h and
			r1.y + r1.h > r2.y
	end

	local r1 = {x = data1.page_x, y = data1.page_y, w = data1.page_w, h = data1.page_h}
	local r2 = {x = data2.page_x, y = data2.page_y, w = data2.page_w, h = data2.page_h}
	T(rects_overlap(r1, r2))["=="](false)
	-- Test page overflow
	-- Insert a giant texture
	local giant = Texture.New({width = 1000, height = 1000})
	local ok, err = pcall(function()
		atlas:Insert("giant", {w = 1000, h = 1000, texture = giant})
		atlas:Build()
	end)
	T(ok)["=="](false)
	T(err:find("too big"))["~="](nil)
	-- Verify multi-page support
	local atlas2 = TextureAtlas.New(128, 128)
	atlas2:SetPadding(0)

	for i = 1, 10 do
		atlas2:Insert("item" .. i, {w = 64, h = 64, texture = Texture.New({width = 64, height = 64})})
	end

	atlas2:Build()
	-- 128x128 can hold 4 64x64 items.
	-- 10 items should require 3 pages (4+4+2).
	T(#atlas2:GetTextures())["=="](3)
	atlas:Remove()
	atlas2:Remove()
end)
