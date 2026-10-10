local T = import("test/environment.lua")
local svg = import("goluwa/codecs/svg.lua")
local math2d = import("goluwa/render2d/math2d.lua")

local function triangle_area_sum(triangles)
	local total = 0

	for i = 1, #triangles, 6 do
		total = total + math.abs(
				math2d.GetPolygonArea{
					triangles[i + 0],
					triangles[i + 1],
					triangles[i + 2],
					triangles[i + 3],
					triangles[i + 4],
					triangles[i + 5],
				}
			)
	end

	return total
end

T.Test("svg decode sample icon to polygon", function()
	local decoded = svg.Decode([[<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><path fill="currentColor" d="M10 20v-6h4v6h5v-8h3L12 3L2 12h3v8z"/></svg>]])
	T(decoded.view_box.x)["=="](0)
	T(decoded.view_box.y)["=="](0)
	T(decoded.view_box.w)["=="](24)
	T(decoded.view_box.h)["=="](24)
	T(decoded.width)["=="](24)
	T(decoded.height)["=="](24)
	T(#decoded.contours)["=="](1)
	local triangles = math2d.TriangulateContoursEvenOdd(decoded.contours)
	T(#triangles)[">"](0)
	T(triangle_area_sum(triangles))[">"](0)
	T(triangle_area_sum(triangles))["~"](178)
end)

T.Test("svg decode merges hole contours with even odd fill", function()
	local decoded = svg.Decode([[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
			<path fill="currentColor" d="M0 0H10V10H0Z M3 3H7V7H3Z"/>
		</svg>
	]])
	T(#decoded.contours)["=="](2)
	local triangles = math2d.TriangulateContoursEvenOdd(decoded.contours)
	T(#triangles)[">"](0)
	T(triangle_area_sum(triangles))["~"](84)
end)

T.Test("svg decode flattens quadratic and cubic curves", function()
	local decoded = svg.Decode(
		[[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
			<path fill="currentColor" d="M0 10 Q5 0 10 10 C12 14 16 14 20 10 L20 20 L0 20 Z"/>
		</svg>
	]],
		8
	)
	T(#decoded.contours)["=="](1)
	T(#decoded.contours[1])[">"](20)
	local triangles = math2d.TriangulateContoursEvenOdd(decoded.contours)
	T(#triangles)[">"](0)
	T(triangle_area_sum(triangles))[">"](0)
end)

T.Test("svg decode accepts compact decimal numbers", function()
	local decoded = svg.Decode([[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
			<path fill="currentColor" d="M1.5.5L9.5.5L9.5 9.5L.5 9.5Z"/>
		</svg>
	]])
	T(#decoded.contours)["=="](1)
	local triangles = math2d.TriangulateContoursEvenOdd(decoded.contours)
	T(#triangles)[">"](0)
	T(triangle_area_sum(triangles))[">"](0)
end)

T.Test("svg decode flattens arc commands", function()
	local decoded = svg.Decode(
		[[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
			<path fill="currentColor" d="M12 2 A10 10 0 1 1 11.999 2 L12 12 Z"/>
		</svg>
	]],
		8
	)
	T(#decoded.contours)["=="](1)
	T(#decoded.contours[1])[">"](20)
	local triangles = math2d.TriangulateContoursEvenOdd(decoded.contours)
	T(#triangles)[">"](0)
	T(triangle_area_sum(triangles))[">"](0)
end)

local function contour_area(contour)
	return math.abs(math2d.GetPolygonArea(contour))
end

local function stroked(attributes, body)
	return (
		[[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" %s>%s</svg>]]
	):format(attributes, body)
end

T.Test("svg decode strokes a line into one outline", function()
	local decoded = svg.Decode(stroked("stroke-width=\"2\"", "<path d=\"M4 12H20\"/>"))
	T(#decoded.contours)["=="](1)
	T(contour_area(decoded.contours[1]))["~"](32, 0.001)
end)

T.Test("svg decode style replaces the stroke settings of the document", function()
	local decoded = svg.Decode(
		stroked("stroke-width=\"2\"", "<path d=\"M4 12H20\"/>"),
		nil,
		{StrokeWidth = 4, LineCap = "square"}
	)
	T(#decoded.contours)["=="](1)
	T(contour_area(decoded.contours[1]))["~"](80, 0.001)
end)

T.Test("svg decode joins strokes that share a point", function()
	local decoded = svg.Decode(stroked("stroke-width=\"2\"", "<path d=\"M12 5V12 19M5 12H12 19\"/>"))
	T(#decoded.contours)["=="](1)
	T(contour_area(decoded.contours[1]))["~"](52, 0.001)
end)

T.Test("svg decode stroke joins", function()
	local source = stroked("stroke-width=\"2\"", "<path d=\"M2 2H12V12\"/>")
	T(contour_area(svg.Decode(source).contours[1]))["~"](40, 0.001)
	T(contour_area(svg.Decode(source, nil, {LineJoin = "bevel"}).contours[1]))["~"](39.5, 0.001)
	local round = contour_area(svg.Decode(source, nil, {LineJoin = "round"}).contours[1])
	T(round)[">"](39.5)
	T(round)["<"](40)
end)

T.Test("svg decode strokes a closed shape into an outer and an inner outline", function()
	local decoded = svg.Decode(
		stroked("stroke-width=\"2\" stroke-linejoin=\"round\"", "<circle cx=\"12\" cy=\"12\" r=\"6\"/>")
	)
	T(#decoded.contours)["=="](2)
	local outer = contour_area(decoded.contours[1])
	local inner = contour_area(decoded.contours[2])

	if inner > outer then outer, inner = inner, outer end

	T(outer)[">"](145)
	T(outer)["<"](154.5)
	T(inner)[">"](75)
	T(inner)["<"](79.5)
end)

T.Test("svg decode fills basic shapes", function()
	local rect = svg.Decode(
		[[<svg viewBox="0 0 24 24"><rect x="2" y="3" width="10" height="6" fill="currentColor"/></svg>]]
	)
	T(#rect.contours)["=="](1)
	T(contour_area(rect.contours[1]))["~"](60, 0.001)
	local circle = svg.Decode(
		[[<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="5" fill="currentColor"/></svg>]]
	)
	T(#circle.contours)["=="](1)
	T(contour_area(circle.contours[1]))[">"](75)
	T(contour_area(circle.contours[1]))["<"](78.6)
end)

T.Test("svg decode draws nothing for fill none without a stroke", function()
	local decoded = svg.Decode(
		[[<svg viewBox="0 0 24 24"><path fill="none" d="M0 0H10V10Z"/></svg>]]
	)
	T(#decoded.contours)["=="](0)
end)
