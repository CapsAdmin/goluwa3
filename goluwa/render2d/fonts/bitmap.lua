local render2d = import("goluwa/render2d/render2d.lua")
local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("bitmap_font")
META.Base = import("goluwa/render2d/fonts/base.lua")

function META.New(font_path)
	local self = META:CreateObject()
	self:SetFontPath(font_path)
	self.chars = {}
	self.rebuild = false
	return self
end

function META:Rebuild() end

function META:RebuildFromScratch() end

function META:OnPaddingChanged() end

function META:OnRemove() end

local function glyph_fn(self, data, X, Y, entries)
	entries[#entries + 1] = {data.glyph_data, X + data.bitmap_left, Y + data.bitmap_top}
end

function META:DrawString(str, x, y, spacing, extra_space_advance)
	local entries = self:BuildLayout(tostring(str), spacing or self.Spacing, extra_space_advance or 0, glyph_fn)
	local last_texture
	render2d.PushMargin(0)

	for _, entry in ipairs(entries) do
		local g = entry[1]

		if g.texture ~= last_texture then
			render2d.SetTexture(g.texture)
			last_texture = g.texture
		end

		render2d.SetColorUV(g.u1, g.v2, g.u2, g.v1)
		render2d.DrawRectf(math.floor(x + entry[2] + 0.5), math.floor(y + entry[3] + 0.5), g.w, g.h)
	end

	render2d.PopMargin()

	if last_texture then
		render2d.SetColorUV(0, 0, 1, 1)
		render2d.SetTexture(nil)
	end
end

return META:Register()
