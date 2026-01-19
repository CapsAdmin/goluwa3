local ffi = require("ffi")
local utf8 = require("utf8")
local render2d = require("render2d.render2d")
local Texture = require("render.texture")
local Framebuffer = require("render.framebuffer")
local Polygon2D = require("render2d.polygon_2d")
local Buffer = require("structs.buffer")
local codec = require("codec")
local gfx = require("render2d.gfx")
local math2d = require("render2d.math2d")
local prototype = require("prototype")
local META = prototype.CreateTemplate("font", "ttf")
META:GetSet("Path", nil)
META:GetSet("Size", 16, {callback = "UpdateScale"})

function META:UpdateScale()
	if self.font then
		self.scale = self.Size / self.font.units_per_em
		-- Use CapHeight for layout if available, otherwise heuristic 70% of EM or typo_ascent
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
	self.font = assert(codec.DecodeFile(path, "ttf"))
	self:UpdateScale()
	self.glyphs = {}
	return self
end

local function get_contour_points(self, glyph, raw_points)
	local flattened = {}

	local function add_pt(x, y)
		if #flattened >= 2 then
			if flattened[#flattened - 1] == x and flattened[#flattened] == y then
				return
			end
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

			-- Flatten quadratic bezier
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

local function is_point_in_polygon(x, y, points)
	local inside = false
	local n = #points / 2
	local j = n

	for i = 1, n do
		local xi, yi = points[(i - 1) * 2 + 1], points[(i - 1) * 2 + 2]
		local xj, yj = points[(j - 1) * 2 + 1], points[(j - 1) * 2 + 2]

		if ((yi > y) ~= (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi) then
			inside = not inside
		end

		j = i
	end

	return inside
end

-- Count how many times a ray from (x,y) going right crosses the polygon edges
-- Used for even-odd fill rule
local function count_polygon_crossings(x, y, points)
	local crossings = 0
	local n = #points / 2

	for i = 1, n do
		local x1, y1 = points[(i - 1) * 2 + 1], points[(i - 1) * 2 + 2]
		local j = i % n + 1
		local x2, y2 = points[(j - 1) * 2 + 1], points[(j - 1) * 2 + 2]

		if (y1 <= y and y2 > y) or (y2 <= y and y1 > y) then
			local t = (y - y1) / (y2 - y1)
			local ix = x1 + t * (x2 - x1)

			if x < ix then crossings = crossings + 1 end
		end
	end

	return crossings
end

-- Check if two line segments intersect and return intersection point
local function segment_intersection(x1, y1, x2, y2, x3, y3, x4, y4)
	local denom = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)

	if math.abs(denom) < 1e-10 then return nil end

	local t = ((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) / denom
	local u = -((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) / denom

	-- Check if intersection is strictly inside both segments (not at endpoints)
	if t > 0.001 and t < 0.999 and u > 0.001 and u < 0.999 then
		local ix = x1 + t * (x2 - x1)
		local iy = y1 + t * (y2 - y1)
		return ix, iy, t, u
	end

	return nil
end

-- Split a self-intersecting contour into multiple simple contours
local function split_self_intersecting(points)
	local n = #points / 2

	if n < 4 then return {points} end

	-- Find first self-intersection
	for i = 1, n do
		local i_next = i % n + 1
		local x1, y1 = points[(i - 1) * 2 + 1], points[(i - 1) * 2 + 2]
		local x2, y2 = points[(i_next - 1) * 2 + 1], points[(i_next - 1) * 2 + 2]

		-- Check against all non-adjacent edges
		for j = i + 2, n do
			local j_next = j % n + 1

			-- Skip if edges share a vertex
			if j_next == i then goto continue end

			local x3, y3 = points[(j - 1) * 2 + 1], points[(j - 1) * 2 + 2]
			local x4, y4 = points[(j_next - 1) * 2 + 1], points[(j_next - 1) * 2 + 2]
			local ix, iy = segment_intersection(x1, y1, x2, y2, x3, y3, x4, y4)

			if ix then
				-- Found intersection! Split into two contours
				-- Contour 1: vertices i+1 to j, plus intersection point
				-- Contour 2: vertices j+1 to i, plus intersection point
				local contour1 = {}
				local contour2 = {}
				-- First contour: from intersection, along edge i->i+1, to j, back to intersection
				table.insert(contour1, ix)
				table.insert(contour1, iy)

				for k = i_next, j do
					local idx = (k - 1) * 2 + 1
					table.insert(contour1, points[idx])
					table.insert(contour1, points[idx + 1])
				end

				-- Second contour: from intersection, along edge j->j+1, around to i, back to intersection
				table.insert(contour2, ix)
				table.insert(contour2, iy)

				for k = j_next, n do
					local idx = (k - 1) * 2 + 1
					table.insert(contour2, points[idx])
					table.insert(contour2, points[idx + 1])
				end

				for k = 1, i do
					local idx = (k - 1) * 2 + 1
					table.insert(contour2, points[idx])
					table.insert(contour2, points[idx + 1])
				end

				-- Recursively split the resulting contours (they might still self-intersect)
				local result = {}

				for _, c in ipairs(split_self_intersecting(contour1)) do
					table.insert(result, c)
				end

				for _, c in ipairs(split_self_intersecting(contour2)) do
					table.insert(result, c)
				end

				return result
			end

			::continue::
		end
	end

	-- No self-intersection found, return as-is
	return {points}
end

function META:DrawGlyph(glyph)
	-- Handle both raw glyph_data and full glyph object from GetGlyph
	if not glyph then return end

	if glyph.glyph_data then glyph = glyph.glyph_data end

	local debug_targets = {P = true, R = true, e = true, ["&"] = true, ["#"] = true}

	if glyph.poly then
		glyph.poly:Draw()
		return
	end

	if not glyph.points then return end

	local contours = {}
	local start_idx = 1
	local original_contour_count = #glyph.end_pts_of_contours

	for ci, end_idx in ipairs(glyph.end_pts_of_contours) do
		end_idx = end_idx + 1
		local raw_points = {}

		for i = start_idx, end_idx do
			table.insert(raw_points, glyph.points[i])
		end

		start_idx = end_idx + 1

		if #raw_points >= 2 then
			local flattened = get_contour_points(self, glyph, raw_points)

			if #flattened >= 6 then table.insert(contours, flattened) end
		end
	end

	-- Only apply self-intersection splitting for single-contour glyphs
	-- Multi-contour glyphs already have separate shell/hole contours
	local was_split = false
	local original_contour = nil

	if original_contour_count == 1 and #contours == 1 then
		original_contour = contours[1] -- Save for even-odd filtering
		local split_contours = split_self_intersecting(contours[1])

		if #split_contours > 1 then
			was_split = true
			contours = {}

			for _, c in ipairs(split_contours) do
				if #c >= 6 then table.insert(contours, c) end
			end
		end
	end

	-- Remove duplicate contours (can happen from splitting at same intersection point)
	local unique_contours = {}

	for _, c in ipairs(contours) do
		local dominated = false

		for _, existing in ipairs(unique_contours) do
			-- Check if first few points match (indicates duplicate)
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

	-- For split self-intersecting contours, use signed area to determine shell vs hole
	-- Then use the normal shell/hole bridging logic
	if was_split then
		-- Separate contours by signed area: positive = shell, negative = hole
		local split_shells = {}
		local split_holes = {}

		for _, c in ipairs(contours) do
			local area = math2d.GetPolygonArea(c)

			if area > 0 then
				table.insert(split_shells, {points = c, area = area})
			elseif area < 0 then
				table.insert(split_holes, {points = c, area = area})
			end
		end

		-- Sort shells by area (largest first)
		table.sort(split_shells, function(a, b)
			return a.area > b.area
		end)

		local final_triangles = {}

		-- For the largest shell, merge all holes into it
		if #split_shells > 0 then
			local main_shell = split_shells[1]
			local merged = main_shell.points

			-- Merge each hole into the shell
			for _, hole_info in ipairs(split_holes) do
				local hole = hole_info.points

				-- Reverse hole winding if needed
				if hole_info.area < 0 == (main_shell.area < 0) then
					hole = math2d.ReversePolygon(hole)
				end

				-- Find closest points between shell and hole
				local best_dist = math.huge
				local s_vertex_idx, h_vertex_idx = 1, 1

				for si = 1, #merged / 2 do
					for hi = 1, #hole / 2 do
						local si_coord = (si - 1) * 2 + 1
						local hi_coord = (hi - 1) * 2 + 1
						local dx = merged[si_coord] - hole[hi_coord]
						local dy = merged[si_coord + 1] - hole[hi_coord + 1]
						local d = dx * dx + dy * dy

						if d < best_dist then
							best_dist = d
							s_vertex_idx, h_vertex_idx = si, hi
						end
					end
				end

				-- Build merged polygon with bridge
				local new_points = {}
				local shell_count = #merged / 2
				local hole_count = #hole / 2

				for vi = 1, s_vertex_idx do
					local idx = (vi - 1) * 2 + 1
					table.insert(new_points, merged[idx])
					table.insert(new_points, merged[idx + 1])
				end

				for vi = 0, hole_count - 1 do
					local idx = ((h_vertex_idx - 1 + vi) % hole_count) * 2 + 1
					table.insert(new_points, hole[idx])
					table.insert(new_points, hole[idx + 1])
				end

				local h_coord = (h_vertex_idx - 1) * 2 + 1
				table.insert(new_points, hole[h_coord])
				table.insert(new_points, hole[h_coord + 1])
				local s_coord = (s_vertex_idx - 1) * 2 + 1
				table.insert(new_points, merged[s_coord])
				table.insert(new_points, merged[s_coord + 1])

				for vi = s_vertex_idx + 1, shell_count do
					local idx = (vi - 1) * 2 + 1
					table.insert(new_points, merged[idx])
					table.insert(new_points, merged[idx + 1])
				end

				merged = new_points
			end

			-- Triangulate the merged polygon
			local triangles = math2d.TriangulateCoordinates(merged)

			for _, tri in ipairs(triangles) do
				table.insert(final_triangles, tri)
			end

			-- Also triangulate any additional shells (smaller positive-area contours)
			for i = 2, #split_shells do
				local tris = math2d.TriangulateCoordinates(split_shells[i].points)

				for _, tri in ipairs(tris) do
					table.insert(final_triangles, tri)
				end
			end
		end

		if #final_triangles > 0 then
			render2d.SetTexture(gfx.white_texture)
			local poly = Polygon2D.New(#final_triangles * 3)
			poly:SetColor(1, 1, 1, 1)

			for tri_idx, tri in ipairs(final_triangles) do
				poly:SetTriangle(tri_idx, tri[1], tri[2], tri[3], tri[4], tri[5], tri[6])
			end

			glyph.poly = poly
			poly:Draw()
		end

		return
	end

	if #contours == 0 then return end

	-- Group contours into shells and holes based on area sign and nesting
	local contour_info = {}

	for i, c in ipairs(contours) do
		local area = math2d.GetPolygonArea(c)

		if math.abs(area) > 1e-12 then
			-- Use triangulation to get a reliable interior point
			local tx, ty
			local tris = math2d.TriangulateCoordinates(c)

			if #tris > 0 then
				-- Use centroid of first triangle - guaranteed to be inside
				local t = tris[1]
				tx, ty = (t[1] + t[3] + t[5]) / 3, (t[2] + t[4] + t[6]) / 3
			else
				-- Fallback: use first vertex if triangulation fails
				tx, ty = c[1], c[2]
			end

			-- Debug: show bounding box for R
			if debug_char == "R" then
				local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge

				for vi = 1, #c / 2 do
					local vx, vy = c[(vi - 1) * 2 + 1], c[(vi - 1) * 2 + 2]
					minx, miny = math.min(minx, vx), math.min(miny, vy)
					maxx, maxy = math.max(maxx, vx), math.max(maxy, vy)
				end
			end

			table.insert(
				contour_info,
				{
					points = c,
					area = area,
					test_pt = {tx, ty},
					vertices = #c / 2,
				}
			)
		end
	end

	table.sort(contour_info, function(a, b)
		return math.abs(a.area) > math.abs(b.area)
	end)

	local shells = {}

	for i, info in ipairs(contour_info) do
		local nesting = 0

		-- Check nesting against ALL other contours, not just previous ones in sorted list
		for j, other in ipairs(contour_info) do
			if i ~= j and math.abs(other.area) > math.abs(info.area) then
				local inside = is_point_in_polygon(info.test_pt[1], info.test_pt[2], other.points)

				if inside then nesting = nesting + 1 end
			end
		end

		-- Even nesting = shell, Odd nesting = hole
		-- But a shell nested in a hole should become a solid part (even-odd fill rule)
		local is_shell = (nesting % 2 == 0)

		if is_shell then
			table.insert(shells, {points = info.points, area = info.area, holes = {}, nesting = nesting})
		else
			local best_parent = nil

			-- Find the parent shell (must have nesting = this nesting - 1)
			for j = #shells, 1, -1 do
				if
					shells[j].nesting == nesting - 1 and
					is_point_in_polygon(info.test_pt[1], info.test_pt[2], shells[j].points)
				then
					best_parent = shells[j]

					break
				end
			end

			if best_parent then
				local hole_points = info.points

				-- Reverse the hole to have opposite winding from the shell
				if (info.area > 0) == (best_parent.area > 0) then
					hole_points = math2d.ReversePolygon(hole_points)
				end

				table.insert(best_parent.holes, hole_points)
			end
		end
	end

	local final_triangles = {}

	for shell_idx, shell_info in ipairs(shells) do
		if #shell_info.holes == 0 then
			-- No holes detected, just triangulate the shell directly
			local triangles = math2d.TriangulateCoordinates(shell_info.points)

			for _, tri in ipairs(triangles) do
				table.insert(final_triangles, tri)
			end
		else
			-- Has holes - need to merge them properly
			for _, hole in ipairs(shell_info.holes) do
				-- Find closest points between shell and hole
				local merged = shell_info.points
				local best_dist = math.huge
				local s_vertex_idx, h_vertex_idx = 1, 1

				for si = 1, #merged / 2 do
					for hi = 1, #hole / 2 do
						local si_coord = (si - 1) * 2 + 1
						local hi_coord = (hi - 1) * 2 + 1
						local dx = merged[si_coord] - hole[hi_coord]
						local dy = merged[si_coord + 1] - hole[hi_coord + 1]
						local d = dx * dx + dy * dy

						if d < best_dist then
							best_dist = d
							s_vertex_idx, h_vertex_idx = si, hi
						end
					end
				end

				-- Build merged polygon with proper bridge
				local new_points = {}
				local shell_count = #merged / 2
				local hole_count = #hole / 2

				-- Add shell vertices from 1 to connection point (inclusive)
				for vi = 1, s_vertex_idx do
					local idx = (vi - 1) * 2 + 1
					table.insert(new_points, merged[idx])
					table.insert(new_points, merged[idx + 1])
				end

				-- Add all hole vertices starting from connection, going around the entire hole
				for vi = 0, hole_count - 1 do
					local idx = ((h_vertex_idx - 1 + vi) % hole_count) * 2 + 1
					table.insert(new_points, hole[idx])
					table.insert(new_points, hole[idx + 1])
				end

				-- Bridge back: return to hole connection point, then back to shell connection
				local h_coord = (h_vertex_idx - 1) * 2 + 1
				table.insert(new_points, hole[h_coord])
				table.insert(new_points, hole[h_coord + 1])
				-- Add shell connection point again (bridge back)
				local s_coord = (s_vertex_idx - 1) * 2 + 1
				table.insert(new_points, merged[s_coord])
				table.insert(new_points, merged[s_coord + 1])

				-- Continue with remaining shell vertices after connection
				for vi = s_vertex_idx + 1, shell_count do
					local idx = (vi - 1) * 2 + 1
					table.insert(new_points, merged[idx])
					table.insert(new_points, merged[idx + 1])
				end

				merged = new_points
				shell_info.points = merged
			end

			local triangles = math2d.TriangulateCoordinates(shell_info.points)

			for _, tri in ipairs(triangles) do
				table.insert(final_triangles, tri)
			end
		end
	end

	if #final_triangles == 0 then return end

	render2d.SetTexture(gfx.white_texture)
	local poly = Polygon2D.New(#final_triangles * 3)
	poly:SetColor(1, 1, 1, 1)

	for tri_idx, tri in ipairs(final_triangles) do
		poly:SetTriangle(tri_idx, tri[1], tri[2], tri[3], tri[4], tri[5], tri[6])
	end

	glyph.poly = poly
	poly:Draw()
end

function META:ResolveGlyphData(glyph_data)
	if not glyph_data then return nil end

	if not glyph_data.is_compound then return glyph_data end

	local all_points = {}
	local all_end_pts = {}

	for _, component in ipairs(glyph_data.components or {}) do
		local comp_data = self:ResolveGlyphData(self.font:GetGlyphData(component.glyph_index))

		if comp_data and comp_data.points then
			local m = component.matrix
			local offset = #all_points

			for _, p in ipairs(comp_data.points) do
				-- Apply 2x2 matrix and translation
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

function META:GetGlyph(char_code)
	if self.glyphs[char_code] then return self.glyphs[char_code] end

	local glyph_index = self.font:GetGlyphIndex(char_code)

	if not glyph_index then return nil end

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
		g.w = math.ceil(g.x_max - g.x_min) + 2
		g.h = math.ceil(g.y_max - g.y_min) + 2
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
		local char_code = string.byte(char)
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

function META:DrawText(str, x, y, spacing, align_x, align_y)
	if align_x or align_y then
		local w, h = self:GetTextSize(str)

		if type(align_x) == "number" then
			x = x - (w * align_x)
		elseif align_x == "center" then
			x = x - (w / 2)
		elseif align_x == "right" then
			x = x - w
		end

		if type(align_y) == "number" then
			y = y - (h * align_y)
		elseif align_y == "baseline" then
			y = y - self:GetAscent()
		elseif align_y == "center" then
			y = y - (h / 2)
		elseif align_y == "bottom" then
			y = y - h
		end
	end

	self:DrawString(str, x, y, spacing)
end

function META:DrawString(str, x, y, spacing)
	-- TTF fonts can be drawn directly but it's slower than using rasterized_font
	-- For best performance, wrap in rasterized_font for texture atlas rendering
	spacing = spacing or 0
	local X, Y = 0, 0

	for i, char in ipairs(utf8.to_list(str)) do
		local char_code = string.byte(char)
		local glyph = self:GetGlyph(char_code)

		if char == "\n" then
			X = 0
			Y = Y + self.Size
		elseif char == "\t" then
			X = X + self.Size * 4
		elseif glyph and glyph.glyph_data then
			-- Debug: pass character info to DrawGlyph
			glyph.glyph_data.debug_char = char
			-- Draw glyph using Polygon2D
			render2d.PushMatrix()
			render2d.Translate(x + X, y + Y)
			self:DrawGlyph(glyph.glyph_data)
			render2d.PopMatrix()
			X = X + glyph.x_advance + spacing
		elseif char == " " then
			X = X + self.Size / 2
		end
	end
end

return META:Register()
