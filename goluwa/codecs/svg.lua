local xml = import("goluwa/codecs/xml.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
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

local function flatten_arc(contour, x1, y1, rx, ry, x_axis_rotation, large_arc_flag, sweep_flag, x2, y2, min_steps)
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

local function finalize_contour(contours, contour)
	if not contour or #contour < 6 then return end

	local split = math2d.SplitSelfIntersectingContour(contour)

	for _, points in ipairs(split) do
		if #points >= 6 then contours[#contours + 1] = points end
	end
end

local function parse_path_contours(data, curve_steps)
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

			finalize_contour(contours, contour)
			contour = {x, y}
			start_x = x
			start_y = y
			current_cmd = relative and "l" or "L"
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		elseif lower == "z" then
			if contour and (#contour < 2 or contour[#contour - 1] ~= start_x or contour[#contour] ~= start_y) then
				contour[#contour + 1] = start_x
				contour[#contour + 1] = start_y
			end

			finalize_contour(contours, contour)
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

			flatten_arc(contour, x, y, rx, ry, x_axis_rotation, large_arc_flag, sweep_flag, nx, ny, curve_steps)
			x = nx
			y = ny
			last_qx, last_qy = nil, nil
			last_cx, last_cy = nil, nil
		else
			error("unsupported SVG path command: " .. tostring(cmd))
		end
	end

	finalize_contour(contours, contour)
	return contours
end

local function find_root(children)
	for i = 1, children.n do
		local child = children[i]
		if child.tag == "svg" then return child end
	end

	return nil
end

local function collect_paths(node, out)
	if node.tag == "path" then out[#out + 1] = node end

	for i = 1, node.children.n do
		collect_paths(node.children[i], out)
	end
end

function svg.Decode(data, options)
	options = options or {}
	local document = xml.Decode(data)
	local root = assert(find_root(document.children), "SVG root node not found")
	local view_box = parse_view_box(root.attrs.viewBox)
	local width = parse_length(root.attrs.width, view_box and view_box.w or 0)
	local height = parse_length(root.attrs.height, view_box and view_box.h or 0)
	local path_nodes = {}
	collect_paths(root, path_nodes)
	local contours = {}
	local curve_steps = options.curve_steps or 12

	for _, node in ipairs(path_nodes) do
		local fill = node.attrs.fill

		if fill ~= "none" and node.attrs.d then
			local path_contours = parse_path_contours(node.attrs.d, curve_steps)

			for _, contour in ipairs(path_contours) do
				contours[#contours + 1] = contour
			end
		end
	end

	local triangles = math2d.TriangulateContoursEvenOdd(contours)

	return {
		width = width,
		height = height,
		view_box = view_box or {x = 0, y = 0, w = width, h = height},
		contours = contours,
		triangles = triangles,
	}
end

function svg.CreatePolygon2D(data, options)
	local decoded = type(data) == "table" and data or svg.Decode(data, options)
	local poly = Polygon2D.FromTriangleCoordinates(decoded.triangles)
	return poly, decoded
end

return svg