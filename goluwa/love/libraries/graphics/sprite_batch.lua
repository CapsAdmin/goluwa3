local line = import("goluwa/love/line.lua")
local gfx = import("goluwa/render2d/gfx.lua")
local render2d = import("goluwa/render2d/render2d.lua")
return function(ctx)
	local love = ctx.love
	local parse_color_bytes = ctx.parse_color_bytes
	local get_api_default_alpha = ctx.get_api_default_alpha
	local get_internal_color = ctx.get_internal_color
	local SpriteBatch = line.TypeTemplate("SpriteBatch")

	local function store_entry(self, id, entry)
		self.entries[id] = entry
	end

	function SpriteBatch:set(id, q, ...)
		id = id or 1
		local is_quad = line.Type(q) == "Quad" or
			(
				type(q) == "table" and
				type(q.x) == "number" and
				type(q.y) == "number" and
				type(q.w) == "number" and
				type(q.h) == "number" and
				type(q.sw) == "number" and
				type(q.sh) == "number"
			)

		if is_quad then
			local x, y, r, sx, sy, ox, oy, kx, ky = ...
			store_entry(
				self,
				id,
				{
					quad = q,
					x = x or 0,
					y = y or 0,
					r = r or 0,
					sx = sx or 1,
					sy = sy or sx or 1,
					ox = ox or 0,
					oy = oy or 0,
					kx = kx or 0,
					ky = ky or 0,
				}
			)
		else
			local x, y, r, sx, sy, ox, oy, kx, ky = q, ...
			store_entry(
				self,
				id,
				{
					x = x or 0,
					y = y or 0,
					r = r or 0,
					sx = sx or 1,
					sy = sy or sx or 1,
					ox = ox or 0,
					oy = oy or 0,
					kx = kx or 0,
					ky = ky or 0,
				}
			)
		end
	end

	SpriteBatch.setq = SpriteBatch.set

	function SpriteBatch:add(...)
		local id = self.i

		if id <= self.size then self:set(id, ...) end

		self.i = id + 1
		return id
	end

	SpriteBatch.addq = SpriteBatch.add

	function SpriteBatch:setColor(r, g, b, a)
		r, g, b, a = parse_color_bytes(r, g, b, a, get_api_default_alpha())
		self.r = r / 255
		self.g = g / 255
		self.b = b / 255
		self.a = a / 255
	end

	function SpriteBatch:clear()
		self.i = 1
		self.entries = {}
	end

	function SpriteBatch:flush()
		return self
	end

	function SpriteBatch:getImage()
		return self.image
	end

	function SpriteBatch:bind() end

	function SpriteBatch:unbind() end

	function SpriteBatch:setImage(image)
		self.img = image
		self.w = image:getWidth()
		self.h = image:getHeight()
	end

	function SpriteBatch:getImage()
		return self.img
	end

	function SpriteBatch:Draw(...)
		local x, y, r, sx, sy, ox, oy, kx, ky = ...
		x = x or 0
		y = y or 0
		r = r or 0
		sx = sx or 1
		sy = sy or sx
		ox = ox or 0
		oy = oy or 0
		kx = kx or 0
		ky = ky or 0
		local cr, cg, cb, ca = get_internal_color()
		local restore = {cr, cg, cb, ca}
		love.graphics.setColor(cr * (self.r or 1), cg * (self.g or 1), cb * (self.b or 1), ca * (self.a or 1))
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		render2d.Rotate(r)

		if ox ~= 0 or oy ~= 0 then render2d.Translatef(-ox * sx, -oy * sy) end

		if kx ~= 0 or ky ~= 0 then render2d.Shear(kx, ky) end

		render2d.Scalef(sx, sy)

		for i = 1, self.i - 1 do
			local entry = self.entries[i]

			if entry then
				if entry.quad then
					love.graphics.drawq(
						self.img,
						entry.quad,
						entry.x,
						entry.y,
						entry.r,
						entry.sx,
						entry.sy,
						entry.ox,
						entry.oy,
						entry.kx,
						entry.ky
					)
				else
					love.graphics.draw(
						self.img,
						entry.x,
						entry.y,
						entry.r,
						entry.sx,
						entry.sy,
						entry.ox,
						entry.oy,
						entry.kx,
						entry.ky
					)
				end
			end
		end

		render2d.PopMatrix()
		love.graphics.setColor(unpack(restore))
	end

	function love.graphics.newSpriteBatch(image, size, usagehint)
		size = size or 1000
		local self = line.CreateObject("SpriteBatch")
		local poly = gfx.CreatePolygon2D(size * 6)
		self.size = size
		self.poly = poly
		self.img = image
		self.w = image:getWidth()
		self.h = image:getHeight()
		self.entries = {}
		self.r = 1
		self.g = 1
		self.b = 1
		self.a = 1
		self.i = 1
		return self
	end

	line.RegisterType(SpriteBatch)
end
