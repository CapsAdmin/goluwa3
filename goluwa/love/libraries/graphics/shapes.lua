local render2d = import("goluwa/render2d/render2d.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local IndexBuffer = import("goluwa/render/index_buffer.lua")
return function(ctx)
	local love = ctx.love
	local mesh = render2d.CreateMesh(2048)

	for i = 1, 2048 do
		mesh:SetVertex(i, "color", 1, 1, 1, 1)
	end

	local mesh_idx = IndexBuffer.New()
	mesh_idx:LoadIndices(2048)

	local function triangle_list_indices(mode, source_indices)
		mode = mode or "triangles"

		if mode == "triangles" or mode == "triangle_list" then
			return source_indices
		elseif mode == "triangle_strip" or mode == "strip" then
			local out = {}

			for i = 1, #source_indices - 2 do
				local a = source_indices[i]
				local b = source_indices[i + 1]
				local c = source_indices[i + 2]

				if i % 2 == 0 then a, b = b, a end

				list.insert(out, a)
				list.insert(out, b)
				list.insert(out, c)
			end

			return out
		elseif mode == "triangle_fan" or mode == "fan" then
			local out = {}
			local first = source_indices[1]

			for i = 2, #source_indices - 1 do
				list.insert(out, first)
				list.insert(out, source_indices[i])
				list.insert(out, source_indices[i + 1])
			end

			return out
		end

		return source_indices
	end

	local function polygon(mode, points, join)
		render2d.PushTexture()
		local idx = 1

		if mode == "line" then
			local draw_mode, vertices, indices = math2d.CoordinatesToLines(points, love.graphics.getLineWidth(), join, love.graphics.getLineJoin(), 1, false)
			local draw_indices

			if indices then
				draw_indices = indices
			else
				draw_indices = {}

				for i = 1, #vertices do
					draw_indices[i] = i - 1
				end
			end

			draw_indices = triangle_list_indices(draw_mode, draw_indices)

			for i, v in ipairs(draw_indices) do
				mesh_idx:SetIndex(i, v)
			end

			idx = #draw_indices

			for i, v in ipairs(vertices) do
				mesh:SetVertex(i, "pos", v.x, v.y)
			end
		else
			local draw_indices = {}
			local vertex_count = 0

			for i = 1, #points, 2 do
				mesh:SetVertex(idx, "pos", points[i + 0], points[i + 1])
				draw_indices[#draw_indices + 1] = vertex_count
				vertex_count = vertex_count + 1
				idx = idx + 1
			end

			draw_indices = triangle_list_indices("triangle_fan", draw_indices)

			for i, v in ipairs(draw_indices) do
				mesh_idx:SetIndex(i, v)
			end

			idx = #draw_indices
		end

		mesh:UpdateBuffer()
		mesh_idx:UpdateBuffer()
		render2d.BindMesh(mesh)
		render2d.UploadConstants(render2d.cmd)
		mesh:Draw(mesh_idx, idx)
		render2d.PopTexture()
	end

	function love.graphics.polygon(mode, ...)
		local points = type(...) == "table" and ... or {...}
		polygon(mode, points, true)
	end

	function love.graphics.arc(...)
		local draw_mode, arc_mode, x, y, radius, angle1, angle2, points

		if type(select(2, ...)) == "number" then
			draw_mode, x, y, radius, angle1, angle2, points = ...
			arc_mode = "pie"
		else
			draw_mode, arc_mode, x, y, radius, angle1, angle2, points = ...
		end

		if
			draw_mode == "line" and
			arc_mode == "closed" and
			math.abs(angle1 - angle2) < math.rad(4)
		then
			arc_mode = "open"
		end

		if draw_mode == "fill" and arc_mode == "open" then arc_mode = "closed" end

		local coords = math2d.ArcToCoordinates(arc_mode, x, y, radius, angle1, angle2, points)

		if coords then polygon(draw_mode, coords) end
	end

	function love.graphics.ellipse(mode, x, y, radiusx, radiusy, points)
		local coords = math2d.EllipseToCoordinates(x, y, radiusx, radiusy, points)
		polygon(mode, coords)
	end

	function love.graphics.circle(mode, x, y, radius, points)
		if not points then
			if radius and radius > 10 then
				points = math.ceil(radius)
			else
				points = 10
			end
		end

		love.graphics.ellipse(mode, x, y, radius, radius, points)
	end

	function love.graphics.line(...)
		local tbl = ...

		if type(tbl) == "number" then tbl = {...} end

		polygon("line", tbl)
	end

	function love.graphics.triangle(mode, x1, y1, x2, y2, x3, y3)
		polygon(mode, {x1, y1, x2, y2, x3, y3, x1, y1})
	end

	function love.graphics.rectangle(mode, x, y, w, h, rx, ry, points)
		rx = rx or 0
		ry = ry or rx

		if mode == "fill" then
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			render2d.SetSwizzleMode(0)
			render2d.SetTexture()
			render2d.DrawRect(x, y, w, h)
			render2d.PopSwizzleMode()
		else
			local coords = math2d.RoundedRectangleToCoordinates(x, y, w, h, rx, ry, points)
			polygon("line", coords, true)
		end
	end
end
