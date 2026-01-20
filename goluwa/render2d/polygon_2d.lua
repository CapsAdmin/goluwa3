local render2d = require("render2d.render2d")
local VertexBuffer = require("render.vertex_buffer")
local IndexBuffer = require("render.index_buffer")
local prototype = require("prototype")
local Polygon2D = prototype.CreateTemplate("render2d_polygon_2d")
Polygon2D:GetSet("WorldMatrixMultiply", false)

function Polygon2D.New(vertex_count, map)
	local self = Polygon2D:CreateObject()
	self.vertex_buffer = render2d.CreateMesh(vertex_count)

	do
		self.index_buffer = IndexBuffer.New()
		self.index_buffer:LoadIndices(vertex_count)
	end

	self.vertex_count = vertex_count
	self.mapped = map
	return self
end

Polygon2D.X, Polygon2D.Y = 0, 0
Polygon2D.ROT = 0
Polygon2D.R, Polygon2D.G, Polygon2D.B, Polygon2D.A = 1, 1, 1, 1
Polygon2D.U1, Polygon2D.V1, Polygon2D.U2, Polygon2D.V2 = 0, 0, 1, 1
Polygon2D.UVSW, Polygon2D.UVSH = 1, 1

function Polygon2D:SetColor(r, g, b, a)
	self.R = r or 1
	self.G = g or 1
	self.B = b or 1
	self.A = a or 1
	self.dirty = true
end

function Polygon2D:SetUV(u1, v1, u2, v2, sw, sh)
	self.U1 = u1
	self.U2 = u2
	self.V1 = v1
	self.V2 = v2
	self.UVSW = sw
	self.UVSH = sh
	self.dirty = true
end

local function set_uv(self, i, x, y, w, h, sx, sy)
	local vtx = self.vertex_buffer:GetVertices()

	if not x then
		vtx[i + 1].uv[0] = 0
		vtx[i + 1].uv[1] = 1
		vtx[i + 0].uv[0] = 0
		vtx[i + 0].uv[1] = 0
		vtx[i + 2].uv[0] = 1
		vtx[i + 2].uv[1] = 0
		--
		vtx[i + 4].uv = vtx[i + 2].uv
		vtx[i + 3].uv[0] = 1
		vtx[i + 3].uv[1] = 1
		vtx[i + 5].uv = vtx[i + 0].uv
	else
		sx = sx or 1
		sy = sy or 1
		y = -y - h
		vtx[i + 1].uv[0] = x / sx
		vtx[i + 1].uv[1] = (y + h) / sy
		vtx[i + 0].uv[0] = x / sx
		vtx[i + 0].uv[1] = y / sy
		vtx[i + 2].uv[0] = (x + w) / sx
		vtx[i + 2].uv[1] = y / sy
		--
		vtx[i + 4].uv = vtx[i + 2].uv
		vtx[i + 3].uv[0] = (x + w) / sx
		vtx[i + 3].uv[1] = (y + h) / sy
		vtx[i + 5].uv = vtx[i + 1].uv
	end
end

function Polygon2D:SetVertex(i, x, y, u, v)
	--if i > self.vertex_count or i < 0 then logf("i = %i vertex_count = %i\n", i, self.vertex_count) return end
	x = x or 0
	y = y or 0

	if self.ROT ~= 0 then
		x = x - self.X + self.RX
		y = y - self.Y + self.RY
		local new_x = x * math.cos(self.ROT) - y * math.sin(self.ROT)
		local new_y = x * math.sin(self.ROT) + y * math.cos(self.ROT)
		x = new_x + self.X - self.RX
		y = new_y + self.Y - self.RY
	end

	if self.WorldMatrixMultiply then
		x, y = render2d.GetWorldMatrix():TransformVector(x, y, 0)
	end

	local vtx = self.vertex_buffer:GetVertices()
	vtx[i].pos[0] = x
	vtx[i].pos[1] = y
	vtx[i].pos[2] = 0
	vtx[i].color[0] = self.R
	vtx[i].color[1] = self.G
	vtx[i].color[2] = self.B
	vtx[i].color[3] = self.A

	if u and v then
		vtx[i].uv[0] = u
		vtx[i].uv[1] = v
	else
		vtx[i].uv[0] = 0
		vtx[i].uv[1] = 0
	end

	self.dirty = true
end

function Polygon2D:SetTriangle(i, x1, y1, x2, y2, x3, y3, u1, v1, u2, v2, u3, v3)
	i = (i - 1) * 3
	self:SetVertex(i + 0, x1, y1, u1, v1)
	self:SetVertex(i + 1, x2, y2, u2, v2)
	self:SetVertex(i + 2, x3, y3, u3, v3)
end

function Polygon2D:SetRect(i, x, y, w, h, r, ox, oy, rx, ry)
	self.X = x or 0
	self.Y = y or 0
	self.ROT = r or 0
	self.OX = ox or 0
	self.OY = oy or 0
	self.RX = rx or 0
	self.RY = ry or 0
	i = i - 1
	i = i * 6
	set_uv(self, i, self.U1, self.V1, self.U2, self.V2, self.UVSW, self.UVSH)
	self:SetVertex(i + 0, self.X + self.OX, self.Y + h + self.OY)
	self:SetVertex(i + 1, self.X + self.OX, self.Y + self.OY)
	self:SetVertex(i + 2, self.X + w + self.OX, self.Y + h + self.OY)
	self:SetVertex(i + 3, self.X + w + self.OX, self.Y + self.OY)
	self:SetVertex(i + 4, self.X + w + self.OX, self.Y + h + self.OY)
	self:SetVertex(i + 5, self.X + self.OX, self.Y + self.OY)
end

function Polygon2D:DrawLine(i, x1, y1, x2, y2, w)
	w = w or 1
	local dx, dy = x2 - x1, y2 - y1
	local ang = math.atan2(dx, dy)
	local dst = math.sqrt((dx * dx) + (dy * dy))
	self:SetRect(i, x1, y1, w, dst, -ang)
end

function Polygon2D:Draw(count)
	if self.dirty and not self.mapped then
		self.vertex_buffer:Upload()
		self.dirty = false
	end

	if self.WorldMatrixMultiply then
		-- Vertices are already transformed, use identity matrix
		render2d.PushMatrix(nil, nil, nil, nil, nil, true)
		render2d.LoadIdentity()
	end

	render2d.UploadConstants(render2d.cmd)
	self.vertex_buffer:Bind(render2d.cmd, 0)
	render2d.cmd:BindIndexBuffer(self.index_buffer:GetBuffer(), 0, self.index_buffer:GetIndexType())
	render2d.cmd:DrawIndexed(count or self.vertex_count, 1, 0, 0, 0)

	if self.WorldMatrixMultiply then render2d.PopMatrix() end
end

function Polygon2D:SetNinePatch(
	i,
	x,
	y,
	w,
	h,
	patch_size_w,
	patch_size_h,
	corner_size,
	u_offset,
	v_offset,
	uv_scale,
	skin_w,
	skin_h
)
	u_offset = u_offset or 0
	v_offset = v_offset or 0
	uv_scale = uv_scale or 1

	if w / 2 < corner_size then corner_size = w / 2 end

	if h / 2 < corner_size then corner_size = h / 2 end

	-- 1
	self:SetUV(
		u_offset,
		v_offset,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 0, x, y, corner_size, corner_size)
	-- 2
	self:SetUV(
		u_offset + corner_size,
		v_offset,
		(patch_size_w - corner_size * 2) / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 1, x + corner_size, y, w - corner_size * 2, corner_size)
	-- 3
	self:SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 2, x + w - corner_size, y, corner_size, corner_size)
	-- 4
	self:SetUV(
		u_offset,
		v_offset + corner_size,
		corner_size / uv_scale,
		(patch_size_h - corner_size * 2) / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 3, x, y + corner_size, corner_size, h - corner_size * 2)
	-- 5
	self:SetUV(
		u_offset + corner_size,
		v_offset + corner_size,
		patch_size_w - corner_size * 2,
		patch_size_h - corner_size * 2,
		skin_w,
		skin_h
	)
	self:SetRect(
		i + 4,
		x + corner_size,
		y + corner_size,
		w - corner_size * 2,
		h - corner_size * 2
	)
	-- 6
	self:SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset + corner_size / uv_scale,
		corner_size / uv_scale,
		(patch_size_h - corner_size * 2) / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(
		i + 5,
		x + w - corner_size,
		y + corner_size,
		corner_size,
		h - corner_size * 2
	)
	-- 7
	self:SetUV(
		u_offset,
		v_offset + patch_size_h - corner_size / uv_scale,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 6, x, y + h - corner_size, corner_size, corner_size)
	-- 8
	self:SetUV(
		u_offset + corner_size / uv_scale,
		v_offset + patch_size_h - corner_size / uv_scale,
		(patch_size_w - corner_size * 2) / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(
		i + 7,
		x + corner_size,
		y + h - corner_size,
		w - corner_size * 2,
		corner_size
	)
	-- 9
	self:SetUV(
		u_offset + patch_size_w - corner_size / uv_scale,
		v_offset + patch_size_h - corner_size / uv_scale,
		corner_size / uv_scale,
		corner_size / uv_scale,
		skin_w,
		skin_h
	)
	self:SetRect(i + 8, x + w - corner_size, y + h - corner_size, corner_size, corner_size)
end

function Polygon2D:AddRect(...)
	self.added = (self.added or 1)
	self:SetRect(self.added, ...)
	self.added = self.added + 1
end

function Polygon2D:AddNinePatch(...)
	self.added = (self.added or 1)
	self:SetRect(self.added, ...)
	self.added = self.added + 9
end

return Polygon2D:Register()
