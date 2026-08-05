local utf8 = import("goluwa/string/utf8.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local codec = import("goluwa/codec.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local glyphs = library()
glyphs.font_cache = {}

local function get_contour_points(raw_points, ascent, inv_upem)
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
	local first_x, first_y
	local start_pt_idx = 1

	if raw_points[1].on_curve then
		first_x, first_y = raw_points[1].x * inv_upem, ascent - raw_points[1].y * inv_upem
		start_pt_idx = 2
	else
		if raw_points[count].on_curve then
			first_x, first_y = raw_points[count].x * inv_upem, ascent - raw_points[count].y * inv_upem
		else
			first_x, first_y = (raw_points[1].x + raw_points[count].x) * inv_upem / 2,
			(ascent - (raw_points[1].y + raw_points[count].y) * inv_upem / 2)
		end
	end

	local cur_x, cur_y = first_x, first_y
	add_pt(cur_x, cur_y)

	for k = 0, count - 1 do
		local idx = (start_pt_idx + k - 1) % count + 1
		local p = raw_points[idx]
		local px, py = p.x * inv_upem, ascent - p.y * inv_upem

		if p.on_curve then
			add_pt(px, py)
			cur_x, cur_y = px, py
		else
			local next_idx = idx % count + 1
			local next_p = raw_points[next_idx]
			local npx, npy = next_p.x * inv_upem, ascent - next_p.y * inv_upem
			local end_x, end_y

			if next_p.on_curve then
				end_x, end_y = npx, npy
			else
				end_x, end_y = (px + npx) / 2, (py + npy) / 2
			end

			for i = 1, 10 do
				local t = i / 10
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

local function resolve_glyph_data(font_obj, glyph_data)
	if not glyph_data then return nil end

	if not glyph_data.is_compound then return glyph_data end

	local all_points = {}
	local all_end_pts = {}

	for _, component in ipairs(glyph_data.components or {}) do
		local comp_data = resolve_glyph_data(font_obj, font_obj:GetGlyphData(font_obj, component.glyph_index))

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

local function build_glyph(font_obj, ascent, inv_upem, char_code)
	local glyph_index = font_obj:GetGlyphIndex(char_code)

	if not glyph_index or glyph_index == 0 then return nil end

	local metrics = font_obj:GetGlyphMetrics(glyph_index)
	local glyph_data = resolve_glyph_data(font_obj, font_obj:GetGlyphData(glyph_index))

	if not glyph_data or not glyph_data.points then
		return {
			x_advance = metrics.advance_width,
			lsb = metrics.lsb,
			glyph_data = glyph_data,
		}
	end

	local contours = {}
	local start_idx = 1

	for ci, end_idx in ipairs(glyph_data.end_pts_of_contours) do
		end_idx = end_idx + 1
		local raw_points = {}

		for i = start_idx, end_idx do
			table.insert(raw_points, glyph_data.points[i])
		end

		start_idx = end_idx + 1

		if #raw_points >= 2 then
			local flattened = get_contour_points(raw_points, ascent, inv_upem)

			if #flattened >= 6 then
				for _, contour in ipairs(math2d.SplitSelfIntersectingContour(flattened)) do
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

	local poly = nil

	if #unique_contours > 0 then
		local final_triangles = math2d.TriangulateContoursEvenOdd(unique_contours)

		if #final_triangles > 0 then
			poly = Polygon2D.FromTriangleCoordinates(final_triangles)
		end
	end

	return {
		x_advance = metrics.advance_width,
		lsb = metrics.lsb,
		glyph_data = glyph_data,
		poly = poly,
	}
end

function glyphs.GetGlyph(path, char_code)
	if type(char_code) == "string" then char_code = utf8.uint32(char_code) end

	if not char_code or char_code < 0 then return nil end

	local state = glyphs.font_cache[path]

	if not state then
		local font_obj = assert(codec.DecodeFile(path, "ttf"))
		local units_per_em = font_obj.units_per_em
		local ascent = font_obj.cap_height or font_obj.typo_ascent or (units_per_em * 0.7)
		state = {
			font = font_obj,
			units_per_em = units_per_em,
			ascent = ascent,
			glyphs_cache = {},
		}
		glyphs.font_cache[path] = state
	end

	if state.glyphs_cache[char_code] ~= nil then
		return state.glyphs_cache[char_code]
	end

	-- normalize coordinates to 0-1 range
	local inv_upem = 1.0 / state.units_per_em
	local g = build_glyph(state.font, state.ascent * inv_upem, inv_upem, char_code)

	if g then
		g.x_advance = g.x_advance * inv_upem
		g.lsb = g.lsb * inv_upem
	end

	state.glyphs_cache[char_code] = g
	return g
end

function glyphs.DrawGlyph(path, char_code, x, y, size)
	local glyph = glyphs.GetGlyph(path, char_code)

	if not glyph or not glyph.poly then return end

	render2d.state.runtime.pipeline_state.synced_pipeline = nil
	render2d.PushMatrix(x, y, size, size)
	glyph.poly:Draw()
	render2d.PopMatrix()
end

return glyphs
