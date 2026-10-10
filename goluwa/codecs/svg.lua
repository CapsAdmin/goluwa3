local xml = import("goluwa/codecs/xml.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local svg = library()
svg.file_extensions = {"svg"}

local function parse_length(value, fallback)
	if type(value) ~= "string" then return fallback end

	local number = tonumber(value:match("^[%s]*([%+%-]?[%d%.]+)%s*(px)?%s*$"))
	return number or fallback
end

local function parse_view_box(value)
	if type(value) ~= "string" then return nil end

	local numbers = {}

	for number in value:gmatch("[%+%-]?[%d%.]+") do
		numbers[#numbers + 1] = tonumber(number)
	end

	if #numbers ~= 4 then return nil end

	return {
		x = numbers[1],
		y = numbers[2],
		w = numbers[3],
		h = numbers[4],
	}
end

local function tokenize_path(data)
	local tokens = {}
	local i = 1

	while i <= #data do
		local char = data:sub(i, i)

		if char:match("[%s,]") then
			i = i + 1
		elseif char:match("[A-Za-z]") then
			tokens[#tokens + 1] = char
			i = i + 1
		else
			local rest = data:sub(i)
			local number_str = rest:match("^([%+%-]?%d+%.?%d*[eE][%+%-]?%d+)") or
				rest:match("^([%+%-]?%.%d+[eE][%+%-]?%d+)") or
				rest:match("^([%+%-]?%d+%.?%d*)") or
				rest:match("^([%+%-]?%.%d+)")
			assert(number_str, "invalid SVG number")
			tokens[#tokens + 1] = assert(tonumber(number_str), "invalid SVG number")
			i = i + #number_str
		end
	end

	return tokens
end

local function vector_angle(ux, uy, vx, vy)
	local dot = ux * vx + uy * vy
	local det = ux * vy - uy * vx
	return math.atan2(det, dot)
end

local function flatten_arc(
	contour,
	x1,
	y1,
	rx,
	ry,
	x_axis_rotation,
	large_arc_flag,
	sweep_flag,
	x2,
	y2,
	min_steps
)
	rx = math.abs(rx)
	ry = math.abs(ry)

	if rx < 1e-12 or ry < 1e-12 then
		contour[#contour + 1] = x2
		contour[#contour + 1] = y2
		return
	end

	local phi = math.rad(x_axis_rotation % 360)
	local cos_phi = math.cos(phi)
	local sin_phi = math.sin(phi)
	local dx2 = (x1 - x2) / 2
	local dy2 = (y1 - y2) / 2
	local x1p = cos_phi * dx2 + sin_phi * dy2
	local y1p = -sin_phi * dx2 + cos_phi * dy2
	local lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)

	if lambda > 1 then
		local scale = math.sqrt(lambda)
		rx = rx * scale
		ry = ry * scale
	end

	local rx2 = rx * rx
	local ry2 = ry * ry
	local x1p2 = x1p * x1p
	local y1p2 = y1p * y1p
	local numerator = rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2
	local denominator = rx2 * y1p2 + ry2 * x1p2
	local factor = 0

	if denominator > 1e-12 then
		factor = math.sqrt(math.max(0, numerator / denominator))
	end

	if (large_arc_flag ~= 0) == (sweep_flag ~= 0) then factor = -factor end

	local cxp = factor * ((rx * y1p) / ry)
	local cyp = factor * (-(ry * x1p) / rx)
	local cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2
	local cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2
	local ux = (x1p - cxp) / rx
	local uy = (y1p - cyp) / ry
	local vx = (-x1p - cxp) / rx
	local vy = (-y1p - cyp) / ry
	local theta1 = vector_angle(1, 0, ux, uy)
	local delta_theta = vector_angle(ux, uy, vx, vy)

	if sweep_flag == 0 and delta_theta > 0 then
		delta_theta = delta_theta - math.pi * 2
	elseif sweep_flag ~= 0 and delta_theta < 0 then
		delta_theta = delta_theta + math.pi * 2
	end

	local steps = math.max(min_steps or 8, math.ceil(math.abs(delta_theta) / (math.pi / 8)))

	for i = 1, steps do
		local theta = theta1 + delta_theta * (i / steps)
		local cos_theta = math.cos(theta)
		local sin_theta = math.sin(theta)
		contour[#contour + 1] = cx + cos_phi * rx * cos_theta - sin_phi * ry * sin_theta
		contour[#contour + 1] = cy + sin_phi * rx * cos_theta + cos_phi * ry * sin_theta
	end
end

local function flatten_quadratic(contour, x0, y0, cx, cy, x1, y1, steps)
	for i = 1, steps do
		local t = i / steps
		local mt = 1 - t
		contour[#contour + 1] = mt * mt * x0 + 2 * mt * t * cx + t * t * x1
		contour[#contour + 1] = mt * mt * y0 + 2 * mt * t * cy + t * t * y1
	end
end

local function flatten_cubic(contour, x0, y0, cx1, cy1, cx2, cy2, x1, y1, steps)
	for i = 1, steps do
		local t = i / steps
		local mt = 1 - t
		contour[#contour + 1] = mt * mt * mt * x0 + 3 * mt * mt * t * cx1 + 3 * mt * t * t * cx2 + t * t * t * x1
		contour[#contour + 1] = mt * mt * mt * y0 + 3 * mt * mt * t * cy1 + 3 * mt * t * t * cy2 + t * t * t * y1
	end
end

local function finalize_contour(contours, contour, raw)
	if raw then
		if contour and #contour >= 4 then contours[#contours + 1] = contour end

		return
	end

	if not contour or #contour < 6 then return end

	local split = math2d.SplitSelfIntersectingContour(contour)

	for _, points in ipairs(split) do
		if #points >= 6 then contours[#contours + 1] = points end
	end
end

local function parse_path_contours(data, curve_steps, raw)
	local tokens = tokenize_path(data)
	local contours = {}
	local current_cmd
	local index = 1
	local x, y = 0, 0
	local start_x, start_y = 0, 0
	local contour = nil
	local last_qx, last_qy = nil, nil
	local last_cx, last_cy = nil, nil

	local function read_number()
		local value = tokens[index]
		assert(type(value) == "number", "expected SVG path number")
		index = index + 1
		return value
	end

	local function ensure_contour()
		if not contour then
			contour = {x, y}
			start_x = x
			start_y = y
		end
	end

	while index <= #tokens do
		local token = tokens[index]

		if type(token) == "string" then
			current_cmd = token
			index = index + 1
		elseif not current_cmd then
			error("SVG path must start with a command")
		end

		local cmd = current_cmd
		local relative = cmd:lower() == cmd
		local lower = cmd:lower()

		if lower == "m" then
			local nx = read_number()
			local ny = read_number()

			if relative then
				x = x + nx
				y = y + ny
			else
				x = nx
				y = ny
			end

			finalize_contour(contours, contour, raw)
			contour = {x, y}
			start_x = x
			start_y = y
			current_cmd = relative and "l" or "L"
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		elseif lower == "z" then
			if
				contour and
				(
					#contour < 2 or
					contour[#contour - 1] ~= start_x or
					contour[#contour] ~= start_y
				)
			then
				contour[#contour + 1] = start_x
				contour[#contour + 1] = start_y
			end

			finalize_contour(contours, contour, raw)
			contour = nil
			x = start_x
			y = start_y
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
			current_cmd = nil
		elseif lower == "l" then
			ensure_contour()
			local nx = read_number()
			local ny = read_number()

			if relative then
				x = x + nx
				y = y + ny
			else
				x = nx
				y = ny
			end

			contour[#contour + 1] = x
			contour[#contour + 1] = y
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		elseif lower == "h" then
			ensure_contour()
			local nx = read_number()
			x = relative and (x + nx) or nx
			contour[#contour + 1] = x
			contour[#contour + 1] = y
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		elseif lower == "v" then
			ensure_contour()
			local ny = read_number()
			y = relative and (y + ny) or ny
			contour[#contour + 1] = x
			contour[#contour + 1] = y
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		elseif lower == "q" then
			ensure_contour()
			local cx = read_number()
			local cy = read_number()
			local nx = read_number()
			local ny = read_number()

			if relative then
				cx = x + cx
				cy = y + cy
				nx = x + nx
				ny = y + ny
			end

			flatten_quadratic(contour, x, y, cx, cy, nx, ny, curve_steps)
			x = nx
			y = ny
			last_qx, last_qy = cx, cy
			last_cx, last_cy = nil, nil
		elseif lower == "t" then
			ensure_contour()
			local cx = last_qx and (2 * x - last_qx) or x
			local cy = last_qy and (2 * y - last_qy) or y
			local nx = read_number()
			local ny = read_number()

			if relative then
				nx = x + nx
				ny = y + ny
			end

			flatten_quadratic(contour, x, y, cx, cy, nx, ny, curve_steps)
			x = nx
			y = ny
			last_qx, last_qy = cx, cy
			last_cx, last_cy = nil, nil
		elseif lower == "c" then
			ensure_contour()
			local cx1 = read_number()
			local cy1 = read_number()
			local cx2 = read_number()
			local cy2 = read_number()
			local nx = read_number()
			local ny = read_number()

			if relative then
				cx1 = x + cx1
				cy1 = y + cy1
				cx2 = x + cx2
				cy2 = y + cy2
				nx = x + nx
				ny = y + ny
			end

			flatten_cubic(contour, x, y, cx1, cy1, cx2, cy2, nx, ny, curve_steps)
			x = nx
			y = ny
			last_qx, last_qy = nil, nil
			last_cx, last_cy = cx2, cy2
		elseif lower == "s" then
			ensure_contour()
			local cx1 = last_cx and (2 * x - last_cx) or x
			local cy1 = last_cy and (2 * y - last_cy) or y
			local cx2 = read_number()
			local cy2 = read_number()
			local nx = read_number()
			local ny = read_number()

			if relative then
				cx2 = x + cx2
				cy2 = y + cy2
				nx = x + nx
				ny = y + ny
			end

			flatten_cubic(contour, x, y, cx1, cy1, cx2, cy2, nx, ny, curve_steps)
			x = nx
			y = ny
			last_qx, last_qy = nil, nil
			last_cx, last_cy = cx2, cy2
		elseif lower == "a" then
			ensure_contour()
			local rx = read_number()
			local ry = read_number()
			local x_axis_rotation = read_number()
			local large_arc_flag = read_number()
			local sweep_flag = read_number()
			local nx = read_number()
			local ny = read_number()

			if relative then
				nx = x + nx
				ny = y + ny
			end

			flatten_arc(
				contour,
				x,
				y,
				rx,
				ry,
				x_axis_rotation,
				large_arc_flag,
				sweep_flag,
				nx,
				ny,
				curve_steps
			)
			x = nx
			y = ny
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		else
			error("unsupported SVG path command: " .. tostring(cmd))
		end
	end

	finalize_contour(contours, contour, raw)
	return contours
end

local function find_root(children)
	for i = 1, children.n do
		local child = children[i]

		if child.tag == "svg" then return child end
	end

	return nil
end

local function number_attr(attrs, name)
	return tonumber(attrs[name]) or 0
end

local function shape_to_path(node)
	local attrs = node.attrs
	local tag = node.tag

	if tag == "path" then return attrs.d end

	if tag == "line" then
		return string.format(
			"M%f %fL%f %f",
			number_attr(attrs, "x1"),
			number_attr(attrs, "y1"),
			number_attr(attrs, "x2"),
			number_attr(attrs, "y2")
		)
	end

	if tag == "polyline" or tag == "polygon" then
		local numbers = {}

		for number in (attrs.points or ""):gmatch("[%+%-]?[%d%.]+") do
			numbers[#numbers + 1] = tonumber(number)
		end

		if #numbers < 4 then return nil end

		local parts = {string.format("M%f %f", numbers[1], numbers[2])}

		for i = 3, #numbers - 1, 2 do
			parts[#parts + 1] = string.format("L%f %f", numbers[i], numbers[i + 1])
		end

		if tag == "polygon" then parts[#parts + 1] = "Z" end

		return table.concat(parts)
	end

	if tag == "circle" or tag == "ellipse" then
		local cx, cy = number_attr(attrs, "cx"), number_attr(attrs, "cy")
		local rx = number_attr(attrs, tag == "circle" and "r" or "rx")
		local ry = tag == "circle" and rx or number_attr(attrs, "ry")

		if rx <= 0 or ry <= 0 then return nil end

		return string.format(
			"M%f %fA%f %f 0 1 0 %f %fA%f %f 0 1 0 %f %fZ",
			cx - rx,
			cy,
			rx,
			ry,
			cx + rx,
			cy,
			rx,
			ry,
			cx - rx,
			cy
		)
	end

	if tag == "rect" then
		local x, y = number_attr(attrs, "x"), number_attr(attrs, "y")
		local w, h = number_attr(attrs, "width"), number_attr(attrs, "height")
		local rx, ry = number_attr(attrs, "rx"), number_attr(attrs, "ry")

		if w <= 0 or h <= 0 then return nil end

		if attrs.rx and not attrs.ry then ry = rx elseif attrs.ry and not attrs.rx then rx = ry end

		rx = math.min(rx, w / 2)
		ry = math.min(ry, h / 2)

		if rx > 0 and ry > 0 then
			return string.format(
				"M%f %fH%fA%f %f 0 0 1 %f %fV%fA%f %f 0 0 1 %f %fH%fA%f %f 0 0 1 %f %fV%fA%f %f 0 0 1 %f %fZ",
				x + rx,
				y,
				x + w - rx,
				rx,
				ry,
				x + w,
				y + ry,
				y + h - ry,
				rx,
				ry,
				x + w - rx,
				y + h,
				x + rx,
				rx,
				ry,
				x,
				y + h - ry,
				y + ry,
				rx,
				ry,
				x + rx,
				y
			)
		end

		return string.format("M%f %fH%fV%fH%fZ", x, y, x + w, y + h, x)
	end

	return nil
end

local function collect_shapes(node, parent_paint, out)
	local attrs = node.attrs
	local paint = {
		fill = attrs.fill or parent_paint.fill,
		stroke = attrs.stroke or parent_paint.stroke,
		stroke_width = tonumber(attrs["stroke-width"]) or parent_paint.stroke_width,
		line_cap = attrs["stroke-linecap"] or parent_paint.line_cap,
		line_join = attrs["stroke-linejoin"] or parent_paint.line_join,
		miter_limit = tonumber(attrs["stroke-miterlimit"]) or parent_paint.miter_limit,
	}
	local d = shape_to_path(node)

	if d then out[#out + 1] = {d = d, paint = paint} end

	for i = 1, node.children.n do
		collect_shapes(node.children[i], paint, out)
	end
end

-- style = {StrokeWidth, LineCap, LineJoin, MiterLimit} replaces what the document says about strokes.
-- A shape is filled or stroked, a stroked shape only gets a fill if it asks for one and that fill
-- must not overlap its stroke, the distance field is built from non overlapping contours.
-- Strokes of all shapes that share their stroke settings are one line graph, see math2d.StrokePolylines
function svg.Decode(data, curve_steps, style)
	curve_steps = curve_steps or 12
	style = style or {}
	local document = xml.Decode(data)
	local root = assert(find_root(document.children), "SVG root node not found")
	local view_box = parse_view_box(root.attrs.viewBox)
	local width = parse_length(root.attrs.width, view_box and view_box.w or 0)
	local height = parse_length(root.attrs.height, view_box and view_box.h or 0)
	local shapes = {}
	collect_shapes(root, {}, shapes)
	local contours = {}
	local stroke_groups = {}
	local stroke_group_list = {}

	for _, shape in ipairs(shapes) do
		local paint = shape.paint
		local stroked = paint.stroke ~= nil and paint.stroke ~= "none"

		if paint.fill ~= "none" and (paint.fill ~= nil or not stroked) then
			for _, contour in ipairs(parse_path_contours(shape.d, curve_steps)) do
				contours[#contours + 1] = contour
			end
		end

		if stroked then
			local stroke_width = style.StrokeWidth or paint.stroke_width or 1
			local line_cap = style.LineCap or paint.line_cap or "butt"
			local line_join = style.LineJoin or paint.line_join or "miter"
			local miter_limit = style.MiterLimit or paint.miter_limit or 4
			local key = stroke_width .. "/" .. line_cap .. "/" .. line_join .. "/" .. miter_limit
			local group = stroke_groups[key]

			if not group then
				group = {
					width = stroke_width,
					cap = line_cap,
					join = line_join,
					miter_limit = miter_limit,
					polylines = {},
				}
				stroke_groups[key] = group
				stroke_group_list[#stroke_group_list + 1] = group
			end

			for _, polyline in ipairs(parse_path_contours(shape.d, curve_steps, true)) do
				group.polylines[#group.polylines + 1] = polyline
			end
		end
	end

	for _, group in ipairs(stroke_group_list) do
		local outlines = math2d.StrokePolylines(group.polylines, group.width, group.cap, group.join, group.miter_limit)

		for _, outline in ipairs(outlines) do
			contours[#contours + 1] = outline
		end
	end

	return {
		width = width,
		height = height,
		view_box = view_box or {x = 0, y = 0, w = width, h = height},
		contours = contours,
	}
end

return svg
