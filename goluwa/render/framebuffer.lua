local Texture = import("goluwa/render/texture.lua")
local ImageView = import("goluwa/render/vulkan/internal/image_view.lua")
local CommandPool = import("goluwa/render/vulkan/internal/command_pool.lua")
local render = import("goluwa/render/render.lua")
local objects = import("goluwa/objects/objects.lua")
local Framebuffer = objects.CreateTemplate("render_framebuffer")

local function apply_object_tags(obj, tags)
	if not tags then return obj end

	for key, value in pairs(tags) do
		obj:SetObjectTag(key, value)
	end

	return obj
end

local function build_color_image_usage(config)
	local usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"}
	local extra_usage = config.color_image_usage

	if not extra_usage then return usage end

	for _, name in ipairs(extra_usage) do
		local found = false

		for i = 1, #usage do
			if usage[i] == name then
				found = true

				break
			end
		end

		if not found then usage[#usage + 1] = name end
	end

	return usage
end

function Framebuffer.New(config)
	local width = config.width or 512
	local height = config.height or 512
	local samples = config.samples or "1"
	local debug_name = config.name or config.label
	local color_image_usage = build_color_image_usage(config)
	local self = Framebuffer:CreateObject()
	self.width = width
	self.height = height
	self.samples = samples
	self.color_textures = {}
	self.clear_colors = {}
	local formats = config.formats or {config.format or "r8g8b8a8_unorm"}
	local clear_colors = config.clear_colors or {config.clear_color or {0, 0, 0, 1}}

	for i, format in ipairs(formats) do
		local color_texture = Texture.New{
			width = width,
			height = height,
			format = format,
			mip_map_levels = config.mip_map_levels or 1,
			image = {
				usage = color_image_usage,
				samples = samples,
			},
			sampler = {
				min_filter = config.min_filter or "linear",
				mag_filter = config.mag_filter or "linear",
				wrap_s = config.wrap_s or "repeat",
				wrap_t = config.wrap_t or "repeat",
			},
		}
		color_texture:SetDebugName(debug_name and (debug_name .. " color " .. tostring(i)) or nil)
		apply_object_tags(color_texture, config.object_tags)
		table.insert(self.color_textures, color_texture)
		table.insert(self.clear_colors, clear_colors[i] or {0, 0, 0, 1})
	end

	self.color_texture = self.color_textures[1]
	self.clear_color = self.clear_colors[1]

	if config.depth then
		self.depth_texture = Texture.New{
			width = width,
			height = height,
			format = config.depth_format or "d32_sfloat",
			image = {
				usage = {"depth_stencil_attachment", "sampled", "transfer_src"},
				properties = "device_local",
				samples = samples,
			},
			view = {
				aspect = "depth",
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
			},
		}
		self.depth_texture:SetDebugName(debug_name and (debug_name .. " depth") or nil)
		apply_object_tags(self.depth_texture, config.object_tags)
	end

	self.command_pool = render.GetCommandPool()
	self.cmd = self.command_pool:AllocateCommandBuffer()
	return self
end

function Framebuffer:Begin(cmd, load_op)
	cmd = cmd or self.cmd
	load_op = load_op or "clear"
	self._active_cmd = cmd

	if cmd == self.cmd then
		self.cmd:Reset()
		self.cmd:Begin()
	end

	-- Transition color attachments to optimal layout
	local imageBarriers = {}

	for _, tex in ipairs(self.color_textures) do
		table.insert(
			imageBarriers,
			{
				image = tex:GetImage(),
				srcAccessMask = "none",
				dstAccessMask = "color_attachment_write",
				oldLayout = self.initialized and "shader_read_only_optimal" or "undefined",
				newLayout = "color_attachment_optimal",
			}
		)
	end

	if self.depth_texture then
		table.insert(
			imageBarriers,
			{
				image = self.depth_texture:GetImage(),
				srcAccessMask = "none",
				dstAccessMask = "depth_stencil_attachment_write",
				oldLayout = self.initialized and "shader_read_only_optimal" or "undefined",
				newLayout = "depth_stencil_attachment_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			}
		)
	end

	cmd:PipelineBarrier{
		srcStage = "top_of_pipe",
		dstStage = {"color_attachment_output", "early_fragment_tests", "late_fragment_tests"},
		imageBarriers = imageBarriers,
	}
	-- Begin rendering
	local color_attachments = {}

	for i, tex in ipairs(self.color_textures) do
		table.insert(
			color_attachments,
			{
				color_image_view = tex:GetView(),
				clear_color = self.clear_colors[i],
				load_op = load_op,
				store_op = "store",
			}
		)
	end

	local rendering_info = {
		color_attachments = color_attachments,
		w = self.width,
		h = self.height,
	}

	if self.depth_texture then
		rendering_info.depth_image_view = self.depth_texture:GetView()
		rendering_info.clear_depth = 1.0
		rendering_info.depth_store = true
	end

	cmd:BeginRendering(rendering_info)
	cmd:SetViewport(0.0, 0.0, self.width, self.height, 0.0, 1.0)
	cmd:SetScissor(0, 0, self.width, self.height)
	return cmd
end

function Framebuffer:End(cmd)
	cmd = cmd or render.GetCommandBuffer() or self.cmd
	cmd:EndRendering()
	-- Transition color attachments to shader read layout
	local imageBarriers = {}

	for _, tex in ipairs(self.color_textures) do
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

	if self.depth_texture then
		table.insert(
			imageBarriers,
			{
				image = self.depth_texture:GetImage(),
				srcAccessMask = "depth_stencil_attachment_write",
				dstAccessMask = "shader_read",
				oldLayout = "depth_attachment_optimal",
				newLayout = "shader_read_only_optimal",
			-- aspect is automatically determined from image format by PipelineBarrier
			}
		)
	end

	cmd:PipelineBarrier{
		srcStage = {"color_attachment_output", "late_fragment_tests"},
		dstStage = {"fragment", "compute"},
		imageBarriers = imageBarriers,
	}
	self.initialized = true

	for _, tex in ipairs(self.color_textures) do
		tex:GetImage().layout = "shader_read_only_optimal"
	end

	if self.depth_texture then
		self.depth_texture:GetImage().layout = "shader_read_only_optimal"
	end

	if cmd == self.cmd then
		self.cmd:End()
		render.SubmitAndWait(self.cmd)
	end
end

function Framebuffer:GetAttachment(key)
	if type(key) == "number" then return self.color_textures[key] end

	if key == "color" then
		return self.color_textures[1]
	elseif key == "depth" and self.depth_texture then
		return self.depth_texture
	end

	return nil
end

function Framebuffer:GetColorTexture()
	return self.color_textures[1]
end

function Framebuffer:GetDepthTexture()
	return self.depth_texture
end

function Framebuffer:GetCommandBuffer()
	return self.cmd
end

function Framebuffer:GetExtent()
	return {width = self.width, height = self.height}
end

function Framebuffer:Clear(cmd, key, r, g, b, depth, stencil)
	-- Detect if first arg is a command buffer or a clear parameter
	local is_cmd = type(cmd) == "table" and cmd.GetImage

	if not is_cmd then
		-- First arg is actually 'key', shift everything
		-- User passes: Clear(key, r, g, b, depth, stencil)
		-- Lua sees: cmd=key, key=r, g=g, b=b, depth=depth, stencil=stencil
		local saved_depth = depth
		local saved_stencil = stencil
		b = g
		g = r
		r = key
		key = cmd
		cmd = self._active_cmd or self.cmd
		-- Restore depth/stencil for color clears (they were shifted into b/g)
		if type(key) == "string" and key ~= "depth" then
			depth = saved_depth
			stencil = saved_stencil
		end
	end

	if type(key) == "string" then
		if key == "color" then
			key = 1
		elseif key == "depth" then
			assert(self.depth_texture, "Framebuffer has no depth texture")
			-- After shift: r=depth_val, g=stencil_val (from user's Clear("depth", depth_val, stencil_val))
			cmd:ClearAttachments{
				depth = r or 1.0,
				stencil = g or 0,
				w = self.width,
				h = self.height,
			}

			return
		else
			error("Unknown clear key: " .. tostring(key))
		end
	end

	key = tonumber(key)
	assert(key and key >= 1 and key <= #self.color_textures, "Invalid color attachment index: " .. tostring(key))

	local clear_color = r ~= nil and {r, g, b, a} or self.clear_colors[key]
	cmd:ClearAttachments{
		color = clear_color,
		color_attachment = key - 1,
		w = self.width,
		h = self.height,
	}
end

function Framebuffer:ClearAll(cmd, r, g, b, a, depth, stencil)
	if type(cmd) ~= "table" or not cmd.GetImage then
		-- First arg is actually 'r', shift everything
		depth = b
		b = a
		a = g
		g = r
		r = cmd
		cmd = self._active_cmd or self.cmd
	end

	-- Clear each color attachment
	for i = 1, #self.color_textures do
		local clear_color = r ~= nil and {r, g, b, a} or self.clear_colors[i]
		cmd:ClearAttachments{
			color = clear_color,
			color_attachment = i - 1,
			w = self.width,
			h = self.height,
		}
	end

	-- Clear depth and stencil if present
	if self.depth_texture then
		cmd:ClearAttachments{
			depth = depth or 1.0,
			stencil = stencil or 0,
			w = self.width,
			h = self.height,
		}
	end
end

return Framebuffer:Register()
