local T = import("test/environment.lua")

local function apply_love_version(love, version)
	version = tostring(version or "11.0.0")
	local major, minor, revision = version:match("^(%d+)%.(%d+)%.?(%d*)$")
	revision = revision ~= "" and revision or "0"
	love._version_major = tonumber(major) or 0
	love._version_minor = tonumber(minor) or 0
	love._version_revision = tonumber(revision) or 0
	love._version = string.format("%d.%d.%d", love._version_major, love._version_minor, love._version_revision)
end

local function new_love_graphics_env(version)
	local love = {_line_env = {}}
	apply_love_version(love, version)
	assert(loadfile("goluwa/love/libraries/image.lua"))(love)
	assert(loadfile("goluwa/love/libraries/graphics.lua"))(love)
	return love
end

local function make_quadrant_image(love)
	local data = love.image.newImageData(2, 2)
	data:setPixel(0, 0, 1, 1, 0, 1)
	data:setPixel(1, 0, 1, 0, 0, 1)
	data:setPixel(0, 1, 0, 1, 0, 1)
	data:setPixel(1, 1, 0, 0.5, 1, 1)
	local image = love.graphics.newImage(data)
	image:setFilter("nearest", "nearest", 1)
	return image
end

T.Test2D("love graphics drawInstanced supports Love vertex shader instance attributes", function()
	local love = new_love_graphics_env("11.0.0")
	local image = make_quadrant_image(love)
	local mesh = love.graphics.newMesh(
		{
			{0, 0, 0, 0, 1, 1, 1, 1},
			{1, 0, 1, 0, 1, 1, 1, 1},
			{0, 1, 0, 1, 1, 1, 1, 1},
			{1, 1, 1, 1, 1, 1, 1, 1},
		},
		image,
		"strip"
	)
	local instances = love.graphics.newMesh(
		{
			{"InstancePosition", "float", 2},
			{"UVOffset", "float", 2},
			{"ImageDim", "float", 2},
			{"ImageShade", "float", 1},
			{"Scale", "float", 2},
		},
		2,
		nil,
		"dynamic"
	)
	mesh:attachAttribute("InstancePosition", instances, "perinstance")
	mesh:attachAttribute("UVOffset", instances, "perinstance")
	mesh:attachAttribute("ImageDim", instances, "perinstance")
	mesh:attachAttribute("ImageShade", instances, "perinstance")
	mesh:attachAttribute("Scale", instances, "perinstance")
	instances:setVertex(1, 32, 32, 0, 0, 0.5, 0.5, 1, 32, 32)
	instances:setVertex(2, 96, 32, 0.5, 0.5, 0.5, 0.5, 1, 32, 32)
	local shader = love.graphics.newShader([[
		varying vec2 uvoff;
		varying vec2 imgdim;
		varying float imgshd;
		#ifdef VERTEX
		attribute vec2 InstancePosition;
		attribute vec2 UVOffset;
		attribute vec2 ImageDim;
		attribute float ImageShade;
		attribute vec2 Scale;
		vec4 position(mat4 transform_projection, vec4 vertex_position)
		{
			uvoff = UVOffset;
			imgdim = ImageDim;
			imgshd = ImageShade;
			vertex_position.xy *= Scale;
			vertex_position.xy += InstancePosition;
			return transform_projection * vertex_position;
		}
		#endif
		#ifdef PIXEL
		vec4 effect(vec4 color, Image tex, vec2 texture_coords, vec2 screen_coords)
		{
			texture_coords = uvoff + imgdim * texture_coords;
			return Texel(tex, texture_coords) * vec4(vec3(imgshd), 1.0) * color;
		}
		#endif
	]])
	love.graphics.clear(0, 0, 0, 1)
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.setShader(shader)
	love.graphics.drawInstanced(mesh, 2)
	love.graphics.setShader()
	return function()
		T.AssertScreenPixel{pos = {40, 40}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {56, 56}, color = {1, 1, 0, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {104, 40}, color = {0, 0.5, 1, 1}, tolerance = 0.1}
		T.AssertScreenPixel{pos = {120, 56}, color = {0, 0.5, 1, 1}, tolerance = 0.1}
	end
end)