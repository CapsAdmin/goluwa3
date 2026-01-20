local prototype = require("prototype")
local render2d = require("render2d.render2d")
local Vec2 = require("structs.vec2")
local Color = require("structs.color")
local META = prototype.CreateTemplate("render2d_quadric_bezier_curve")
META:GetSet("JoinLast", true)
META:GetSet("MaxLines", 0)

function META.New(count)
	local self = META:CreateObject()
	self.nodes = {}
	self.MaxLines = count
	return self
end

function META:Add(point, control)
	self:Set(#self.nodes + 1, point, control)
	self.MaxLines = #self.nodes
end

function META:Set(i, point, control)
	self.nodes[i] = self.nodes[i] or {}

	if point then
		self.nodes[i].point = self.nodes[i].point or Vec2()
		self.nodes[i].point.x = point.x
		self.nodes[i].point.y = point.y
	end

	if control then
		self.nodes[i].control = self.nodes[i].control or Vec2()
		self.nodes[i].control.x = control.x
		self.nodes[i].control.y = control.y
	else
		self.nodes[i].control = nil
	end
end

local function quadratic_bezier(a, b, control, t)
	return (1 - t) * (1 - t) * a + (2 - 2 * t) * t * control + b * t * t
end

function META:ConvertToPoints(quality)
	quality = quality or 60
	local points = {}
	local precision = 1 / quality

	for i = 1, self.MaxLines do
		local current = self.nodes[i]
		local next = self.nodes[i + 1]

		if self.JoinLast then
			if i == self.MaxLines then next = self.nodes[1] end
		else
			if i ~= self.MaxLines then break end
		end

		local current_control = current.control or current.point:GetLerped(0.5, next.point)

		for step = 0, 1, precision do
			list.insert(points, quadratic_bezier(current.point, next.point, current_control, step))
		end
	end

	return points
end

local function line_segment_normal(a, b)
	return Vec2(b.y - a.y, a.x - b.x):Normalize()
end

function META:CreateOffsetedCurve(offset)
	local offseted = META.New()

	for i = 1, self.MaxLines do
		local current = self.nodes[i]
		local next = self.nodes[i + 1]

		if self.JoinLast then
			if i == self.MaxLines then next = self.nodes[1] end
		else
			if i ~= self.MaxLines then break end
		end

		if not next then break end

		local prev = self.nodes[i - 1] or self.nodes[self.MaxLines]
		local current_control = current.control or current.point:GetLerped(0.5, next.point)
		local prev_control = prev and (prev.control or prev.point:GetLerped(0.5, current.point))
		local normal = line_segment_normal(current.point, current_control)
		normal = normal + line_segment_normal(prev_control, current.point)
		normal:Normalize()
		local render2d_normal = line_segment_normal(current.point, next.point)
		offseted:Add(current.point + normal * offset, current_control + render2d_normal * offset)
	end

	return offseted
end

local color_white = Color(1, 1, 1, 1)

function META:ConstructMesh(width, quality, stretch, mesh)
	width = width or 30
	stretch = stretch or 1

	if type(width) == "number" then width = Vec2(-width, width) end

	local negative_points = self:CreateOffsetedCurve(width.x):ConvertToPoints(quality)
	local positive_points = self:CreateOffsetedCurve(width.y):ConvertToPoints(quality)
	local mesh = mesh or render2d.CreateMesh(#positive_points * 2)
	local vertices = mesh:GetVertices()
	local distance_positive = 0

	for i in ipairs(positive_points) do
		if i > 1 then
			distance_positive = distance_positive + (
					negative_points[i - 1]:Distance(negative_points[i]) + positive_points[i - 1]:Distance(positive_points[i])
				) / stretch / 2
		end

		local negative = negative_points[i]
		local positive = positive_points[i]
		local i = i - 1
		i = i * 2
		local a = vertices[i]
		a.pos[0] = negative.x
		a.pos[1] = negative.y
		a.uv[0] = distance_positive
		a.uv[1] = 0
		a.color[0] = color_white.r
		a.color[1] = color_white.g
		a.color[2] = color_white.b
		a.color[3] = color_white.a
		local b = vertices[i + 1]
		b.pos[0] = positive.x
		b.pos[1] = positive.y
		b.uv[0] = distance_positive
		b.uv[1] = 1
		b.color[0] = color_white.r
		b.color[1] = color_white.g
		b.color[2] = color_white.b
		b.color[3] = color_white.a
	end

	-- Create index buffer for triangle strip converted to triangle list
	local segment_count = #positive_points - 1
	local index_count = segment_count * 6 -- 2 triangles per segment, 3 indices each
	local indices = {}

	for i = 0, segment_count - 1 do
		local base = i * 2
		-- First triangle (counter-clockwise winding)
		table.insert(indices, base + 1)
		table.insert(indices, base + 2)
		table.insert(indices, base)
		-- Second triangle (counter-clockwise winding)
		table.insert(indices, base + 3)
		table.insert(indices, base + 2)
		table.insert(indices, base + 1)
	end

	mesh:Upload()
	mesh:UploadIndices(indices, "uint16")
	return mesh, index_count
end

function META:UpdateMesh(mesh, width, quality, stretch)
	return self:ConstructMesh(width, quality, stretch, mesh)
end

META:Register()
return META
