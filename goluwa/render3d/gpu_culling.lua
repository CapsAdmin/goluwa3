local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")
local pvars = import("goluwa/cli/pvars.lua")
local event = import("goluwa/event.lua")
local render3d = nil
local gpu_culling = {}
gpu_culling.culling_enabled = true
gpu_culling.drawn_cull_frame = gpu_culling.drawn_cull_frame or -1
gpu_culling.occlusion_mode = gpu_culling.occlusion_mode or "hiz"
local VALID_OCCLUSION_MODES = {
	disabled = true,
	hiz = true,
}
pvars.StartGroup("Rendering", "Culling", {store = false, prefix = "feature_"})
pvars.Setup2{
	key = "r_feature_culling",
	default = true,
	friendly = "visibility culling",
	help = "frustum, distance, size and occlusion culling of the main view and the shadow maps, off draws everything in the scene every frame, the worst case for benchmarking",
	callback = function(enabled)
		gpu_culling.culling_enabled = enabled
		event.Call("CullingSettingsChanged")
	end,
}
pvars.EndGroup()

function gpu_culling.Initialize()
	render3d = import("goluwa/render3d/render3d.lua")
	local hiz_descriptor_set_count = (math.max(render.GetSwapchainImageCount() or 1, 1) + 1) * 16

	do
		gpu_culling.main_view_hiz_build_pass = EasyPipeline.Compute{
			DescriptorSetCount = hiz_descriptor_set_count,
			name = "gpu_culling_main_view_hiz_copy",
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_image",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			shader = [[
			layout(set = 0, binding = 0) uniform sampler2D source_depth_tex;
			layout(set = 0, binding = 1, r32f) uniform writeonly image2D out_hiz;

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 dst_size = imageSize(out_hiz);

				if (any(greaterThanEqual(pos, dst_size))) return;

				ivec2 src_size = textureSize(source_depth_tex, 0);
				if (any(greaterThanEqual(pos, src_size))) return;
				imageStore(out_hiz, pos, vec4(texelFetch(source_depth_tex, pos, 0).r, 0.0, 0.0, 1.0));
			}
		]],
		}
	end

	do
		gpu_culling.main_view_hiz_reduce_pass = EasyPipeline.Compute{
			DescriptorSetCount = hiz_descriptor_set_count,
			name = "gpu_culling_main_view_hiz_reduce",
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = {
				{
					type = "storage_image",
					binding_index = 0,
					stageFlags = "compute",
					set_index = 0,
				},
				{
					type = "storage_image",
					binding_index = 1,
					stageFlags = "compute",
					set_index = 0,
				},
			},
			shader = [[
			layout(set = 0, binding = 0, r32f) uniform readonly image2D source_hiz;
			layout(set = 0, binding = 1, r32f) uniform writeonly image2D out_hiz;

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 dst_size = imageSize(out_hiz);

				if (any(greaterThanEqual(pos, dst_size))) return;

				ivec2 src_size = imageSize(source_hiz);
				ivec2 src_base = pos * 2;
				ivec2 src_last = src_base + 1;

				if (pos.x == dst_size.x - 1) src_last.x = src_size.x - 1;
				if (pos.y == dst_size.y - 1) src_last.y = src_size.y - 1;

				float min_depth = 1.0;

				for (int y = src_base.y; y <= src_last.y; ++y) {
					for (int x = src_base.x; x <= src_last.x; ++x) {
						min_depth = min(min_depth, imageLoad(source_hiz, ivec2(x, y)).r);
					}
				}

				imageStore(out_hiz, pos, vec4(min_depth, 0.0, 0.0, 1.0));
			}
		]],
		}
	end
end

function gpu_culling.Shutdown()
	if
		gpu_culling.main_view_hiz_build_pass and
		gpu_culling.main_view_hiz_build_pass.Remove
	then
		gpu_culling.main_view_hiz_build_pass:Remove()
	end

	gpu_culling.main_view_hiz_build_pass = nil

	if
		gpu_culling.main_view_hiz_reduce_pass and
		gpu_culling.main_view_hiz_reduce_pass.Remove
	then
		gpu_culling.main_view_hiz_reduce_pass:Remove()
	end

	gpu_culling.main_view_hiz_reduce_pass = nil
	local state = gpu_culling.main_view_hiz_state

	if state and state.buffers then
		for _, buffer in ipairs(state.buffers) do
			if buffer and buffer.texture then buffer.texture:Remove() end
		end
	end

	gpu_culling.main_view_hiz_state = nil
end

local HIZ_BUFFER_COUNT = 2

local function create_main_view_hiz_buffer(width, height, index)
	local mip_count = 1
	local largest_dimension = math.max(width, height)

	while largest_dimension > 1 do
		largest_dimension = math.floor(largest_dimension * 0.5)
		mip_count = mip_count + 1
	end

	local texture = Texture.New{
		width = width,
		height = height,
		format = "r32_sfloat",
		mip_map_levels = mip_count,
		image = {
			usage = {"sampled", "storage", "transfer_src"},
			properties = "device_local",
		},
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			mipmap_mode = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
		},
	}
	texture:SetDebugName("gpu culling main view hiz " .. index)
	local image = texture:GetImage()
	local single_mip_views = {}

	for mip_level = 0, mip_count - 1 do
		single_mip_views[mip_level + 1] = image:CreateView{
			format = "r32_sfloat",
			base_mip_level = mip_level,
			level_count = 1,
			aspect = "color",
		}
		single_mip_views[mip_level + 1]:SetDebugName("gpu culling main view hiz " .. index .. " mip " .. mip_level)
	end

	image:TransitionLayout(image.layout or "undefined", "general")
	local buffer = {
		index = index,
		texture = texture,
		image = image,
		view = texture:GetView(),
		sampler = texture.sampler or render.CreateSampler(texture:GetSamplerConfig()),
		max_mip = mip_count - 1,
		single_mip_views = single_mip_views,
		built = false,
		mip_barriers = {},
	}

	for mip_level = 0, mip_count - 1 do
		buffer.mip_barriers[mip_level + 1] = {
			srcStage = "compute",
			dstStage = "compute",
			imageBarriers = {
				{
					image = image,
					srcAccessMask = "shader_write",
					dstAccessMask = "shader_read",
					oldLayout = "general",
					newLayout = "general",
					base_mip_level = mip_level,
					level_count = 1,
					layer_count = 1,
				},
			},
		}
	end

	return buffer
end

local function ensure_main_view_hiz_state(width, height)
	local state = gpu_culling.main_view_hiz_state

	if state and state.width == width and state.height == height then
		return state
	end

	if state then
		for _, buffer in ipairs(state.buffers) do
			buffer.texture:Remove()
		end
	end

	state = {
		width = width,
		height = height,
		buffers = {},
		write_index = 1,
		latest = nil,
	}

	for index = 1, HIZ_BUFFER_COUNT do
		state.buffers[index] = create_main_view_hiz_buffer(width, height, index)
	end

	gpu_culling.main_view_hiz_state = state
	return state
end

local function get_main_view_hiz_state()
	local depth_texture = render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture()
	return ensure_main_view_hiz_state(depth_texture:GetWidth(), depth_texture:GetHeight()),
	depth_texture
end

function gpu_culling.PrepareMainViewHiZ(cmd)
	if gpu_culling.GetOcclusionMode() ~= "hiz" or not gpu_culling.culling_enabled then return end

	local state, depth_texture = get_main_view_hiz_state()
	local buffer = state.buffers[state.write_index]
	local descriptor_base = math.max(render.GetCurrentFrame() or 1, 1) * 16
	local copy_pass = gpu_culling.main_view_hiz_build_pass
	copy_pass:UpdateDescriptorSet("combined_image_sampler", descriptor_base, 0, 0, depth_texture)
	copy_pass:UpdateDescriptorSet("storage_image", descriptor_base, 1, 0, buffer.single_mip_views[1])
	copy_pass:DispatchForSize(cmd, state.width, state.height, 1, descriptor_base)
	cmd:PipelineBarrier(buffer.mip_barriers[1])
	local reduce_pass = gpu_culling.main_view_hiz_reduce_pass

	for mip_level = 1, buffer.max_mip do
		local reduce_descriptor_slot = descriptor_base + mip_level
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			0,
			0,
			buffer.single_mip_views[mip_level]
		)
		reduce_pass:UpdateDescriptorSet(
			"storage_image",
			reduce_descriptor_slot,
			1,
			0,
			buffer.single_mip_views[mip_level + 1]
		)
		reduce_pass:DispatchForSize(
			cmd,
			math.max(1, math.floor((state.width + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			math.max(1, math.floor((state.height + (2 ^ mip_level) - 1) / (2 ^ mip_level))),
			1,
			reduce_descriptor_slot
		)
		cmd:PipelineBarrier(buffer.mip_barriers[mip_level + 1])
	end

	buffer.built = true
	state.latest = buffer
	state.write_index = (state.write_index % HIZ_BUFFER_COUNT) + 1
end


function gpu_culling.GetDrawnCullFrame()
	return gpu_culling.drawn_cull_frame
end

function gpu_culling.MarkMainViewDrawn()
	gpu_culling.drawn_cull_frame = system.GetFrameNumber()
end

function gpu_culling.GetMainViewHiZ()
	if gpu_culling.GetOcclusionMode() ~= "hiz" or not gpu_culling.culling_enabled then return nil end

	local state = get_main_view_hiz_state()
	return state.latest, state.buffers[1], state.height
end

function gpu_culling.GetOcclusionMode()
	return gpu_culling.occlusion_mode
end

function gpu_culling.SetOcclusionMode(mode)
	assert(VALID_OCCLUSION_MODES[mode], "invalid gpu culling occlusion mode: " .. tostring(mode))
	gpu_culling.occlusion_mode = mode
end


local function extract_frustum_planes(proj_view_matrix, out_planes, side_scale)
	local m = proj_view_matrix
	local x0, x1, x2, x3 = m.m00 * side_scale, m.m10 * side_scale, m.m20 * side_scale, m.m30 * side_scale
	local y0, y1, y2, y3 = m.m01 * side_scale, m.m11 * side_scale, m.m21 * side_scale, m.m31 * side_scale
	out_planes[0] = m.m03 + x0
	out_planes[1] = m.m13 + x1
	out_planes[2] = m.m23 + x2
	out_planes[3] = m.m33 + x3
	out_planes[4] = m.m03 - x0
	out_planes[5] = m.m13 - x1
	out_planes[6] = m.m23 - x2
	out_planes[7] = m.m33 - x3
	out_planes[8] = m.m03 + y0
	out_planes[9] = m.m13 + y1
	out_planes[10] = m.m23 + y2
	out_planes[11] = m.m33 + y3
	out_planes[12] = m.m03 - y0
	out_planes[13] = m.m13 - y1
	out_planes[14] = m.m23 - y2
	out_planes[15] = m.m33 - y3
	out_planes[16] = m.m02
	out_planes[17] = m.m12
	out_planes[18] = m.m22
	out_planes[19] = m.m32
	out_planes[20] = m.m03 - m.m02
	out_planes[21] = m.m13 - m.m12
	out_planes[22] = m.m23 - m.m22
	out_planes[23] = m.m33 - m.m32

	for i = 0, 20, 4 do
		local a, b, c = out_planes[i], out_planes[i + 1], out_planes[i + 2]
		local len = math.sqrt(a * a + b * b + c * c)

		if len > 0 then
			local inv_len = 1.0 / len
			out_planes[i] = a * inv_len
			out_planes[i + 1] = b * inv_len
			out_planes[i + 2] = c * inv_len
			out_planes[i + 3] = out_planes[i + 3] * inv_len
		end
	end
end

gpu_culling.ExtractFrustumPlanes = extract_frustum_planes

return gpu_culling
