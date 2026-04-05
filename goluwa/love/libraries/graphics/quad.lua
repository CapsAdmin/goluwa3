return function(ctx)
	local love = ctx.love
	local ENV = ctx.ENV
	local line = ctx.line

	local function drawable_uses_linear_filter(drawable)
		local min = drawable and drawable.filter_min or ENV.graphics_filter_min
		local mag = drawable and drawable.filter_mag or min or ENV.graphics_filter_mag
		return min == "linear" or mag == "linear"
	end

	local function get_quad_uv_rect(drawable, quad)
		local sample_x = quad.x
		local sample_y = quad.y
		local sample_w = quad.w
		local sample_h = quad.h

		if drawable_uses_linear_filter(drawable) then
			local inset_x = math.min(0.5, quad.w / 2)
			local inset_y = math.min(0.5, quad.h / 2)
			sample_x = sample_x + inset_x
			sample_y = sample_y + inset_y
			sample_w = math.max(quad.w - (inset_x * 2), 0)
			sample_h = math.max(quad.h - (inset_y * 2), 0)
		end

		return sample_x, sample_y, sample_w, sample_h
	end

	local function get_quad_draw_rect(drawable, quad, x, y, sx, sy, ox, oy, r, kx, ky)
		local draw_x = x
		local draw_y = y
		local draw_w = quad.w * sx
		local draw_h = quad.h * sy

		if
			drawable_uses_linear_filter(drawable) and
			r == 0 and
			kx == 0 and
			ky == 0 and
			ox == 0 and
			oy == 0 and
			sx >= 0 and
			sy >= 0
		then
			draw_x = draw_x - 0.5
			draw_y = draw_y - 0.5
			draw_w = draw_w + 1
			draw_h = draw_h + 1
		end

		return draw_x, draw_y, draw_w, draw_h
	end

	do
		local Quad = line.TypeTemplate("Quad")

		local function refresh(vertices, x, y, w, h, sw, sh)
			vertices[0].x = 0
			vertices[0].y = 0
			vertices[1].x = 0
			vertices[1].y = h
			vertices[2].x = w
			vertices[2].y = h
			vertices[3].x = w
			vertices[3].y = 0
			vertices[0].s = x / sw
			vertices[0].t = y / sh
			vertices[1].s = x / sw
			vertices[1].t = (y + h) / sh
			vertices[2].s = (x + w) / sw
			vertices[2].t = (y + h) / sh
			vertices[3].s = (x + w) / sw
			vertices[3].t = y / sh
		end

		function Quad:flip() end

		function Quad:getViewport()
			return self.x, self.y, self.w, self.h
		end

		function Quad:setViewport(x, y, w, h)
			self.x = x
			self.y = y
			self.w = w
			self.h = h
			refresh(self.vertices, self.x, self.y, self.w, self.h, self.sw, self.sh)
		end

		function love.graphics.newQuad(x, y, w, h, sw, sh)
			local self = line.CreateObject("Quad")
			local vertices = {}

			if type(sw) == "table" and sh == nil then
				local tex = ENV.textures[sw] or sw

				if tex.GetSize then
					sw, sh = tex:GetSize():Unpack()
				elseif sw.getDimensions then
					sw, sh = sw:getDimensions()
				end
			end

			for i = 0, 3 do
				vertices[i] = {x = 0, y = 0, s = 0, t = 0}
			end

			self.x = x
			self.y = y
			self.w = w
			self.h = h
			self.sw = sw or 1
			self.sh = sh or 1
			self.vertices = vertices
			refresh(self.vertices, x, y, w, h, self.sw, self.sh)
			return self
		end

		line.RegisterType(Quad)
	end

	ctx.get_quad_uv_rect = get_quad_uv_rect
	ctx.get_quad_draw_rect = get_quad_draw_rect
end
