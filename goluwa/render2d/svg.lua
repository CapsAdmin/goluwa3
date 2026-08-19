local io = require("io")
local ffi = require("ffi")
local render2d = import("goluwa/render2d/render2d.lua")
local render = import("goluwa/render/render.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local svg_codec = import("goluwa/codecs/svg.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
local Texture = import("goluwa/render/texture.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local msdf = import("goluwa/render2d/msdf.lua")
local math2d = import("goluwa/render2d/math2d.lua")
local objects = import("goluwa/objects/objects.lua")
local SVG = objects.CreateTemplate("svg")

-- Convert a flat contour {x1, y1, x2, y2, ...} to polyline points {{x, y}, ...}
local function contour_to_polyline(contour)
	local poly = {}

	for i = 1, #contour, 2 do
		poly[#poly + 1] = {x = contour[i], y = contour[i + 1]}
	end

	return poly
end

-- Extract and color edges from SVG contours, transformed to texture coordinates
local function extract_svg_edges(contours, view_box, width, height, spread, supersampling)
	local bounds_w = view_box.w
	local bounds_h = view_box.h
	local super_w = width * supersampling
	local super_h = height * supersampling
	local scale_x = super_w / bounds_w
	local scale_y = super_h / bounds_h
	local offset_x = -view_box.x * scale_x
	local offset_y = -view_box.y * scale_y
	local all_edges = {}

	for _, contour in ipairs(contours) do
		local poly = contour_to_polyline(contour)

		-- Transform to texture coordinates (match mask rendering)
		for _, pt in ipairs(poly) do
			pt.x = pt.x * scale_x + offset_x
			pt.y = pt.y * scale_y + offset_y
		end

		local edges = msdf.ColorPolyline(poly)

		for _, e in ipairs(edges) do
			all_edges[#all_edges + 1] = e
		end
	end

	return all_edges
end

local function CreateSDFTexture(decoded, poly, mode, texture_size, spread, supersampling)
	local view_box = assert(decoded.view_box)
	local bounds_w = math.max(view_box.w)
	local bounds_h = math.max(view_box.h)
	local longest_side = math.max(1, math.floor((texture_size) + 0.5))
	local spread = math.max(1, math.floor((spread) + 0.5))
	local width = math.max(1, math.floor(bounds_w / math.max(bounds_w, bounds_h) * longest_side + 0.5))
	local height = math.max(1, math.floor(bounds_h / math.max(bounds_w, bounds_h) * longest_side + 0.5))
	local super_w = width * supersampling
	local super_h = height * supersampling
	-- Create mask by rendering polygon to framebuffer
	local mask_fb = Framebuffer.New{
		width = super_w,
		height = super_h,
		name = "svg",
		clear_color = {0, 0, 0, 0},
		format = "r8g8b8a8_unorm",
		mip_map_levels = "auto",
		min_filter = "linear",
		mag_filter = "linear",
		wrap_s = "clamp_to_border",
		wrap_t = "clamp_to_border",
	}
	local edges = mode == "msdf" and
		extract_svg_edges(decoded.contours, view_box, width, height, spread, supersampling) or
		nil
	local mask_texture = render.ExecuteCommand(function(cmd)
		mask_fb:Begin(cmd)
		local saved_batch = render2d.SaveBatchState()
		render2d.state.runtime.batch.state:ClearPending()
		render2d.PushBlendPreset("alpha")
		render2d.PushScreenSize(super_w, super_h)
		render2d.PushMatrix()
		render2d.LoadIdentity()
		-- Draw the polygon filled with white
		poly:SetColor(1, 1, 1, 1)
		-- Scale polygon to fill the framebuffer
		local scale_x = super_w / view_box.w
		local scale_y = super_h / view_box.h
		local offset_x = -view_box.x * scale_x
		local offset_y = -view_box.y * scale_y
		render2d.Translatef(offset_x, offset_y)
		render2d.Scalef(scale_x, scale_y)
		poly:Draw()
		render2d.FlushBatches("svg_mask")
		render2d.PopMatrix()
		render2d.PopScreenSize()
		render2d.PopBlendMode()
		render2d.RestoreBatchState(saved_batch)
		mask_fb:End(cmd)
		return mask_fb.color_texture
	end)
	local tex_final = render.ExecuteCommand(function(cmd)
		return msdf.Build(
			mask_texture,
			{
				width = width,
				height = height,
				spread = spread * supersampling,
				format = "r8g8b8a8_unorm",
				filter = "linear",
				mode = mode,
				edges = edges,
			}
		)
	end)
	return tex_final, mask_texture
end

local function read_source_text(path)
	local data = vfs.Read(path)

	if data then return data end

	local file = io.open(path, "rb")

	if not file then return nil end

	data = file:read("*a")
	file:close()
	return data
end

SVG:GetSet("Status", "idle")
SVG:GetSet("Error", nil)
SVG:StartStorable()
SVG:GetSet("Mode", "msdf")
SVG:GetSet("TextureSize", 256)
SVG:GetSet("SDFSpread", 0.9)
SVG:EndStorable()

function SVG.New(source, options)
	local self = SVG:CreateObject()

	if options then
		if options.Mode then self:SetMode(options.Mode) end

		if options.TextureSize then self:SetTextureSize(options.TextureSize) end

		if options.SDFSpread then self:SetSDFSpread(options.SDFSpread) end
	end

	if source then self:Load(source) end

	return self
end

function SVG:Load(source)
	assert(source)

	if source:starts_with("<svg") then
		self:ApplyData(source)
		return
	end

	resource.Download(source):Then(function(path)
		local data, err = vfs.Read(path)

		if not data then
			self:Fail(err)
			return
		end

		self:ApplyData(data)
	end):Catch(function(reason)
		self:Fail(reason)
	end)
end

function SVG:ApplyData(data)
	local ok, decoded

	if type(data) == "table" then
		ok, decoded = true, data
	else
		ok, decoded = pcall(svg_codec.Decode, data)
	end

	if not ok then
		self:Fail(decoded)
		return
	end

	self.decoded = decoded
	self.poly = Polygon2D.FromTriangleCoordinates(math2d.TriangulateContoursEvenOdd(decoded.contours))

	if self.Mode ~= "poly" then
		self.sdf_texture, self.mask_texture = CreateSDFTexture(
			decoded,
			self.poly,
			self.Mode,
			self.TextureSize,
			self.SDFSpread * self.TextureSize / 4,
			4
		)
	end

	self.Status = "loaded"
	self.Error = nil
end

function SVG:Fail(reason)
	self.poly = nil
	self.sdf_texture = nil
	self.Status = "error"
	self.Error = tostring(reason)
	wlog("svg load failed for %s: %s", tostring(self.source), self.Error)
end

function SVG:Draw()
	if self.Status ~= "loaded" then return end

	if self.Mode == "msdf" or self.Mode == "sdf" then
		assert(self.sdf_texture)
		render2d.PushSDFTexture(self.sdf_texture)
		render2d.PushSDFTexelRange(self.SDFSpread * self.TextureSize / 4)

		if self.Mode == "msdf" then render2d.PushMSDF(true) end

		render2d.PushSDFUV(0, 1, 1, 0)
		render2d.DrawRectf(0, 0, 1, 1)
		render2d.PopSDFUV()

		if self.Mode == "msdf" then render2d.PopMSDF() end

		render2d.PopSDFTexelRange()
		render2d.PopSDFTexture()
	elseif self.Mode == "poly" then
		self.poly:Draw()
	end
end

return SVG:Register()
