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
	local poly, decoded = svg.CreatePolygon2D([[<svg xmlns="http://www.w3.org/2000/svg" width="1em" height="1em" viewBox="0 0 24 24"><path fill="currentColor" d="M10 20v-6h4v6h5v-8h3L12 3L2 12h3v8z"/></svg>]])
	T(decoded.view_box.x)["=="](0)
	T(decoded.view_box.y)["=="](0)
	T(decoded.view_box.w)["=="](24)
	T(decoded.view_box.h)["=="](24)
	T(decoded.width)["=="](24)
	T(decoded.height)["=="](24)
	T(#decoded.contours)["=="](1)
	T(#decoded.triangles)[">"](0)
	T(poly.vertex_count)["=="](#decoded.triangles / 2)
	T(triangle_area_sum(decoded.triangles))[">"](0)
	T(triangle_area_sum(decoded.triangles))["~"](114)
end)

T.Test("svg decode merges hole contours with even odd fill", function()
	local decoded = svg.Decode([[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
			<path fill="currentColor" d="M0 0H10V10H0Z M3 3H7V7H3Z"/>
		</svg>
	]])
	T(#decoded.contours)["=="](2)
	T(#decoded.triangles)[">"](0)
	T(triangle_area_sum(decoded.triangles))["~"](84)
end)

T.Test("svg decode flattens quadratic and cubic curves", function()
	local decoded = svg.Decode(
		[[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 10">
			<path fill="currentColor" d="M0 10 Q5 0 10 10 C12 14 16 14 20 10 L20 20 L0 20 Z"/>
		</svg>
	]],
		{curve_steps = 8}
	)
	T(#decoded.contours)["=="](1)
	T(#decoded.contours[1])[">"](20)
	T(#decoded.triangles)[">"](0)
	T(triangle_area_sum(decoded.triangles))[">"](0)
end)

T.Test("svg decode accepts compact decimal numbers", function()
	local decoded = svg.Decode([[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
			<path fill="currentColor" d="M1.5.5L9.5.5L9.5 9.5L.5 9.5Z"/>
		</svg>
	]])
	T(#decoded.contours)["=="](1)
	T(#decoded.triangles)[">"](0)
	T(triangle_area_sum(decoded.triangles))[">"](0)
end)

T.Test("svg decode flattens arc commands", function()
	local decoded = svg.Decode(
		[[
		<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
			<path fill="currentColor" d="M12 2 A10 10 0 1 1 11.999 2 L12 12 Z"/>
		</svg>
	]],
		{curve_steps = 8}
	)
	T(#decoded.contours)["=="](1)
	T(#decoded.contours[1])[">"](20)
	T(#decoded.triangles)[">"](0)
	T(triangle_area_sum(decoded.triangles))[">"](0)
end)
