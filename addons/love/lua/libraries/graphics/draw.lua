local line = import("lua/line.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or import("lua/love.lua")
local ctx = shared.Get(love)
local ENV = ctx.ENV

function love.graphics.rectangle(mode, x, y, w, h)
	if mode == "fill" then
		render2d.PushTexture()
		render2d.PushColor(ctx.get_draw_fg_color())
		render2d.PushSwizzleMode("none")
		render2d.DrawRect(x, y, w, h)
		render2d.PopSwizzleMode()
		render2d.PopColor()
		render2d.PopTexture()
	else
		render2d.PushTexture()
		render2d.PushColor(ctx.get_draw_fg_color())
		render2d.PushSwizzleMode("none")
		render2d.DrawLine(x, y, x + w, y)
		render2d.DrawLine(x, y, x, y + h)
		render2d.DrawLine(x + w, y, x + w, y + h)
		render2d.DrawLine(x, y + h, x + w, y + h)
		render2d.PopSwizzleMode()
		render2d.PopColor()
		render2d.PopTexture()
	end
end

function love.graphics.roundrect(mode, x, y, w, h)
	return love.graphics.rectangle(mode, x, y, w, h)
end

function love.graphics.drawq(drawable, quad, x, y, r, sx, sy, ox, oy, kx, ky)
	x = x or 0
	y = y or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	r = r or 0
	kx = kx or 0
	ky = ky or 0
	local dpi_scale = drawable.dpi_scale or 1
	render2d.PushColor(ctx.get_draw_fg_color())
	render2d.PushTexture(ENV.textures[drawable])

	do
		local x, y = quad.x, quad.y
		local w, h = quad.w, quad.h
		w = w + x
		h = h + y
		local uvsx = quad.sw * dpi_scale
		local uvsy = quad.sh * dpi_scale
		local u1, v1, u2, v2 = x / uvsx, y / uvsy, w / uvsx, h / uvsy
		v1 = -v1 + 1
		v2 = -v2 + 1
		render2d.PushColorUV(u1, v2, u2, v1, 0)
	end

	render2d.DrawRectf(x, y, quad.w * sx, quad.h * sy, r, ox * sx, oy * sy)
	render2d.PopColorUV()
	render2d.PopTexture()
	render2d.PopColor()
end

function love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy, kx, ky, quad_arg)
	local drawable_texture = ENV.textures[drawable]

	if
		not drawable_texture and
		(
			line.Type(drawable) == "Image" or
			line.Type(drawable) == "Canvas"
		)
	then
		if drawable.fb then
			drawable_texture = drawable.fb:GetColorTexture()
			ENV.textures[drawable] = drawable_texture
		end
	end

	if drawable_texture then
		if line.Type(x) == "Quad" then
			love.graphics.drawq(drawable, x, y, r, sx, sy, ox, oy, kx, ky, quad_arg)
		else
			x = x or 0
			y = y or 0
			sx = sx or 1
			sy = sy or sx
			ox = ox or 0
			oy = oy or 0
			r = r or 0
			kx = kx or 0
			ky = ky or 0
			local tex = drawable_texture
			local tex_w, tex_h

			if drawable.getDimensions then
				tex_w, tex_h = drawable:getDimensions()
			else
				tex_w, tex_h = tex:GetSize():Unpack()
			end

			render2d.PushColor(ctx.get_draw_fg_color())
			render2d.PushSwizzleMode(render2d.GetSwizzleMode())
			render2d.SetSwizzleMode("none")
			render2d.PushTexture(tex)
			local uv_w, uv_h = tex:GetSize():Unpack()
			render2d.PushColorUV(0, 0, uv_w, -uv_h, 0, uv_w, uv_h)
			render2d.DrawRectf(x, y, tex_w * sx, tex_h * sy, r, ox * sx, oy * sy)
			render2d.PopColorUV()
			render2d.PopTexture()
			render2d.PopSwizzleMode()
			render2d.PopColor()
		end
	else
		x = x or 0
		y = y or 0
		sx = sx or 1
		sy = sy or sx
		ox = ox or 0
		oy = oy or 0
		r = r or 0
		kx = kx or 0
		ky = ky or 0

		if line.Type(drawable) == "SpriteBatch" then
			drawable:Draw(x, y, r, sx, sy, ox, oy, kx, ky)
		elseif line.Type(drawable) == "Text" then
			drawable:Draw(x, y, r, sx, sy, ox, oy, kx, ky)
		elseif line.Type(drawable) == "Mesh" then
			render2d.PushColor(1, 1, 1, 1)
			render2d.PushTexture(ENV.textures[drawable.img])
			render2d.PushWorldMatrix()
			render2d.Translatef(x, y)
			render2d.Rotate(r)

			if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

			if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

			render2d.Scalef(sx, sy)
			render2d.UploadConstants()
			drawable:Draw()
			render2d.PopMatrix()
			render2d.PopTexture()
			render2d.PopColor()
		elseif line.Type(drawable) == "ParticleSystem" then

		else
			table.print(drawable)
			debug.trace()
		end
	end
end

local function get_attached_mesh_attribute(drawable, attribute_name, index, default_a, default_b)
	local attachment = drawable.attached_attributes and drawable.attached_attributes[attribute_name]

	if not attachment or not attachment.mesh then return default_a, default_b end

	local a, b = attachment.mesh:getVertexAttributeByName(index, attribute_name)

	if a == nil then a = default_a end

	if b == nil then b = default_b end

	return a, b
end

local function get_shared_instance_mesh(drawable)
	local shared_mesh

	for _, attachment in pairs(drawable.attached_attributes or {}) do
		if attachment and attachment.mesh then
			if shared_mesh and shared_mesh ~= attachment.mesh then return nil end

			shared_mesh = attachment.mesh
		end
	end

	return shared_mesh
end

local function draw_instanced_mesh_gpu(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	local shader = ENV.current_shader

	if not shader or not shader.pipeline or not shader.instance_binding then
		return false
	end

	local instance_mesh = get_shared_instance_mesh(drawable)

	if not instance_mesh or not instance_mesh.vertex_buffer then return false end

	local texture = drawable:getTexture()

	if not texture then return false end

	if drawable._line_dirty_buffers then drawable:UpdateBuffers() end

	if instance_mesh._line_dirty_buffers then instance_mesh:UpdateBuffers() end

	instance_count = math.min(
		instance_count or instance_mesh.vertex_buffer:GetVertexCount(),
		instance_mesh.vertex_buffer:GetVertexCount()
	)
	x = x or 0
	y = y or 0
	r = r or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	kx = kx or 0
	ky = ky or 0
	render2d.PushColor(1, 1, 1, 1)
	render2d.PushTexture(ENV.textures[texture] or texture)
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(r)

	if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

	if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

	render2d.Scalef(sx, sy)
	render2d.UploadConstants()
	-- Sync pipeline state to bind descriptor set with registered textures
	--render2d.BindPipeline()
	drawable:DrawInstanced(instance_count, {instance_mesh.vertex_buffer})
	render2d.PopMatrix()
	render2d.PopTexture()
	render2d.PopColor()
	return true
end

local function draw_instanced_mesh(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	if
		draw_instanced_mesh_gpu(drawable, instance_count, x, y, r, sx, sy, ox, oy, kx, ky)
	then
		return true
	end

	if not drawable.attached_attributes then return false end

	local texture = drawable:getTexture()

	if not texture then return false end

	local position_attachment = drawable.attached_attributes.InstancePosition

	if not position_attachment or not position_attachment.mesh then return false end

	instance_count = math.min(
		instance_count or position_attachment.mesh:getVertexCount(),
		position_attachment.mesh:getVertexCount()
	)
	x = x or 0
	y = y or 0
	r = r or 0
	sx = sx or 1
	sy = sy or sx
	ox = ox or 0
	oy = oy or 0
	kx = kx or 0
	ky = ky or 0
	ENV.graphics_instanced_quad = ENV.graphics_instanced_quad or love.graphics.newQuad(0, 0, 1, 1, texture)
	local quad = ENV.graphics_instanced_quad
	render2d.PushMatrix()
	render2d.Translatef(x, y)
	render2d.Rotate(r)

	if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

	if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

	render2d.Scalef(sx, sy)
	render2d.PushColor(ctx.get_draw_fg_color())

	for index = 1, instance_count do
		local inst_x, inst_y = get_attached_mesh_attribute(drawable, "InstancePosition", index, 0, 0)
		local uv_x, uv_y = get_attached_mesh_attribute(drawable, "UVOffset", index, 0, 0)
		local img_w, img_h = get_attached_mesh_attribute(drawable, "ImageDim", index, 0, 0)
		--local shade = select(1, get_attached_mesh_attribute(drawable, "ImageShade", index, 1)) or 1
		local scale_x, scale_y = get_attached_mesh_attribute(drawable, "Scale", index, 1, 1)

		if img_w ~= 0 and img_h ~= 0 then
			quad:setViewport(uv_x, uv_y, img_w, img_h)
			love.graphics.drawq(texture, quad, inst_x, inst_y, 0, scale_x, scale_y)
		end
	end

	render2d.PopColor()
	render2d.PopMatrix()
	return true
end

function love.graphics.drawInstanced(drawable, instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	if
		line.Type(drawable) == "Mesh" and
		draw_instanced_mesh(drawable, instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	then
		return
	end

	if drawable.drawInstanced then
		return drawable:drawInstanced(instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	end

	if drawable.DrawInstanced then
		return drawable:DrawInstanced(instancecount, x, y, r, sx, sy, ox, oy, kx, ky)
	end

	return love.graphics.draw(drawable, x, y, r, sx, sy, ox, oy, kx, ky)
end

return love.graphics
