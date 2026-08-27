local io = require("io")
local render2d = import("goluwa/render2d/render2d.lua")
local resource = import("goluwa/resource.lua")
local vfs = import("goluwa/vfs.lua")
local svg_codec = import("goluwa/codecs/svg.lua")
local Polygon2D = import("goluwa/render2d/polygon_2d.lua")
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

-- Extract and color edges from SVG contours, transformed to final texture coordinates
local function extract_svg_edges(contours, view_box, width, height)
	local scale_x = width / view_box.w
	local scale_y = height / view_box.h
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

local function CreateSDFTexture(decoded, mode, texture_size, spread)
	local view_box = assert(decoded.view_box)
	local bounds_w = math.max(view_box.w)
	local bounds_h = math.max(view_box.h)
	local longest_side = math.max(1, math.floor((texture_size) + 0.5))
	local spread = math.max(1, math.floor((spread) + 0.5))
	local width = math.max(1, math.floor(bounds_w / math.max(bounds_w, bounds_h) * longest_side + 0.5))
	local height = math.max(1, math.floor(bounds_h / math.max(bounds_w, bounds_h) * longest_side + 0.5))
	local edges = extract_svg_edges(decoded.contours, view_box, width, height)
	return msdf.Build{
		width = width,
		height = height,
		spread = spread,
		format = "r8g8b8a8_unorm",
		filter = "linear",
		mode = mode,
		edges = edges,
	}
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
		self.sdf_texture = CreateSDFTexture(
			decoded,
			self.Mode,
			self.TextureSize,
			self.SDFSpread * self.TextureSize / 4
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
