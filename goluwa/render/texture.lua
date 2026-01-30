local ffi = require("ffi")
local render = require("render.render")
local Vec2 = require("structs.vec2")
local Buffer = require("render.vulkan.internal.buffer")
local CommandPool = require("render.vulkan.internal.command_pool")
local Fence = require("render.vulkan.internal.fence")
local ImageView = require("render.vulkan.internal.image_view")
local Image = require("render.vulkan.internal.image")
local Sampler = require("render.vulkan.internal.sampler")
local codec = require("codec")
local resource = require("resource")
local prototype = require("prototype")
local Texture = prototype.CreateTemplate("render_texture")
-- Texture cache for path-based textures
local texture_cache = {}
local temp_fence = nil

local function get_bytes_per_pixel(format)
	if
		format == "r8g8b8a8_unorm" or
		format == "r8g8b8a8_srgb" or
		format == "b8g8r8a8_unorm" or
		format == "b8g8r8a8_srgb"
	then
		return 4
	elseif format == "r32g32b32a32_sfloat" then
		return 16
	elseif format == "r16g16b16a16_sfloat" or format == "r16g16b16a16_unorm" then
		return 8
	elseif format == "r32_sfloat" then
		return 4
	elseif format == "r16_sfloat" then
		return 2
	elseif format == "r8_unorm" then
		return 1
	elseif format == "r8g8_unorm" then
		return 2
	end

	return 4
end

-- Fallback checkerboard texture (pink and black)
local fallback_texture = nil

local function create_fallback_texture()
	if fallback_texture then return fallback_texture end

	-- Create 8x8 pink/black checkerboard pattern
	local size = 8
	local buffer = ffi.new("uint8_t[?]", size * size * 4)
	local pink = {255, 0, 255, 255}
	local black = {0, 0, 0, 255}

	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local is_pink = ((x + y) % 2) == 0
			local color = is_pink and pink or black
			local idx = (y * size + x) * 4
			buffer[idx + 0] = color[1]
			buffer[idx + 1] = color[2]
			buffer[idx + 2] = color[3]
			buffer[idx + 3] = color[4]
		end
	end

	fallback_texture = Texture.New(
		{
			width = size,
			height = size,
			format = "r8g8b8a8_unorm",
			buffer = buffer,
			sampler = {
				min_filter = "nearest",
				mag_filter = "nearest",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
	)
	return fallback_texture
end

function Texture.GetFallback()
	return create_fallback_texture()
end

function Texture.ClearCache()
	texture_cache = {}
end

function Texture:__tostring2()
	return "[" .. tostring(self.config.path) .. "]"
end

function Texture.New(config)
	-- Check cache if path is provided
	local cache_key = config.cache_key or config.path

	if cache_key and texture_cache[cache_key] then
		return texture_cache[cache_key]
	end

	local self = Texture:CreateObject({
		config = config,
		is_ready = false,
	})

	local function load(img_or_err)
		local reflectivity = nil -- VTF specifc
		local buffer_data = nil
		local is_compressed = false
		local vulkan_info = nil

		if img_or_err then
			-- hacky way to get the prop from vtf to vmt where it belongs
			reflectivity = img_or_err.reflectivity
			local img = img_or_err
			config.width = config.width or img.width
			config.height = config.height or img.height

			-- Handle images that already have a vulkan format (DDS, EXR, etc.)
			if img.vulkan_format then
				config.format = config.format or img.vulkan_format
				is_compressed = img.is_compressed
				vulkan_info = img
				buffer_data = img.data
			else
				config.format = config.format or "r8g8b8a8_unorm"
				buffer_data = img.buffer:GetBuffer()
			end
		end

		-- Use buffer from config or from path loading
		buffer_data = config.buffer or buffer_data
		-- Calculate mip levels
		local mip_levels = config.mip_map_levels or 1

		if mip_levels == "auto" then mip_levels = 999 end

		-- For compressed images, use mip count from file and don't generate mipmaps
		if vulkan_info and vulkan_info.mip_count and vulkan_info.mip_count > 1 then
			mip_levels = vulkan_info.mip_count
		elseif mip_levels > 1 then
			assert(config.width and config.height, "width and height required for mipmap generation")
			mip_levels = math.floor(math.log(math.max(config.width, config.height), 2)) + 1
		end

		-- Shared parameters for overriding
		local width = config.width
		local height = config.height
		local format = config.format or "r8g8b8a8_unorm"

		if config.srgb and not format:ends_with("_srgb") then
			local test = format:replace("_unorm", "_srgb")

			if require("bindings.vk").e.VkFormat(test) then
				format = test
			else
				print("Warning: sRGB format requested but not available for", format)
			end
		end

		-- Create or use image
		local image

		if config.image == false then
			image = nil
		elseif config.image and config.image.ptr then
			-- Already an Image object
			image = config.image
		else
			-- Create image from config
			local image_config = config.image or {}
			-- Compressed formats cannot be used as color attachments or transfer_src
			local default_usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"}

			if is_compressed then default_usage = {"sampled", "transfer_dst"} end

			image = render.CreateImage(
				{
					width = image_config.width or width,
					height = image_config.height or height,
					format = image_config.format or format,
					usage = image_config.usage or default_usage,
					properties = image_config.properties or "device_local",
					samples = image_config.samples,
					mip_levels = image_config.mip_levels or mip_levels,
					tiling = image_config.tiling,
					image_type = image_config.image_type,
					depth = image_config.depth,
					array_layers = image_config.array_layers,
					sharing_mode = image_config.sharing_mode,
					initial_layout = image_config.initial_layout,
					flags = image_config.flags,
				}
			)
		end

		-- Create or use view
		local view

		if config.view == false then
			view = nil
		elseif config.view and config.view.ptr then
			-- Already a View object
			view = config.view
		elseif image then
			-- Create view from config
			local view_config = config.view or {}
			view = image:CreateView(
				{
					view_type = view_config.view_type,
					format = view_config.format or format,
					aspect = view_config.aspect,
					base_mip_level = view_config.base_mip_level,
					level_count = view_config.level_count,
					base_array_layer = view_config.base_array_layer,
					layer_count = view_config.layer_count,
					component_r = view_config.component_r,
					component_g = view_config.component_g,
					component_b = view_config.component_b,
					component_a = view_config.component_a,
					flags = view_config.flags,
				}
			)
		end

		-- Create or use sampler
		local sampler

		if config.sampler == false then
			sampler = nil
		elseif config.sampler and config.sampler.ptr then
			-- Already a Sampler object
			sampler = config.sampler
		else
			-- Create sampler from config
			local sampler_config = config.sampler or {}
			sampler = render.CreateSampler(
				{
					min_filter = sampler_config.min_filter or "linear",
					mag_filter = sampler_config.mag_filter or "linear",
					mipmap_mode = sampler_config.mipmap_mode or "linear",
					wrap_s = sampler_config.wrap_s or "repeat",
					wrap_t = sampler_config.wrap_t or "repeat",
					wrap_r = sampler_config.wrap_r or "repeat",
					max_lod = sampler_config.max_lod or mip_levels,
					min_lod = sampler_config.min_lod,
					mip_lod_bias = sampler_config.mip_lod_bias,
					anisotropy = sampler_config.anisotropy or 16,
					border_color = sampler_config.border_color,
					unnormalized_coordinates = sampler_config.unnormalized_coordinates,
					compare_enable = sampler_config.compare_enable,
					compare_op = sampler_config.compare_op,
					flags = sampler_config.flags,
				}
			)
		end

		self.image = image
		self.view = view
		self.sampler = sampler
		self.mip_map_levels = mip_levels
		self.format = format
		self.is_compressed = is_compressed
		self.vulkan_info = vulkan_info

		if buffer_data and image then
			if is_compressed and vulkan_info then
				-- Upload compressed data with all mipmaps
				self:UploadCompressed(buffer_data, vulkan_info)
			else
				-- If we're generating mipmaps, keep mip level 0 in transfer_dst after upload
				self:Upload(buffer_data, mip_levels > 1)

				-- Auto-generate mipmaps if requested
				if mip_levels > 1 then self:GenerateMipmaps() end
			end
		elseif image then
			-- If no buffer is provided, transition the image to an appropriate layout
			-- Only transition to shader_read_only_optimal if the image has sampled usage
			local has_sampled = false

			if type(image.usage) == "table" then
				for _, usage in ipairs(image.usage) do
					if usage == "sampled" then
						has_sampled = true

						break
					end
				end
			end

			if has_sampled then
				image:TransitionLayout("undefined", "shader_read_only_optimal")
			end
		end

		self.is_ready = true
		self.reflectivity = reflectivity
	end

	if cache_key then texture_cache[cache_key] = self end

	if config.path then
		local fallback = create_fallback_texture()
		self.image = fallback.image
		self.view = fallback.view
		self.sampler = fallback.sampler

		resource.Download(config.path):Then(function(p)
			local ok, img_or_err = pcall(codec.DecodeFile, p)

			if ok and img_or_err then
				load(img_or_err)
			else
				if ok == false then
					debug.trace()
					print("Warning: Failed to load texture:", config.path, img_or_err)
				end

				self.is_ready = true
			end
		end):Catch(function(err)
			print("Warning: Failed to download texture:", config.path, err)
			self.is_ready = true
		end)
	else
		load()
	end

	return self
end

local cache = {}

function Texture.FromColor(color, config)
	if not config then
		if cache[tostring(color)] then return cache[tostring(color)] end
	end

	local has_config = config ~= nil
	config = config or {}
	local tex = Texture.New(
		{
			buffer = ffi.new("uint8_t[4]", color:Get255():Unpack()),
			width = config.width or 1,
			height = config.height or 1,
			format = config.format or "r8g8b8a8_unorm",
		}
	)

	if not has_config then cache[tostring(color)] = tex end

	return tex
end

function Texture:CopyFrom(other, width, height, srcX, srcY, dstX, dstY)
	local cmd_pool = render.GetCommandPool()
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Transition src to transfer_src
	cmd:PipelineBarrier(
		{
			srcStage = "all_commands",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = other:GetImage(),
					oldLayout = other:GetImage().layout or "shader_read_only_optimal",
					newLayout = "transfer_src_optimal",
					srcAccessMask = "memory_read",
					dstAccessMask = "transfer_read",
				},
			},
		}
	)
	-- Transition dst to transfer_dst
	cmd:PipelineBarrier(
		{
			srcStage = "all_commands",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self:GetImage(),
					oldLayout = self:GetImage().layout or "shader_read_only_optimal",
					newLayout = "transfer_dst_optimal",
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
				},
			},
		}
	)
	cmd:CopyImageToImage(other:GetImage(), self:GetImage(), width, height, srcX, srcY, dstX, dstY)
	-- Transition back
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "all_commands",
			imageBarriers = {
				{
					image = other:GetImage(),
					oldLayout = "transfer_src_optimal",
					newLayout = other:GetImage().layout or "shader_read_only_optimal",
					srcAccessMask = "transfer_read",
					dstAccessMask = "memory_read",
				},
				{
					image = self:GetImage(),
					oldLayout = "transfer_dst_optimal",
					newLayout = "shader_read_only_optimal",
					srcAccessMask = "transfer_write",
					dstAccessMask = "memory_read",
				},
			},
		}
	)
	cmd:End()
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
end

function Texture:Upload(data, keep_in_transfer_dst)
	if not self.image then error("Cannot upload: texture has no image") end

	local device = render.GetDevice()
	local queue = render.GetQueue()
	local width, height, x, y, buffer

	if type(data) == "table" then
		width = data.width
		height = data.height
		x = data.x
		y = data.y
		buffer = data.buffer
	else
		width = self.image:GetWidth()
		height = self.image:GetHeight()
		x = 0
		y = 0
		buffer = data
	end

	if type(buffer) == "table" and buffer.pixels then buffer = buffer.pixels end

	local pixel_count = width * height
	local bytes_per_pixel = get_bytes_per_pixel(self.format)
	-- Create staging buffer
	local staging_buffer = Buffer.New(
		{
			device = device,
			size = pixel_count * bytes_per_pixel,
			usage = "transfer_src",
			properties = {"host_visible", "host_coherent"},
		}
	)
	staging_buffer:CopyData(buffer, pixel_count * bytes_per_pixel)
	-- Copy to image using command buffer
	local cmd_pool = render.GetCommandPool()
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Transition image to transfer dst (only mip level 0)
	cmd:PipelineBarrier(
		{
			srcStage = "compute",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
					base_mip_level = 0,
					level_count = 1,
				},
			},
		}
	)
	-- Copy buffer to image
	cmd:CopyBufferToImage(staging_buffer, self.image, width, height, x, y)

	-- Only transition to final layout if not keeping in transfer_dst for mipmap generation
	if not keep_in_transfer_dst then
		-- Determine final layout based on image usage
		local final_layout = "general"
		local dst_stage = "compute"

		if type(self.image.usage) == "table" then
			for _, usage in ipairs(self.image.usage) do
				if usage == "sampled" then
					final_layout = "shader_read_only_optimal"
					dst_stage = "fragment"

					break
				end
			end
		end

		-- Transition to final layout
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = dst_stage,
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "transfer_write",
						dstAccessMask = "shader_read",
						oldLayout = "transfer_dst_optimal",
						newLayout = final_layout,
						base_mip_level = 0,
						level_count = 1,
					},
				},
			}
		)
	end

	cmd:End()
	-- Submit and wait
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
end

function Texture:UploadCompressed(data, vulkan_info)
	if not self.image then error("Cannot upload: texture has no image") end

	local device = render.GetDevice()
	local queue = render.GetQueue()
	local mip_count = vulkan_info.mip_count
	local total_size = vulkan_info.data_size
	-- Create staging buffer for all data
	local staging_buffer = Buffer.New(
		{
			device = device,
			size = total_size,
			usage = "transfer_src",
			properties = {"host_visible", "host_coherent"},
		}
	)
	staging_buffer:CopyData(data, total_size)
	-- Copy to image using command buffer
	local cmd_pool = render.GetCommandPool()
	local cmd = cmd_pool:AllocateCommandBuffer()
	cmd:Begin()
	-- Transition all mip levels to transfer dst
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "none",
					dstAccessMask = "transfer_write",
					oldLayout = "undefined",
					newLayout = "transfer_dst_optimal",
					base_mip_level = 0,
					level_count = mip_count,
				},
			},
		}
	)

	-- Copy each mip level from the staging buffer
	for mip = 1, mip_count do
		local mip_info = vulkan_info.mip_info[mip]

		if mip_info then
			cmd:CopyBufferToImageMip(
				staging_buffer,
				self.image,
				mip_info.width,
				mip_info.height,
				mip - 1, -- mip level (0-indexed)
				mip_info.offset,
				mip_info.size
			)
		end
	end

	-- Transition all mip levels to shader read optimal
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "transfer_write",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_dst_optimal",
					newLayout = "shader_read_only_optimal",
					base_mip_level = 0,
					level_count = mip_count,
				},
			},
		}
	)
	cmd:End()
	-- Submit and wait
	local fence = Fence.New(device)
	queue:SubmitAndWait(device, cmd, fence)
end

function Texture:GetImage()
	return self.image
end

function Texture:GetView()
	return self.view
end

function Texture:GetSampler()
	return self.sampler
end

function Texture:GetMipMapLevels()
	return self.mip_map_levels or 1
end

function Texture:GetWidth()
	return self.image and self.image:GetWidth() or 0
end

function Texture:GetHeight()
	return self.image and self.image:GetHeight() or 0
end

function Texture:GetSize()
	return self.image and Vec2(self.image:GetWidth(), self.image:GetHeight()) or Vec2(0, 0)
end

function Texture:IsReady()
	return self.is_ready
end

function Texture:OnRemove()
	local event = require("event")
	event.Call("TextureRemoved", self)
	local cache_key = self.config.cache_key or self.config.path

	if cache_key and texture_cache[cache_key] == self then
		texture_cache[cache_key] = nil
	end

	if self.image then self.image:Remove() end

	if self.view then self.view:Remove() end

	if self.sampler then self.sampler:Remove() end
end

function Texture:GenerateMipmaps(initial_layout, cmd)
	if not self.image or self.mip_map_levels <= 1 then return end

	local device = render.GetDevice()
	local queue = render.GetQueue()
	local command_pool = render.GetCommandPool()
	local internal_cmd = false

	if not cmd then
		cmd = command_pool:AllocateCommandBuffer()
		cmd:Begin()
		internal_cmd = true
	end

	local is_cube = self:IsCubemap()
	local layers = is_cube and 6 or 1
	-- Determine initial layout
	local old_layout = initial_layout or "transfer_dst_optimal"
	local src_access = "transfer_read"
	local src_stage = "transfer"

	if old_layout == "transfer_dst_optimal" then
		src_access = "transfer_write"
		src_stage = "transfer"
	elseif old_layout == "shader_read_only_optimal" then
		src_access = "shader_read"
		src_stage = "fragment"
	elseif old_layout == "color_attachment_optimal" then
		src_access = "color_attachment_write"
		src_stage = "color_attachment_output"
	end

	-- Transition first mip level (0) to transfer_src
	cmd:PipelineBarrier(
		{
			srcStage = src_stage,
			dstStage = "transfer",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = src_access,
					dstAccessMask = "transfer_read",
					oldLayout = old_layout,
					newLayout = "transfer_src_optimal",
					base_mip_level = 0,
					level_count = 1,
					layer_count = layers,
				},
			},
		}
	)
	local mip_width = self.image:GetWidth()
	local mip_height = self.image:GetHeight()

	-- Generate each mip level by blitting from the previous level
	for i = 1, self.mip_map_levels - 1 do
		local next_mip_width = math.max(1, math.floor(mip_width / 2))
		local next_mip_height = math.max(1, math.floor(mip_height / 2))
		-- Transition current mip level to transfer_dst before blitting into it
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = "transfer",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "none",
						dstAccessMask = "transfer_write",
						oldLayout = "undefined",
						newLayout = "transfer_dst_optimal",
						base_mip_level = i,
						level_count = 1,
						layer_count = layers,
					},
				},
			}
		)
		-- Blit from previous mip level to current mip level
		cmd:BlitImage(
			{
				src_image = self.image,
				dst_image = self.image,
				src_mip_level = i - 1,
				dst_mip_level = i,
				src_width = mip_width,
				src_height = mip_height,
				dst_width = next_mip_width,
				dst_height = next_mip_height,
				src_layout = "transfer_src_optimal",
				dst_layout = "transfer_dst_optimal",
				filter = "linear",
				src_layer_count = layers,
				dst_layer_count = layers,
			}
		)
		-- Transition current mip level from transfer_dst to transfer_src
		cmd:PipelineBarrier(
			{
				srcStage = "transfer",
				dstStage = "transfer",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "transfer_write",
						dstAccessMask = "transfer_read",
						oldLayout = "transfer_dst_optimal",
						newLayout = "transfer_src_optimal",
						base_mip_level = i,
						level_count = 1,
						layer_count = layers,
					},
				},
			}
		)
		mip_width = next_mip_width
		mip_height = next_mip_height
	end

	-- Transition all mip levels to shader_read_only_optimal for sampling
	cmd:PipelineBarrier(
		{
			srcStage = "transfer",
			dstStage = "fragment",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "transfer_read",
					dstAccessMask = "shader_read",
					oldLayout = "transfer_src_optimal",
					newLayout = "shader_read_only_optimal",
					base_mip_level = 0,
					level_count = self.mip_map_levels,
					layer_count = layers,
				},
			},
		}
	)

	if internal_cmd then
		cmd:End()

		if not temp_fence then temp_fence = Fence.New(device) end

		queue:SubmitAndWait(device, cmd, temp_fence)
		cmd:Remove()
	end
end

function Texture:IsCubemap()
	return (
			self.config.view and
			self.config.view.view_type == "cube"
		)
		or
		(
			self.view and
			self.view.view_type == "cube"
		)
end

function Texture:Shade(glsl, extra_config)
	if not self.image then error("Cannot shade: texture has no image") end

	extra_config = extra_config or {}

	if glsl:find("vec4 shade") then

	-- Already a full function
	else
		glsl = [[
			vec4 shade(vec2 uv, vec3 _cube_dir) {
				]] .. glsl .. [[
			}
		]]
	end

	local header = extra_config.header or ""
	local device = render.GetDevice()
	local queue = render.GetQueue()
	local is_cube = self:IsCubemap()
	local layers = is_cube and 6 or 1
	-- Create views for each layer (face) if it's a cubemap, or just one for 2D
	local views = {}

	for i = 0, layers - 1 do
		table.insert(
			views,
			ImageView.New(
				{
					device = device,
					image = self.image,
					format = self.format,
					base_mip_level = 0,
					level_count = 1,
					base_array_layer = i,
					layer_count = 1,
					view_type = "2d",
				}
			)
		)
	end

	-- Create command pool and buffer for this operation
	local command_pool = render.GetCommandPool()
	local cmd = command_pool:AllocateCommandBuffer()
	local vertex_code = [[
		#version 450

		// Full-screen triangle
		vec2 positions[3] = vec2[](
			vec2(-1.0, -1.0),
			vec2( 3.0, -1.0),
			vec2(-1.0,  3.0)
		);

		layout(location = 0) out vec2 frag_uv;
		layout(location = 1) out vec3 frag_dir;

		layout(push_constant) uniform Constants {
			int face;
		} pc;

		vec3 get_cube_dir(vec2 uv, int face) {
			vec3 dir;
			if (face == 0) dir = vec3(1.0, -uv.y, -uv.x); // +X
			else if (face == 1) dir = vec3(-1.0, -uv.y, uv.x); // -X
			else if (face == 2) dir = vec3(uv.x, 1.0, uv.y); // +Y
			else if (face == 3) dir = vec3(uv.x, -1.0, -uv.y); // -Y
			else if (face == 4) dir = vec3(uv.x, -uv.y, 1.0); // +Z
			else if (face == 5) dir = vec3(-uv.x, -uv.y, -1.0); // -Z
			return normalize(dir);
		}

		void main() {
			vec2 pos = positions[gl_VertexIndex];
			gl_Position = vec4(pos, 0.0, 1.0);
			frag_uv = pos * 0.5 + 0.5;
			frag_dir = get_cube_dir(pos, pc.face);
		}
	]]
	-- Create graphics pipeline
	local pipeline = render.CreateGraphicsPipeline(
		{
			dynamic_states = {"viewport", "scissor"},
			color_format = self.format,
			samples = "1",
			shader_stages = {
				{
					type = "vertex",
					code = vertex_code,
					input_assembly = {
						topology = "triangle_list",
						primitive_restart = false,
					},
					push_constants = {
						size = 4,
						offset = 0,
					},
				},
				{
					type = "fragment",
					code = [[
							#version 450
							#extension GL_EXT_nonuniform_qualifier : require

							layout(binding = 0) uniform sampler2D textures[1024];
							layout(binding = 1) uniform samplerCube cubemaps[1024];

							layout(location = 0) in vec2 in_uv;
							layout(location = 1) in vec3 in_dir;
							layout(location = 0) out vec4 out_color;

							]] .. (
							extra_config.custom_declarations or
							""
						) .. [[

							]] .. header .. [[
							]] .. glsl .. [[

							void main() {
								out_color = shade(in_uv, in_dir);
							}
						]],
					descriptor_sets = {
						{
							type = "combined_image_sampler",
							binding_index = 0,
							count = 1024,
						},
						{
							type = "combined_image_sampler",
							binding_index = 1,
							count = 1024,
						},
					},
				},
			},
			rasterizer = {
				depth_clamp = false,
				discard = false,
				polygon_mode = "fill",
				line_width = 1.0,
				cull_mode = "front",
				front_face = "counter_clockwise",
				depth_bias = 0,
			},
			color_blend = {
				logic_op_enabled = false,
				logic_op = "copy",
				constants = {0.0, 0.0, 0.0, 0.0},
				attachments = {
					{
						blend = extra_config.blend or false,
						src_color_blend_factor = "src_alpha",
						dst_color_blend_factor = "one_minus_src_alpha",
						color_blend_op = "add",
						src_alpha_blend_factor = "one",
						dst_alpha_blend_factor = "zero",
						alpha_blend_op = "add",
						color_write_mask = {"r", "g", "b", "a"},
					},
				},
			},
			multisampling = {
				sample_shading = false,
				rasterization_samples = "1",
			},
			depth_stencil = {
				depth_test = false,
				depth_write = false,
				depth_compare_op = "less",
				depth_bounds_test = false,
				stencil_test = false,
			},
		}
	)

	if extra_config.textures then
		for _, tex in ipairs(extra_config.textures) do
			pipeline:GetTextureIndex(tex)
		end
	end

	-- Begin recording commands
	cmd:Reset()
	cmd:Begin()
	-- Transition image from undefined/shader_read to color_attachment_optimal
	local old_layout = self.image.layout or "undefined"
	cmd:PipelineBarrier(
		{
			srcStage = "top_of_pipe",
			dstStage = "color_attachment_output",
			imageBarriers = {
				{
					image = self.image,
					srcAccessMask = "none",
					dstAccessMask = "color_attachment_write",
					oldLayout = (extra_config.load_op == "load") and old_layout or "undefined",
					newLayout = "color_attachment_optimal",
					level_count = 1,
					layer_count = layers,
				},
			},
		}
	)
	pipeline:Bind(cmd)

	for i = 0, layers - 1 do
		local face_const = ffi.new("int[1]", i)
		pipeline:PushConstants(cmd, "vertex", 0, face_const)
		-- Begin rendering
		cmd:BeginRendering(
			{
				color_image_view = views[i + 1],
				w = self.image:GetWidth(),
				h = self.image:GetHeight(),
				clear_color = extra_config.clear_color or {0, 0, 0, 0},
				load_op = extra_config.load_op or "clear",
			}
		)
		-- Draw fullscreen triangle
		cmd:SetViewport(0.0, 0.0, self.image:GetWidth(), self.image:GetHeight(), 0.0, 1.0)
		cmd:SetScissor(0, 0, self.image:GetWidth(), self.image:GetHeight())
		cmd:Draw(3, 1, 0, 0)
		-- End rendering
		cmd:EndRendering()
	end

	if self.mip_map_levels > 1 then
		self:GenerateMipmaps("color_attachment_optimal", cmd)
	else
		-- Transition to shader_read_only_optimal
		cmd:PipelineBarrier(
			{
				srcStage = "color_attachment_output",
				dstStage = "fragment",
				imageBarriers = {
					{
						image = self.image,
						srcAccessMask = "color_attachment_write",
						dstAccessMask = "shader_read",
						oldLayout = "color_attachment_optimal",
						newLayout = "shader_read_only_optimal",
						level_count = 1,
						layer_count = layers,
					},
				},
			}
		)
	end

	-- End command buffer
	cmd:End()
	-- Submit and wait
	local fence = Fence.New(device)
	self.refs = {cmd, views, command_pool, pipeline, fence}
	queue:SubmitAndWait(device, cmd, fence)
	self.refs = nil
end

do
	local vulkan = require("render.vulkan.internal.vulkan")

	function Texture:Download()
		local image = self:GetImage()
		local width = image:GetWidth()
		local height = image:GetHeight()
		local format = self.format
		local bytes_per_pixel = get_bytes_per_pixel(format)
		-- Create staging buffer
		local device = render.GetDevice()
		local staging_buffer = Buffer.New(
			{
				device = device,
				size = width * height * bytes_per_pixel,
				usage = "transfer_dst",
				properties = {"host_visible", "host_coherent"},
			}
		)
		-- Create command buffer for copy
		local copy_cmd = render.GetCommandPool():AllocateCommandBuffer()
		copy_cmd:Begin()
		local old_layout = image.layout or "undefined"

		if old_layout ~= "transfer_src_optimal" then
			copy_cmd:PipelineBarrier(
				{
					srcStage = "all_commands",
					dstStage = "transfer",
					imageBarriers = {
						{
							image = image,
							oldLayout = old_layout,
							newLayout = "transfer_src_optimal",
							srcAccessMask = "memory_read",
							dstAccessMask = "transfer_read",
						},
					},
				}
			)
		end

		vulkan.lib.vkCmdCopyImageToBuffer(
			copy_cmd.ptr[0],
			image.ptr[0],
			vulkan.vk.e.VkImageLayout("transfer_src_optimal"),
			staging_buffer.ptr[0],
			1,
			vulkan.vk.VkBufferImageCopy(
				{
					bufferOffset = 0,
					bufferRowLength = 0,
					bufferImageHeight = 0,
					imageSubresource = vulkan.vk.s.ImageSubresourceLayers(
						{
							aspectMask = (image.format and image.format:match("^d")) and "depth" or "color",
							mipLevel = 0,
							baseArrayLayer = 0,
							layerCount = 1,
						}
					),
					imageOffset = vulkan.vk.VkOffset3D({x = 0, y = 0, z = 0}),
					imageExtent = vulkan.vk.VkExtent3D({width = width, height = height, depth = 1}),
				}
			)
		)

		if old_layout ~= "transfer_src_optimal" then
			copy_cmd:PipelineBarrier(
				{
					srcStage = "transfer",
					dstStage = "all_commands",
					imageBarriers = {
						{
							image = image,
							oldLayout = "transfer_src_optimal",
							newLayout = old_layout,
							srcAccessMask = "transfer_read",
							dstAccessMask = "memory_read",
						},
					},
				}
			)
		end

		copy_cmd:End()
		-- Submit and wait
		local fence = Fence.New(device)
		render.GetQueue():SubmitAndWait(device, copy_cmd, fence)
		-- Map staging buffer and copy pixel data
		local pixel_data = staging_buffer:Map()
		local pixels = ffi.new("uint8_t[?]", width * height * bytes_per_pixel)
		ffi.copy(pixels, pixel_data, width * height * bytes_per_pixel)
		staging_buffer:Unmap()
		return {
			pixels = pixels,
			width = width,
			height = height,
			format = format,
			bytes_per_pixel = bytes_per_pixel,
			size = width * height * bytes_per_pixel,
		}
	end

	function Texture:GetPixel(x, y)
		local image_data = self:Download()
		local width = image_data.width
		local height = image_data.height
		local bytes_per_pixel = image_data.bytes_per_pixel

		if x < 0 or x >= width or y < 0 or y >= height then return 0, 0, 0, 0 end

		local offset = (y * width + x) * bytes_per_pixel
		local r = image_data.pixels[offset + 0]
		local g = image_data.pixels[offset + 1]
		local b = image_data.pixels[offset + 2]
		local a = image_data.pixels[offset + 3]
		return r, g, b, a
	end

	function Texture:GetRawPixelColor(x, y)
		if not self.image_data_cache then self.image_data_cache = self:Download() end

		local image_data = self.image_data_cache
		local width = image_data.width
		local height = image_data.height
		local bytes_per_pixel = image_data.bytes_per_pixel
		x = math.clamp(math.floor(x), 0, width - 1)
		y = math.clamp(math.floor(y), 0, height - 1)
		local offset = (y * width + x) * bytes_per_pixel
		local r = image_data.pixels[offset + 0]
		local g = image_data.pixels[offset + 1]
		local b = image_data.pixels[offset + 2]
		local a = bytes_per_pixel == 4 and image_data.pixels[offset + 3] or 255
		return r, g, b, a
	end

	function Texture:ClearImageDataCache()
		self.image_data_cache = nil
	end
end

do
	local png = require("codecs.png")
	local fs = require("fs")

	function Texture:DumpToDisk(name)
		local width, height = self:GetWidth(), self:GetHeight()
		local image_data = self:Download()
		local png = png.Encode(width, height, "rgba")
		local pixel_table = {}

		for i = 0, image_data.size - 1 do
			pixel_table[i + 1] = image_data.pixels[i]
		end

		png:write(pixel_table)
		local screenshot_dir = "./logs/screenshots"
		fs.create_directory_recursive(screenshot_dir)
		local screenshot_path = screenshot_dir .. "/" .. name .. ".png"
		local file = assert(io.open(screenshot_path, "wb"))
		file:write(png:getData())
		file:close()
		return screenshot_path
	end
end

return Texture:Register()
