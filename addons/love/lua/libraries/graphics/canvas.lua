local line = import("lua/line.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local shared = import("addons/love/lua/libraries/graphics/shared.lua")
local love = ...

if type(love) == "string" then love = nil end

love = love or import("lua/love.lua")
local ctx = shared.Get(love)
local ENV = ctx.ENV
local ADD_FILTER = ctx.ADD_FILTER
local Canvas = line.TypeTemplate("Canvas", love)
ADD_FILTER(Canvas)

local function get_canvas_depth_format()
	return "d32_sfloat"
end

local function create_canvas_framebuffer(canvas, with_depth) end

local function update_render_size_for_canvas(canvas) end

function Canvas:renderTo(cb)
	local old = love.graphics.getCanvas()
	love.graphics.setCanvas(self)
	local ok, err = pcall(cb)

	if not ok then wlog(err) end

	love.graphics.setCanvas(old)
end

function Canvas:getWidth()
	return self.w
end

function Canvas:getHeight()
	return self.h
end

function Canvas:getDimensions()
	return self.w, self.h
end

function Canvas:getPixelWidth()
	return self.w
end

function Canvas:getPixelHeight()
	return self.h
end

function Canvas:getPixelDimensions()
	return self:getPixelWidth(), self:getPixelHeight()
end

function Canvas:getImageData(x, y, w, h)
	local was_current = ENV.graphics_current_canvas == self

	if was_current then love.graphics.setCanvas() end

	local image_data = love.image._newImageDataFromTexture(self.fb:GetColorTexture())

	if was_current then love.graphics.setCanvas(self) end

	x = math.floor(tonumber(x) or 0)
	y = math.floor(tonumber(y) or 0)
	w = math.floor(tonumber(w) or image_data:getWidth())
	h = math.floor(tonumber(h) or image_data:getHeight())

	if x == 0 and y == 0 and w == image_data:getWidth() and h == image_data:getHeight() then
		return image_data
	end

	local cropped = love.image.newImageData(w, h)
	cropped:paste(image_data, 0, 0, x, y, w, h)
	return cropped
end

function Canvas:newImageData(...)
	return self:getImageData(...)
end

function Canvas:clear(...)
	local args = {...}
	local count = select("#", ...)
	local depth
	local stencil

	-- Extract depth/stencil when present (count > 4 means r,g,b,a + optional stencil/depth)
	if count > 4 then
		if count == 6 then
			depth = args[count]
			stencil = args[count - 1]
		else -- count == 5
			depth = nil
			stencil = args[count]
		end

		if depth == true then depth = 0 elseif not tonumber(depth) then depth = nil end

		if stencil == true then
			stencil = 0
		elseif not tonumber(stencil) then
			stencil = nil
		end
	end

	local colors = {}

	for i = 1, math.min(count, 4) do
		table.insert(colors, args[i])
	end

	if type(colors[1]) == "number" then
		colors[1] = {args[1], args[2], args[3], args[4]}

		-- Remove extra elements left over from the initial numeric array
		for i = #colors, 2, -1 do
			table.remove(colors, i)
		end
	end

	local was_current = ENV.graphics_current_canvas == self
	local cmd = self.fb:GetCommandBuffer()

	if not was_current then
		-- Standalone clear: begin the framebuffer's own render pass on its
		-- command buffer. We do NOT push to the main render command buffer
		-- stack since this is a self-contained operation.
		self.fb:Begin()
	end

	for i, color in ipairs(colors) do
		-- Canvas:clear API receives 0-255 color values; normalize to 0-1 for Vulkan
		local r = math.min(color[1] / 255, 1)
		local g = math.min(color[2] / 255, 1)
		local b = math.min(color[3] / 255, 1)
		local a = math.min(color[4] / 255, 1)
		cmd:ClearAttachments{
			color = {r, g, b, a},
			color_attachment = i - 1,
			w = self.w,
			h = self.h,
		}
	end

	if not was_current then
		cmd:EndRendering()
		-- Transition to shader read layout
		local imageBarriers = {}

		for _, tex in ipairs(self.fb.color_textures) do
			table.insert(
				imageBarriers,
				{
					image = tex:GetImage(),
					srcAccessMask = "color_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "color_attachment_optimal",
					newLayout = "shader_read_only_optimal",
				}
			)
		end

		if self.fb.depth_texture then
			table.insert(
				imageBarriers,
				{
					image = self.fb.depth_texture:GetImage(),
					srcAccessMask = "depth_stencil_attachment_write",
					dstAccessMask = "shader_read",
					oldLayout = "depth_attachment_optimal",
					newLayout = "shader_read_only_optimal",
				}
			)
		end

		cmd:PipelineBarrier{
			srcStage = {"color_attachment_output", "late_fragment_tests"},
			dstStage = {"fragment", "compute"},
			imageBarriers = imageBarriers,
		}

		for _, tex in ipairs(self.fb.color_textures) do
			tex:GetImage().layout = "shader_read_only_optimal"
		end

		if self.fb.depth_texture then
			self.fb.depth_texture:GetImage().layout = "shader_read_only_optimal"
		end

		cmd:End()
		render.SubmitAndWait(cmd)
		self.fb.initialized = true
	end
end

function Canvas:setWrap() end

function Canvas:getWrap() end

function love.graphics.newCanvas(w, h)
	if not w or not h then
		local default_w, default_h = ctx.get_main_surface_dimensions()
		w = w or default_w
		h = h or default_h
	end

	local screen_texture = render.GetScreenTexture()
	local self = line.CreateObject("Canvas", love)
	self.w = w
	self.h = h
	self.format = screen_texture.format or "r8g8b8a8_unorm"
	self.filter_min = ENV.graphics_filter_min
	self.filter_mag = ENV.graphics_filter_mag
	self.filter_anistropy = ENV.graphics_filter_anisotropy
	self.fb = Framebuffer.New{
		width = self.w,
		height = self.h,
		format = self.format,
		clear_color = {0, 0, 0, 0},
		min_filter = self.filter_min,
		mag_filter = self.filter_mag,
	}
	ENV.textures[self] = self.fb:GetColorTexture()
	return self
end

function love.graphics.setCanvas(canvas, ...)
	-- Handle table argument: {canvas, depth = true}
	local depth_option

	if type(canvas) == "table" and canvas[1] then
		local options = canvas
		canvas = options[1]
		depth_option = options.depth
	end

	if canvas then
		-- Recreate framebuffer with depth if requested
		if depth_option and not canvas.fb.depth_texture then
			canvas.fb:EnableDepth()
		end

		ENV.graphics_current_canvas = canvas
		canvas.fb:Begin()
		render.PushCommandBuffer(canvas.fb:GetCommandBuffer())
		render2d.SetScreenSize(canvas.w, canvas.h)
		render2d.BindPipeline()
	else
		local canvas = ENV.graphics_current_canvas

		if canvas then
			-- Flush any pending batched draws before ending the canvas render pass
			render2d.FlushBatches("setCanvas")
			canvas.fb:End()
			render.PopCommandBuffer()
		end

		ENV.graphics_current_canvas = nil
		local width, height = ctx.get_main_surface_dimensions()
		render2d.SetScreenSize(width, height)
	end
end

function love.graphics.getCanvas()
	return ENV.graphics_current_canvas
end

line.RegisterType(Canvas, love)
return love.graphics
