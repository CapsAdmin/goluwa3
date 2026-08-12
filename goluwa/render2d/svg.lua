local io = require("io")
local render2d = import("goluwa/render2d/render2d.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local svg_codec = import("goluwa/codecs/svg.lua")
local objects = import("goluwa/objects/objects.lua")
local SVG = objects.CreateTemplate("svg")

local function read_source_text(path)
	local data = vfs.Read(path)

	if data then return data end

	local file = io.open(path, "rb")

	if not file then return nil end

	data = file:read("*a")
	file:close()
	return data
end

function SVG.New(source, options)
	local self = SVG:CreateObject{
		status = "idle",
		options = options or {},
		request_id = 0,
	}
	self.options.mode = self.options.mode or "msdf"

	if source then self:Load(source) end

	return self
end

function SVG:Load(source)
	self.request_id = self.request_id + 1
	local request_id = self.request_id
	self.source = source

	if not source or source == "" then
		self.poly = nil
		self.decoded = nil
		self.sdf_texture = nil
		self.status = "idle"
		self.error = nil
		return
	end

	self.status = "loading"
	self.error = nil

	if source:find("<svg", 1, true) then
		self:ApplyData(source, request_id)
		return
	end

	local local_data = read_source_text(source)

	if local_data then
		self:ApplyData(local_data, request_id)
		return
	end

	resource.Download(source):Then(function(path)
		local data = read_source_text(path)

		if not data then
			self:Fail("unable to read SVG source: " .. tostring(path), request_id)
			return
		end

		self:ApplyData(data, request_id)
	end):Catch(function(reason)
		self:Fail(reason or (tostring(source) .. " not found"), request_id)
	end)
end

function SVG:ApplyData(data, request_id)
	local ok, poly, decoded = pcall(svg_codec.CreatePolygon2D, data, self.options)

	if not ok then
		self:Fail(poly, request_id)
		return
	end

	local sdf_texture, _, sdf_meta = svg_codec.CreateSDFTexture(decoded, self.options)

	if request_id ~= self.request_id then return end

	self.poly = poly
	self.decoded = decoded
	self.sdf_texture = sdf_texture
	self.texel_range = sdf_meta.spread

	--self.sdf_is_msdf = sdf_meta and sdf_meta.is_msdf == true
	if sdf_meta.is_msdf then self.options.mode = "msdf" end

	self.status = "loaded"
	self.error = nil
end

function SVG:Fail(reason, request_id)
	if request_id ~= self.request_id then return end

	self.poly = nil
	self.decoded = nil
	self.sdf_texture = nil
	self.status = "error"
	self.error = tostring(reason)
	wlog("svg load failed for %s: %s", tostring(self.source), self.error)
end

function SVG:Draw(x, y, width, height, useSDF)
	if self.status ~= "loaded" then return end

	local decoded = self.decoded
	local view_box = decoded.view_box or {x = 0, y = 0, w = decoded.width, h = decoded.height}
	local bounds_w = math.max(1e-6, view_box.w)
	local bounds_h = math.max(1e-6, view_box.h)

	if width <= 0 or height <= 0 then return end

	if self.options.mode == "msdf" or self.options.mode == "sdf" then
		assert(self.sdf_texture)
		local scale = math.min(width / bounds_w, height / bounds_h)
		local draw_w = bounds_w * scale
		local draw_h = bounds_h * scale
		local offset_x = x + (width - draw_w) / 2
		local offset_y = y + (height - draw_h) / 2
		render2d.PushSDFTexture(self.sdf_texture)
		render2d.PushSDFTexelRange(self.texel_range)
		render2d.PushMSDFEnabled(self.options.mode == "msdf")
		render2d.PushTexture()
		render2d.SetTexture(nil)
		render2d.DrawRectUV2f(offset_x, offset_y, draw_w, draw_h, 0, 1, 1, 0)
		render2d.PopTexture()
		render2d.PopMSDFEnabled()
		render2d.PopSDFTexture()
		render2d.PopSDFTexelRange()
	elseif self.options.mode == "poly" then
		render2d.PushMatrix()
		render2d.Translatef(x, y)
		local scale = math.min(width / bounds_w, height / bounds_h)
		render2d.Scalef(scale, scale)
		render2d.Translatef(-view_box.x, -view_box.y)
		self.poly:Draw()
		render2d.PopMatrix()
	else
		error("invalid mode " .. self.options.mode)
	end
end

return SVG:Register()
