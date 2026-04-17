local gine = ... or _G.gine
local render = import("goluwa/render/render.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local surface = gine.env.surface

local function get_panel_scissor_rect(panel)
	if not panel then
		if render.GetScissorRect then return render.GetScissorRect() end

		return false, 0, 0, gine.env.ScrW(), gine.env.ScrH()
	end

	local left, top = panel:LocalToScreen(0, 0)
	local right, bottom = panel:LocalToScreen(panel:GetWide(), panel:GetTall())
	local current = panel:GetParent()

	while current do
		local x1, y1 = current:LocalToScreen(0, 0)
		local x2, y2 = current:LocalToScreen(current:GetWide(), current:GetTall())
		left = math.max(left, x1)
		top = math.max(top, y1)
		right = math.min(right, x2)
		bottom = math.min(bottom, y2)
		current = current:GetParent()
	end

	return true, left, top, math.max(right, left), math.max(bottom, top)
end

function surface.SetDrawColor(r, g, b, a)
	if type(r) == "table" then r, g, b, a = r.r, r.g, r.b, r.a end

	a = a or 255
	render2d.SetColor(r / 255, g / 255, b / 255, a / 255)
end

function surface.SetAlphaMultiplier(a)
	render2d.SetAlphaMultiplier(a)
end

function surface.DrawTexturedRectRotated(x, y, w, h, r)
	render2d.PushUV()
	render2d.SetUV2(0, 1, 1, 0)
	render2d.DrawRectf(x, y, w, h, math.rad(r), w / 2, h / 2)
	render2d.PopUV()
end

function surface.DrawTexturedRect(x, y, w, h)
	render2d.PushUV()
	render2d.SetUV2(0, 1, 1, 0)
	render2d.DrawRect(x, y, w, h)
	render2d.PopUV()
end

function surface.DrawRect(x, y, w, h)
	local old = render2d.GetTexture()
	render2d.SetTexture()
	render2d.DrawRect(x, y, w, h)
	render2d.SetTexture(old)
end

function surface.DrawOutlinedRect(x, y, w, h)
	local old = render2d.GetTexture()
	render2d.SetTexture()
	render2d.DrawRect(x, y, 1, h)
	render2d.DrawRect(x, y, w, 1)
	render2d.DrawRect(w + x - 1, y, 1, h)
	render2d.DrawRect(x, h + y - 1, w, 1)
	render2d.SetTexture(old)
end

function surface.DrawTexturedRectUV(x, y, w, h, u1, v1, u2, v2)
	render2d.PushUV()
	render2d.SetUV2(u1, 1 - v2, u2, 1 - v1)
	render2d.DrawRect(x, y, w, h)
	render2d.PopUV()
end

function surface.DrawLine(...)
	gfx.DrawLine(...)
end

function surface.DisableClipping(b)
	local old = gine.surface_clipping_disabled or false

	if b ~= nil then gine.surface_clipping_disabled = not not b end

	return old
end

function surface.GetScissorRect()
	if gine.surface_clipping_disabled then
		return false, 0, 0, gine.env.ScrW(), gine.env.ScrH()
	end

	local panel = gine.GetPaintPanel and gine.GetPaintPanel() or nil
	return get_panel_scissor_rect(panel)
end

do
	local mesh
	local mesh_idx

	local function ensure_poly_mesh()
		if mesh then return mesh, mesh_idx end

		mesh = render2d.CreateMesh(2048)
		mesh:SetMode("triangle_fan")

		for i = 1, 2048 do
			mesh:SetVertex(i, "color", 1, 1, 1, 1)
		end

		mesh_idx = render.CreateIndexBuffer()
		mesh_idx:LoadIndices(2048)
		return mesh, mesh_idx
	end

	function surface.DrawPoly(tbl)
		local mesh, mesh_idx = ensure_poly_mesh()
		local count = #tbl

		for i = 1, count do
			local vertex = tbl[i]
			mesh:SetVertex(i, "pos", vertex.x, vertex.y)

			if vertex.u and vertex.v then
				mesh:SetVertex(i, "uv", vertex.u, vertex.v)
			end
		end

		render2d.BindShader()
		mesh:UpdateBuffer()
		mesh_idx:UpdateBuffer()
		mesh:Draw(mesh_idx, count)
	end
end
