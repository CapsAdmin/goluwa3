local M = library()
local CHANNEL_R, CHANNEL_G, CHANNEL_B = 1, 2, 4
local CHANNEL_CYCLE = {CHANNEL_R + CHANNEL_G, CHANNEL_G + CHANNEL_B, CHANNEL_B + CHANNEL_R} -- yellow, cyan, magenta
local CORNER_ANGLE_THRESHOLD = math.rad(3) -- msdfgen default-ish
local function get_raw_contours(glyph_data)
	-- glyph_data = glyph.glyph_data.glyph_data (the innermost one with points/end_pts_of_contours)
	local points = glyph_data.points
	local ends = glyph_data.end_pts_of_contours
	local contours = {}
	local start_idx = 1

	for _, end_idx_0 in ipairs(ends) do
		local end_idx = end_idx_0 + 1
		local contour = {}

		for i = start_idx, end_idx do
			local p = points[i]
			contour[#contour + 1] = {x = p.x, y = p.y, on_curve = p.on_curve}
		end

		contours[#contours + 1] = contour
		start_idx = end_idx + 1
	end

	return contours
end

local function lerp(a, b, t)
	return {x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t}
end

local function flatten_quad(p0, c, p1, out, steps)
	steps = steps or 8

	for i = 1, steps do
		local t = i / steps
		local a = lerp(p0, c, t)
		local b = lerp(c, p1, t)
		local pt = lerp(a, b, t)
		out[#out + 1] = pt
	end
end

local function flatten_contour(raw_contour, curve_steps)
	local n = #raw_contour

	if n == 0 then return {} end

	-- normalize starting point to an on-curve point if one exists
	local start = 1

	for i = 1, n do
		if raw_contour[i].on_curve then
			start = i

			break
		end
	end

	local ordered = {}

	for i = 0, n - 1 do
		ordered[#ordered + 1] = raw_contour[((start - 1 + i) % n) + 1]
	end

	if not ordered[1].on_curve then
		local mid = lerp(ordered[n], ordered[1], 0.5)
		table.insert(ordered, 1, {x = mid.x, y = mid.y, on_curve = true})
		n = n + 1
	end

	local poly = {}
	poly[#poly + 1] = {x = ordered[1].x, y = ordered[1].y}
	local i = 2

	while i <= n + 1 do
		local cur = ordered[((i - 1) % n) + 1]

		if cur.on_curve then
			poly[#poly + 1] = {x = cur.x, y = cur.y}
			i = i + 1
		else
			local nxt = ordered[(i % n) + 1]
			local end_pt

			if nxt.on_curve then
				end_pt = {x = nxt.x, y = nxt.y}
				i = i + 2
			else
				end_pt = lerp(cur, nxt, 0.5) -- implied on-curve point
				i = i + 1
			end

			local prev = poly[#poly]
			flatten_quad(prev, cur, end_pt, poly, curve_steps)
		end
	end

	-- drop duplicate closing point if flatten produced it
	local first, last = poly[1], poly[#poly]

	if math.abs(first.x - last.x) < 1e-6 and math.abs(first.y - last.y) < 1e-6 then
		poly[#poly] = nil
	end

	return poly
end

local function normalize(v)
	local len = math.sqrt(v.x * v.x + v.y * v.y)

	if len < 1e-9 then return {x = 0, y = 0} end

	return {x = v.x / len, y = v.y / len}
end

local function angle_between(a, b)
	local cross = a.x * b.y - a.y * b.x
	local dot = a.x * b.x + a.y * b.y
	return math.atan2(math.abs(cross), dot)
end

local function color_polyline(poly)
	local n = #poly

	if n < 2 then return {} end

	local dirs = {}

	for i = 1, n do
		local a = poly[i]
		local b = poly[(i % n) + 1]
		dirs[i] = normalize{x = b.x - a.x, y = b.y - a.y}
	end

	local corner_before = {} -- corner_before[i] == true means edge i starts right after a corner
	for i = 1, n do
		local prev_dir = dirs[((i - 2) % n) + 1]
		local this_dir = dirs[i]

		if angle_between(prev_dir, this_dir) > CORNER_ANGLE_THRESHOLD then
			corner_before[i] = true
		end
	end

	local any_corner = false

	for i = 1, n do
		if corner_before[i] then
			any_corner = true

			break
		end
	end

	local edges = {}
	local color_idx = 1

	if not any_corner then
		for i = 1, n do
			local a = poly[i]
			local b = poly[(i % n) + 1]
			edges[#edges + 1] = {p0 = a, p1 = b, channel = CHANNEL_CYCLE[1]}
		end

		return edges
	end

	for i = 1, n do
		if corner_before[i] then color_idx = color_idx % 3 + 1 end

		local a = poly[i]
		local b = poly[(i % n) + 1]
		edges[#edges + 1] = {p0 = a, p1 = b, channel = CHANNEL_CYCLE[color_idx]}
	end

	return edges
end

function M.ExtractEdges(glyph, opts)
	local raw_gd = glyph.glyph_data.glyph_data
	local contours = get_raw_contours(raw_gd)
	local scale = opts.scale
	local super_scale = opts.super_scale
	local pad = opts.pad
	local bitmap_left = glyph.bitmap_left
	local bitmap_top = glyph.bitmap_top

	local function to_texel_space(p)
		-- 1) raw font units -> pixel space (matches bitmap_left/top/w/h)
		local px = p.x * scale
		local py = p.y * scale
		-- 2) same transform DrawGlyph's render2d stack applies before rasterizing mask_fb:
		--    Translate(pad) * Scale(super_scale) * Translate(-bitmap_left, -bitmap_top)
		local tx = (px - bitmap_left) * super_scale + pad
		local ty = -(py - opts.bearing_y) * super_scale + pad
		-- NOTE: verify sign/orientation of ty against your mask texture (see caveat above);
		-- flip with `ty = -(py - bitmap_top) * super_scale + pad` if it comes out upside down.
		return tx, ty
	end

	local out = {}

	for _, raw_contour in ipairs(contours) do
		local poly = flatten_contour(raw_contour, opts.curve_steps or 8)
		local colored = color_polyline(poly)

		for _, e in ipairs(colored) do
			local x0, y0 = to_texel_space(e.p0)
			local x1, y1 = to_texel_space(e.p1)
			out[#out + 1] = {x0, y0, x1, y1, e.channel}
		end
	end

	return out
end

return M
