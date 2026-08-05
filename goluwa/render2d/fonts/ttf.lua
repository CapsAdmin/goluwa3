local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
local utf8 = import("goluwa/string/utf8.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local codec = import("goluwa/codec.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local objects = import("goluwa/objects/objects.lua")
local FontBase = import("goluwa/render2d/fonts/base.lua")
local META = objects.CreateTemplate("font_ttf")
META.Base = FontBase
META:GetSet("Size", 16, {callback = "UpdateScale"})
META.scale_override = nil

function META:__copy()
	return self
end

function META:SetScale(v)
	self.scale_override = v
end

function META:GetScale()
	if self.scale_override then return self.scale_override end

	return Vec2(self.scale)
end

function META:UpdateScale()
	if self.font then
		if self.scale_override then
			self.scale = self.scale_override.x or self.scale_override
		else
			self.scale = self.Size / self.font.units_per_em
		end

		self.ascent = (
				self.font.cap_height or
				self.font.typo_ascent or
				(
					self.font.units_per_em * 0.7
				)
			) * self.scale
		self.descent = (self.font.win_descent or self.font.descent or (self.font.units_per_em * 0.2)) * self.scale
	end

	self.glyphs = {}
end

function META.New(path)
	assert(path)
	local self = META:CreateObject()
	self:SetPath(path)
	return self
end

function META:SetPath(path)
	self.Path = path
	self.font = assert(codec.DecodeFile(path, "ttf"))
	self:UpdateScale()
	self.glyphs = {}
	return self
end

local function get_contour_points(self, glyph, raw_points)
	local flattened = {}

	local function add_pt(x, y)
		if #flattened >= 2 then
			if flattened[#flattened - 1] == x and flattened[#flattened] == y then return end
		end

		if #flattened >= 6 then
			if flattened[1] == x and flattened[2] == y then return end
		end

		table.insert(flattened, x)
		table.insert(flattened, y)
	end

	local count = #raw_points

	local function get_xy(p)
		return p.x * self.scale, self.ascent - p.y * self.scale
	end

	local first_x, first_y
	local start_pt_idx = 1

	if raw_points[1].on_curve then
		first_x, first_y = get_xy(raw_points[1])
		start_pt_idx = 2
	else
		if raw_points[count].on_curve then
			first_x, first_y = get_xy(raw_points[count])
		else
			local x1, y1 = get_xy(raw_points[1])
			local x2, y2 = get_xy(raw_points[count])
			first_x, first_y = (x1 + x2) / 2, (y1 + y2) / 2
		end
	end

	local cur_x, cur_y = first_x, first_y
	add_pt(cur_x, cur_y)

	for k = 0, count - 1 do
		local idx = (start_pt_idx + k - 1) % count + 1
		local p = raw_points[idx]
		local px, py = get_xy(p)

		if p.on_curve then
			add_pt(px, py)
			cur_x, cur_y = px, py
		else
			local next_idx = idx % count + 1
			local next_p = raw_points[next_idx]
			local npx, npy = get_xy(next_p)
			local end_x, end_y

			if next_p.on_curve then
				end_x, end_y = npx, npy
			else
				end_x, end_y = (px + npx) / 2, (py + npy) / 2
			end

			local steps = 10

			for i = 1, steps do
				local t = i / steps
				local mt = 1 - t
				local bx = mt * mt * cur_x + 2 * mt * t * px + t * t * end_x
				local by = mt * mt * cur_y + 2 * mt * t * py + t * t * end_y
				add_pt(bx, by)
			end

			cur_x, cur_y = end_x, end_y
		end
	end

	return flattened
end

function META:DrawGlyph(glyph)
	if not glyph then return end

	if glyph.glyph_data then glyph = glyph.glyph_data end

	if glyph.poly then
		glyph.poly:Draw()
		return
	end

	if not glyph.points then return end

	local contours = {}
	local start_idx = 1

	for ci, end_idx in ipairs(glyph.end_pts_of_contours) do
		end_idx = end_idx + 1
		local raw_points = {}

		for i = start_idx, end_idx do
			table.insert(raw_points, glyph.points[i])
		end

		start_idx = end_idx + 1

		if #raw_points >= 2 then
			local flattened = get_contour_points(self, glyph, raw_points)

			if #flattened >= 6 then
				local split_contours = math2d.SplitSelfIntersectingContour(flattened)

				for _, contour in ipairs(split_contours) do
					if #contour >= 6 then table.insert(contours, contour) end
				end
			end
		end
	end

	local unique_contours = {}

	for _, c in ipairs(contours) do
		local dominated = false

		for _, existing in ipairs(unique_contours) do
			if
				#c == #existing and
				math.abs(c[1] - existing[1]) < 0.01 and
				math.abs(c[2] - existing[2]) < 0.01
			then
				dominated = true

				break
			end
		end

		if not dominated then table.insert(unique_contours, c) end
	end

	contours = unique_contours

	if #contours == 0 then return end

	local final_triangles = math2d.TriangulateContoursEvenOdd(contours)

	if #final_triangles == 0 then return end

	render2d.SetTexture(nil)
	local poly = Polygon2D.FromTriangleCoordinates(final_triangles)
	poly:SetColor(1, 1, 1, 1)
	glyph.poly = poly
	poly:Draw()
end

function META:ResolveGlyphData(glyph_data)
	if not glyph_data then return nil end

	if not glyph_data.is_compound then return glyph_data end

	local all_points = {}
	local all_end_pts = {}

	for _, component in ipairs(glyph_data.components or {}) do
		local comp_data = self:ResolveGlyphData(self.font:GetGlyphData(self.font, component.glyph_index))

		if comp_data and comp_data.points then
			local m = component.matrix
			local offset = #all_points

			for _, p in ipairs(comp_data.points) do
				local x = p.x * m[1] + p.y * m[3] + m[5]
				local y = p.x * m[2] + p.y * m[4] + m[6]
				table.insert(all_points, {x = x, y = y, on_curve = p.on_curve})
			end

			for _, end_pt in ipairs(comp_data.end_pts_of_contours) do
				table.insert(all_end_pts, end_pt + offset)
			end
		end
	end

	glyph_data.points = all_points
	glyph_data.end_pts_of_contours = all_end_pts
	glyph_data.is_compound = false
	return glyph_data
end

function META:GetAscent()
	return self.ascent
end

function META:GetDescent()
	return self.descent
end

function META:GetLineHeight()
	return self.Size
end

function META:GetGlyph(char_code)
	if type(char_code) == "string" then char_code = utf8.uint32(char_code) end

	if not char_code or char_code < 0 then return nil end

	if self.glyphs[char_code] then return self.glyphs[char_code] end

	local glyph_index = self.font:GetGlyphIndex(char_code)

	if not glyph_index or glyph_index == 0 then return nil end

	local metrics = self.font:GetGlyphMetrics(glyph_index)
	local glyph_data = self:ResolveGlyphData(self.font:GetGlyphData(glyph_index))
	local g = {
		x_advance = metrics.advance_width * self.scale,
		lsb = metrics.lsb * self.scale,
		w = 0,
		h = 0,
		x_min = 0,
		x_max = 0,
		y_min = 0,
		y_max = 0,
		bearing_x = 0,
		bearing_y = 0,
		bitmap_left = 0,
		bitmap_top = 0,
		buffer = nil,
		flip_y = false,
		glyph_data = glyph_data,
	}

	if glyph_data then
		g.x_min = glyph_data.x_min * self.scale
		g.x_max = glyph_data.x_max * self.scale
		g.y_min = glyph_data.y_min * self.scale
		g.y_max = glyph_data.y_max * self.scale
		g.w = math.ceil(g.x_max - g.x_min)
		g.h = math.ceil(g.y_max - g.y_min)
		g.bearing_x = g.x_min
		g.bearing_y = g.y_max
		g.bitmap_left = g.x_min
		g.bitmap_top = (self.ascent - g.y_max)
	end

	self.glyphs[char_code] = g
	return g
end

function META:GetTextSize(str)
	str = tostring(str)
	local X, Y = 0, self:GetAscent()
	local max_x = 0

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local glyph = self:GetGlyph(char_code)

		if char == "\n" then
			Y = Y + self.Size
			max_x = math.max(max_x, X)
			X = 0
		elseif char == "\t" then
			X = X + self.Size * 4
		elseif glyph then
			X = X + glyph.x_advance
		elseif char == " " then
			X = X + self.Size / 2
		end
	end

	if max_x ~= 0 then X = max_x end

	return X, Y
end

function META:DrawString(str, x, y, spacing, extra_space_advance)
	spacing = spacing or 0
	extra_space_advance = extra_space_advance or 0
	local X, Y = 0, 0

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = utf8.uint32(char)
		local glyph = self:GetGlyph(char_code)

		if char == "\n" then
			X = 0
			Y = Y + self.Size
		elseif char == "\t" then
			X = X + self.Size * 4
		elseif glyph and glyph.glyph_data then
			glyph.glyph_data.debug_char = char
			render2d.PushMatrix()
			render2d.Translate(x + X, y + Y)
			self:DrawGlyph(glyph.glyph_data)
			render2d.PopMatrix()
			X = X + glyph.x_advance + spacing
		elseif char == " " then
			X = X + self.Size / 2 + extra_space_advance
		end
	end
end

return META:Register()
