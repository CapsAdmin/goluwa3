local ffi = require("ffi")
local objects = import("goluwa/objects/objects.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local TrailRenderer = objects.CreateTemplate("TrailRenderer")
TrailRenderer:GetSet("Duration", 1.0)
TrailRenderer:GetSet("Spacing", 2.0)
TrailRenderer:GetSet("StartSize", 4.0)
TrailRenderer:GetSet("EndSize", 0.0)
TrailRenderer:GetSet("StartColor", Color(1, 1, 1, 1))
TrailRenderer:GetSet("EndColor", Color(1, 1, 1, 0))
TrailRenderer:GetSet("Texture", nil)
TrailRenderer:GetSet("UVStretch", 1.0)
TrailRenderer:GetSet("MaxPoints", 512)
TrailRenderer:GetSet("Additive", true)
TrailRenderer:GetSet("Paused", false)

function TrailRenderer.New(config)
	config = config or {}
	return TrailRenderer:CreateObject{
		points = {},
		last_position = nil,
		Duration = config.Duration or 1.0,
		Spacing = config.Spacing or 2.0,
		StartSize = config.StartSize or 4.0,
		EndSize = config.EndSize or 0.0,
		StartColor = config.StartColor or Color(1, 1, 1, 1),
		EndColor = config.EndColor or Color(1, 1, 1, 0),
		Texture = config.Texture or nil,
		UVStretch = config.UVStretch or 1.0,
		MaxPoints = config.MaxPoints or 512,
		Additive = config.Additive ~= false,
		Paused = config.Paused or false,
	}
end

function TrailRenderer:Update(dt)
	if self.Paused then return end

	local time = system.GetElapsedTime()
	local cutoff = time - self.Duration

	while #self.points > 0 and self.points[1].time < cutoff do
		table.remove(self.points, 1)
	end
end

function TrailRenderer:Draw()
	if #self.points < 2 then return end

	render2d.PushBlendPreset(self.Additive and "additive" or "alpha")
	render2d.SetTexture(self.Texture)
	local num_segments = #self.points - 1
	local poly = Polygon2D.New(6 * num_segments)
	poly:SetWorldMatrixMultiply(true)
	local vtx = poly.vertex_buffer:GetVertices()
	local denom = num_segments > 1 and (num_segments - 1) or 1
	local uv_denom = self.UVStretch * math.max(num_segments, 1)
	-- Precompute perpendiculars at each point using centered differences
	local normals = {}

	for j = 1, #self.points do
		local px, py

		if j == 1 then
			-- First point: use direction to next
			local dx = self.points[2].x - self.points[1].x
			local dy = self.points[2].y - self.points[1].y
			px = -dy
			py = dx
		elseif j == #self.points then
			-- Last point: use direction from previous
			local dx = self.points[j].x - self.points[j - 1].x
			local dy = self.points[j].y - self.points[j - 1].y
			px = -dy
			py = dx
		else
			-- Centered: average of incoming and outgoing direction
			local dx_in = self.points[j].x - self.points[j - 1].x
			local dy_in = self.points[j].y - self.points[j - 1].y
			local dx_out = self.points[j + 1].x - self.points[j].x
			local dy_out = self.points[j + 1].y - self.points[j].y
			px = -(dy_in + dy_out)
			py = dx_in + dx_out
		end

		local plen = math.sqrt(px * px + py * py)

		if plen > 0.001 then
			normals[j] = {px / plen, py / plen}
		else
			normals[j] = {1, 0}
		end
	end

	for i = 0, num_segments - 1 do
		local p0 = self.points[i + 1]
		local p1 = self.points[i + 2]
		local n0 = normals[i + 1]
		local n1 = normals[i + 2]
		local t = i / denom
		local t_next = (i + 1) / denom
		local size0 = math.lerp(1 - t, self.StartSize, self.EndSize)
		local size1 = math.lerp(1 - t_next, self.StartSize, self.EndSize)
		local base = i * 6
		local cr = math.lerp(1 - t, self.StartColor.r, self.EndColor.r)
		local cg = math.lerp(1 - t, self.StartColor.g, self.EndColor.g)
		local cb = math.lerp(1 - t, self.StartColor.b, self.EndColor.b)
		local ca = math.lerp(1 - t, self.StartColor.a, self.EndColor.a)
		local uv = i / uv_denom
		local cr1 = math.lerp(1 - t_next, self.StartColor.r, self.EndColor.r)
		local cg1 = math.lerp(1 - t_next, self.StartColor.g, self.EndColor.g)
		local cb1 = math.lerp(1 - t_next, self.StartColor.b, self.EndColor.b)
		local ca1 = math.lerp(1 - t_next, self.StartColor.a, self.EndColor.a)
		local uv1 = (i + 1) / uv_denom
		-- v0: top at p0
		vtx[base].pos[0] = p0.x + n0[1] * size0
		vtx[base].pos[1] = p0.y + n0[2] * size0
		vtx[base].pos[2] = 0
		vtx[base].color[0] = cr
		vtx[base].color[1] = cg
		vtx[base].color[2] = cb
		vtx[base].color[3] = ca
		vtx[base].uv[0] = uv
		vtx[base].uv[1] = 0
		vtx[base].sample_uv[0] = uv
		vtx[base].sample_uv[1] = 0
		-- v1: bottom at p0
		vtx[base + 1].pos[0] = p0.x - n0[1] * size0
		vtx[base + 1].pos[1] = p0.y - n0[2] * size0
		vtx[base + 1].pos[2] = 0
		vtx[base + 1].color[0] = cr
		vtx[base + 1].color[1] = cg
		vtx[base + 1].color[2] = cb
		vtx[base + 1].color[3] = ca
		vtx[base + 1].uv[0] = uv
		vtx[base + 1].uv[1] = 1
		vtx[base + 1].sample_uv[0] = uv
		vtx[base + 1].sample_uv[1] = 1
		-- v2: top at p1
		vtx[base + 2].pos[0] = p1.x + n1[1] * size1
		vtx[base + 2].pos[1] = p1.y + n1[2] * size1
		vtx[base + 2].pos[2] = 0
		vtx[base + 2].color[0] = cr1
		vtx[base + 2].color[1] = cg1
		vtx[base + 2].color[2] = cb1
		vtx[base + 2].color[3] = ca1
		vtx[base + 2].uv[0] = uv1
		vtx[base + 2].uv[1] = 0
		vtx[base + 2].sample_uv[0] = uv1
		vtx[base + 2].sample_uv[1] = 0
		-- v3: bottom at p1
		vtx[base + 3].pos[0] = p1.x - n1[1] * size1
		vtx[base + 3].pos[1] = p1.y - n1[2] * size1
		vtx[base + 3].pos[2] = 0
		vtx[base + 3].color[0] = cr1
		vtx[base + 3].color[1] = cg1
		vtx[base + 3].color[2] = cb1
		vtx[base + 3].color[3] = ca1
		vtx[base + 3].uv[0] = uv1
		vtx[base + 3].uv[1] = 1
		vtx[base + 3].sample_uv[0] = uv1
		vtx[base + 3].sample_uv[1] = 1
		-- v4: duplicate of v2
		vtx[base + 4].pos[0] = p1.x + n1[1] * size1
		vtx[base + 4].pos[1] = p1.y + n1[2] * size1
		vtx[base + 4].pos[2] = 0
		vtx[base + 4].color[0] = cr1
		vtx[base + 4].color[1] = cg1
		vtx[base + 4].color[2] = cb1
		vtx[base + 4].color[3] = ca1
		vtx[base + 4].uv[0] = uv1
		vtx[base + 4].uv[1] = 0
		vtx[base + 4].sample_uv[0] = uv1
		vtx[base + 4].sample_uv[1] = 0
		-- v5: duplicate of v1
		vtx[base + 5].pos[0] = p0.x - n0[1] * size0
		vtx[base + 5].pos[1] = p0.y - n0[2] * size0
		vtx[base + 5].pos[2] = 0
		vtx[base + 5].color[0] = cr
		vtx[base + 5].color[1] = cg
		vtx[base + 5].color[2] = cb
		vtx[base + 5].color[3] = ca
		vtx[base + 5].uv[0] = uv
		vtx[base + 5].uv[1] = 1
		vtx[base + 5].sample_uv[0] = uv
		vtx[base + 5].sample_uv[1] = 1
	end

	poly.vertex_buffer:Upload()
	poly:Draw(num_segments * 6)
	render2d.PopBlendMode()
end

function TrailRenderer:AddPoint(x, y)
	if self.last_position then
		local dx = x - self.last_position.x
		local dy = y - self.last_position.y

		if dx * dx + dy * dy < self.Spacing * self.Spacing then return end
	end

	self.last_position = Vec2(x, y)

	if #self.points >= self.MaxPoints then table.remove(self.points, 1) end

	table.insert(self.points, {x = x, y = y, time = system.GetElapsedTime()})
end

function TrailRenderer:Clear()
	self.points = {}
	self.last_position = nil
end

function TrailRenderer:GetPointCount()
	return #self.points
end

return TrailRenderer:Register()
