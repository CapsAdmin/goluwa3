-- Every icon is a stroked line drawing on a 24 unit grid, the theme wraps the body in an svg with
-- fill none and stroke currentColor and decides the stroke width, caps and joins (IconStyle).
-- Strokes only meet at points they share, they must not cross anywhere else and neighbouring strokes
-- keep about 3.5 units between their center lines, see math2d.StrokePolylines. Filled shapes are the
-- exception, they ignore the weight.
local ARC_STEP = 11.25
local icons = {}
local categories = {}
local category_by_name = {}

local function f(n)
	return (("%.3f"):format(n):gsub("%.?0+$", ""))
end

local function polar(cx, cy, rx, ry, degrees)
	local a = math.rad(degrees)
	return cx + math.cos(a) * rx, cy + math.sin(a) * ry
end

-- degrees run clockwise from the positive x axis, the first point is a line to unless move is set
local function arc(cx, cy, rx, ry, from, to, move)
	local steps = math.max(1, math.ceil(math.abs(to - from) / ARC_STEP - 1e-9))
	local out = {}

	for i = 0, steps do
		local x, y = polar(cx, cy, rx, ry, from + (to - from) * i / steps)
		out[#out + 1] = (i == 0 and move and "M" or "L") .. f(x) .. " " .. f(y)
	end

	return table.concat(out)
end

local function ring(cx, cy, r, degrees)
	degrees = degrees or 0
	return arc(cx, cy, r, r, degrees, degrees + 360, true) .. "Z"
end

local function polygon(cx, cy, r, count, degrees)
	local out = {}

	for i = 0, count - 1 do
		local x, y = polar(cx, cy, r, r, degrees + i * 360 / count)
		out[#out + 1] = (i == 0 and "M" or "L") .. f(x) .. " " .. f(y)
	end

	return table.concat(out) .. "Z"
end

local function star(cx, cy, r_out, r_in, points)
	local out = {}

	for i = 0, points * 2 - 1 do
		local r = i % 2 == 0 and r_out or r_in
		local x, y = polar(cx, cy, r, r, -90 + i * 180 / points)
		out[#out + 1] = (i == 0 and "M" or "L") .. f(x) .. " " .. f(y)
	end

	return table.concat(out) .. "Z"
end

local function gear(cx, cy, r_out, r_in, teeth)
	local out = {}
	local pitch = 360 / teeth

	for i = 0, teeth - 1 do
		local a = i * pitch

		for _, point in ipairs{{a - pitch * 0.23, r_in}, {a - pitch * 0.15, r_out}, {a + pitch * 0.15, r_out}, {a + pitch * 0.23, r_in}} do
			local x, y = polar(cx, cy, point[2], point[2], point[1])
			out[#out + 1] = (#out == 0 and "M" or "L") .. f(x) .. " " .. f(y)
		end
	end

	return table.concat(out) .. "Z"
end

-- a circle with a point outside of it, the lines from the point touch the circle
local function teardrop(cx, cy, r, tx, ty)
	local phi = math.deg(math.atan2(ty - cy, tx - cx))
	local beta = math.deg(math.acos(r / math.sqrt((tx - cx) ^ 2 + (ty - cy) ^ 2)))
	return "M" .. f(tx) .. " " .. f(ty) .. arc(cx, cy, r, r, phi + beta, phi - beta + 360) .. "Z"
end

-- two lines ending in x, y that look back along degrees
local function head(x, y, degrees, size)
	local x1, y1 = polar(x, y, size, size, degrees + 180 - 45)
	local x2, y2 = polar(x, y, size, size, degrees + 180 + 45)
	return "M" .. f(x1) .. " " .. f(y1) .. "L" .. f(x) .. " " .. f(y) .. "L" .. f(x2) .. " " .. f(y2)
end

local function path(...)
	local out = {}

	for i = 1, select("#", ...) do
		out[i] = "<path d=\"" .. select(i, ...) .. "\"/>"
	end

	return table.concat(out)
end

local function dot(cx, cy, r)
	return "<circle cx=\"" .. f(cx) .. "\" cy=\"" .. f(cy) .. "\" r=\"" .. f(r) .. "\" fill=\"currentColor\" stroke=\"none\"/>"
end

local function add(category_name, name, body)
	assert(not icons[name], name)
	icons[name] = body
	local category = category_by_name[category_name]

	if not category then
		category = {Name = category_name, Icons = {}}
		category_by_name[category_name] = category
		categories[#categories + 1] = category
	end

	category.Icons[#category.Icons + 1] = name
end

add("Arrows", "chevron_right", path("M8.5 5L15.5 12L8.5 19"))
add("Arrows", "chevron_left", path("M15.5 5L8.5 12L15.5 19"))
add("Arrows", "chevron_down", path("M5 8.5L12 15.5L19 8.5"))
add("Arrows", "chevron_up", path("M5 15.5L12 8.5L19 15.5"))
add("Arrows", "arrow_right", path("M4 12H20M14 6L20 12L14 18"))
add("Arrows", "arrow_left", path("M20 12H4M10 6L4 12L10 18"))
add("Arrows", "arrow_up", path("M12 20V4M6 10L12 4L18 10"))
add("Arrows", "arrow_down", path("M12 4V20M6 14L12 20L18 14"))
add("Basic", "plus", path("M12 5V12 19M5 12H12 19"))
add("Basic", "minus", path("M5 12H19"))
add("Basic", "check", path("M5 12.5L10 17.5L19 7"))
add("Basic", "close", path("M6 6L12 12L18 18M18 6L12 12L6 18"))
add("Basic", "more_horizontal", dot(6, 12, 1.8) .. dot(12, 12, 1.8) .. dot(18, 12, 1.8))
add("Basic", "more_vertical", dot(12, 6, 1.8) .. dot(12, 12, 1.8) .. dot(12, 18, 1.8))

do
	local x, y = polar(10.5, 10.5, 6.5, 6.5, 45)
	add("Basic", "search", path(ring(10.5, 10.5, 6.5, 45), "M" .. f(x) .. " " .. f(y) .. "L20.5 20.5"))
end

add("Basic", "menu", path("M4 7H20M4 12H20M4 17H20"))
add("Basic", "filter", path("M4 5H20L14 12.5V19L10 17V12.5Z"))
add("Window", "minimize", path("M6 18H18"))
add("Window", "maximize", "<rect x=\"5\" y=\"5\" width=\"14\" height=\"14\"/>")
add("Window", "restore", "<rect x=\"4\" y=\"9\" width=\"11\" height=\"11\"/>" .. path("M9 5H20V16"))
add("Actions", "copy", "<rect x=\"9\" y=\"9\" width=\"11\" height=\"11\" rx=\"2\"/>" .. path("M5 14V5H14"))
add("Actions", "paste", path("M9 3H15V5H18V21H6V5H9Z"))

do
	local x, y = polar(12, 12, 8, 8, -75)
	add("Actions", "reset", path(arc(12, 12, 8, 8, 225, -75, true), head(x, y, -165, 4.5)))
	x, y = polar(12, 12, 8, 8, 255)
	add("Actions", "refresh", path(arc(12, 12, 8, 8, -45, 255, true), head(x, y, 345, 4.5)))
end

add("Actions", "trash", path("M5 7H7 9.5 14.5 17 19", "M9.5 7V3.5H14.5V7", "M7 7V18.5L8.5 20.5H15.5L17 18.5V7"))
add("Actions", "edit", path("M4 20L5 15L13 7L16 4L20 8L17 11L9 19Z", "M13 7L17 11"))
add("Actions", "save", path("M4 4H8 15 16.5L20.5 8V20H17 8 4Z", "M8 4V9H15V4", "M8 20V14H17V20"))
add("Actions", "upload", path("M12 15V4M7 9L12 4L17 9M4 15V20H20V15"))
add("Actions", "download", path("M12 4V15M7 10L12 15L17 10M4 15V20H20V15"))
add("Actions", "expand", path("M4 9V4H9M20 9V4H15M4 15V20H9M20 15V20H15"))
add("Files", "folder", path("M3.5 5.5H9L11 8H20.5V19H3.5Z"))
add("Files", "folder_open", path("M3.5 16V5.5H9L11 8H18.5", "M6.5 19.5L8.5 12.5H21.5L19.5 19.5Z"))
add("Files", "file", path("M4.5 2.5H13.5L19.5 8.5V21.5H4.5Z", "M13.5 2.5V8.5H19.5"))
add("Files", "image", "<rect x=\"3.5\" y=\"4.5\" width=\"17\" height=\"15\" rx=\"2\"/>" .. path("M7 16.5L11 11.5L15 16.5") .. dot(16.5, 8.5, 1.6))
add("Files", "code", path("M9 7L4 12L9 17M15 7L20 12L15 17"))
add("Objects", "cube", path("M12 3L20.5 7.5V16.5L12 21L3.5 16.5V7.5Z", "M3.5 7.5L12 12L20.5 7.5M12 12V21"))
add("Objects", "sphere", path(ring(12, 12, 9, 180), arc(12, 12, 9, 3.5, 180, 0, true)))
add("Objects", "material", path(ring(12, 12, 9), arc(12, 12, 5, 5, 200, 260, true)))
add("Objects", "layers", path("M12 3.5L20.5 8L12 12.5L3.5 8Z", "M3.5 12.5L12 17L20.5 12.5", "M3.5 16.5L12 21L20.5 16.5"))
add("Objects", "layout", path("M3.5 4.5H20.5V9.5 19.5H3.5V9.5Z", "M3.5 9.5H20.5"))
add("Objects", "component", path(polygon(12, 12, 9, 6, -90)))
add("Objects", "entity", path(ring(12, 12, 8)) .. dot(12, 12, 2.2))

do
	local ticks = {}

	for _, degrees in ipairs{0, 90, 180, 270} do
		local x1, y1 = polar(12, 12, 6.5, 6.5, degrees)
		local x2, y2 = polar(12, 12, 10, 10, degrees)
		ticks[#ticks + 1] = "M" .. f(x1) .. " " .. f(y1) .. "L" .. f(x2) .. " " .. f(y2)
	end

	add("Objects", "target", path(ring(12, 12, 6.5), table.concat(ticks)) .. dot(12, 12, 1.6))
end

add("Objects", "physics", path(ring(10, 9.5, 4.5), "M4 20.5L20.5 15"))
add(
	"Scene",
	"light",
	path(arc(12, 10, 6, 6, 125, 415, true) .. "L15 17.5L9 17.5Z", "M10 21H14")
)

do
	local rays = {}

	for i = 0, 7 do
		local x1, y1 = polar(12, 12, 7.5, 7.5, i * 45)
		local x2, y2 = polar(12, 12, 10, 10, i * 45)
		rays[#rays + 1] = "M" .. f(x1) .. " " .. f(y1) .. "L" .. f(x2) .. " " .. f(y2)
	end

	add("Scene", "sun", path(ring(12, 12, 4), table.concat(rays)))
end

add("Scene", "camera", path("M3.5 7H8L9.5 4.5H14.5L16 7H20.5V20.5H3.5Z", ring(12, 13.5, 3)))
add("Scene", "water", path(teardrop(12, 14.5, 6.5, 12, 3.5)))
add("Scene", "spawn", path("M6 4H18L15 8.5L18 13H6Z", "M6 13V21"))
add("Scene", "place", path(teardrop(12, 9.5, 6.5, 12, 21)) .. dot(12, 9.5, 2.2))
add("Scene", "world", path(ring(12, 12, 9, 180), "M3 12H8 16 21", arc(12, 12, 4, 5.5, 270, 630, true) .. "Z"))
add(
	"Scene",
	"move",
	path(
		"M12 3.5V12 20.5M3.5 12H12 20.5",
		"M9 6.5L12 3.5L15 6.5M9 17.5L12 20.5L15 17.5M6.5 9L3.5 12L6.5 15M17.5 9L20.5 12L17.5 15"
	)
)
add("Scene", "rotate", icons.refresh)
add("Scene", "scale", path("M5 19L19 5", "M12.5 5H19V11.5", "M5 12.5V19H11.5"))
add("Scene", "transform", path(ring(12, 12, 9), "M12 8V12 16M8 12H12 16"))
add("Scene", "play", path("M8 4.5L19 12L8 19.5Z"))
add(
	"Interface",
	"eye",
	path("M3 12C6 3.3 18 3.3 21 12C18 20.7 6 20.7 3 12Z", ring(12, 12, 2.6))
)
add("Interface", "lock", path("M5 11H8 16 19V21H5Z", "M8 11V8" .. arc(12, 8, 4, 4, 180, 360) .. "L16 11"))
add("Interface", "settings", path(gear(12, 12, 10, 7.5, 6), ring(12, 12, 3.2)))
add("Interface", "info", path(ring(12, 12, 9), "M12 11V17") .. dot(12, 7.5, 1.4))
add("Interface", "warning", path("M12 3.5L21.5 20.5H2.5Z", "M12 9.5V14") .. dot(12, 17, 1.2))
add("Interface", "error", path(ring(12, 12, 9), "M12 7V13") .. dot(12, 16.3, 1.3))
add("Interface", "star", path(star(12, 12.5, 9.5, 4.3, 5)))
add("Interface", "power", path(arc(12, 13.5, 7.5, 7.5, 300, 600, true), "M12 3.5V12"))

do
	local dots = {}

	for _, degrees in ipairs{90, 210, 330} do
		local x, y = polar(12, 12, 4.5, 4.5, degrees)
		dots[#dots + 1] = dot(x, y, 1.6)
	end

	add("Interface", "palette", path(ring(12, 12, 9)) .. table.concat(dots))
end

add(
	"Interface",
	"grid",
	path(
		"M3.5 3.5H10V10H3.5Z",
		"M14 3.5H20.5V10H14Z",
		"M3.5 14H10V20.5H3.5Z",
		"M14 14H20.5V20.5H14Z"
	)
)
add("Interface", "tree", path("M3.5 5.5H6 20.5M6 5.5V12 18.5M6 12H20.5M6 18.5H20.5"))
return {Icons = icons, Categories = categories}
