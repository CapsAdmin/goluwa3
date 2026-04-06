local line = import("goluwa/love/line.lua")
local shared = import("goluwa/love/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or _G.love

local ctx = shared.Get(love)
local ENV = ctx.ENV

	do
		local Quad = line.TypeTemplate("Quad", love)

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
			local self = line.CreateObject("Quad", love)
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

		line.RegisterType(Quad, love)
	end

return love.graphics
