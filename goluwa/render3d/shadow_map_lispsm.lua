local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local Fence = import("goluwa/render/vulkan/internal/fence.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local AABB = import("goluwa/structs/aabb.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local system = import("goluwa/system.lua")
local render3d = nil
local M = {}
local DEFAULT_DIRECTIONAL_PROJECTION_MODE = "lispsm_or_orthographic"
local LISPSM_MIN_SIN_GAMMA = 0.12
local LISPSM_MIN_NEAR_DISTANCE = 0.01
local LISPSM_MAX_EYE_OFFSET_MULTIPLIER = 32.0
local LISPSM_DEPTH_SAMPLE_GRID = 64
local LISPSM_DEPTH_REDUCTION_TAPS = 4
local LISPSM_DEPTH_HISTOGRAM_BINS = 256
local LISPSM_DEPTH_NEAR_PERCENTILE = 0.02
local LISPSM_DEPTH_FAR_PERCENTILE = 0.985
local LISPSM_MIN_DEPTH_SAMPLES = 32
local LISPSM_MIN_FIT_SPAN_RATIO = 1 / 12
local LISPSM_MIN_FIT_SPAN_ABSOLUTE = 48.0
local LISPSM_DEPTH_STABILIZATION_STEPS = 64
local LISPSM_DEPTH_HYSTERESIS_STEPS = 2
local LISPSM_VISIBLE_DEPTH_READBACK_RING_SIZE = 3

function M.NormalizeDirectionalProjectionMode(mode)
	if mode == "lispsm" then return DEFAULT_DIRECTIONAL_PROJECTION_MODE end

	if mode == "orthographic" or mode == "lispsm_or_orthographic" then
		return mode
	end

	return DEFAULT_DIRECTIONAL_PROJECTION_MODE
end

M.DEFAULT_DIRECTIONAL_PROJECTION_MODE = DEFAULT_DIRECTIONAL_PROJECTION_MODE

local function get_visible_depth_reduce_pass(self)
	self.visible_depth_reduce_slots = self.visible_depth_reduce_slots or {}
	local slots = self.visible_depth_reduce_slots

	for slot_index = 1, LISPSM_VISIBLE_DEPTH_READBACK_RING_SIZE do
		local slot = slots[slot_index]

		if not slot then
			local result_count = LISPSM_DEPTH_HISTOGRAM_BINS + 1
			local result_buffer = Buffer.New{
				device = render.GetDevice(),
				size = ffi.sizeof("uint32_t") * result_count,
				usage = {"storage_buffer"},
				properties = {"host_visible", "host_coherent"},
				name = "shadow visible depth histogram buffer",
			}
			local mapped_result = ffi.cast("uint32_t*", result_buffer:Map())
			local pass = EasyPipeline.Compute{
				DescriptorSetCount = 1,
				name = "shadow_visible_depth_reduce",
				LocalSize = {x = 8, y = 8, z = 1},
				descriptor_sets = {
					{
						type = "storage_buffer",
						binding_index = 0,
						stageFlags = "compute",
						set_index = 0,
						args = {result_buffer, result_buffer.size},
					},
					{
						type = "combined_image_sampler",
						binding_index = 1,
						stageFlags = "compute",
						set_index = 0,
					},
				},
				block = {
					{"output_width", "int"},
					{"output_height", "int"},
					{"near_plane", "float"},
					{"far_plane", "float"},
					{"max_distance", "float"},
					{"has_source_depth_texture", "int"},
				},
				write = function(pass, block)
					block.output_width = LISPSM_DEPTH_SAMPLE_GRID
					block.output_height = LISPSM_DEPTH_SAMPLE_GRID
					block.near_plane = pass.near_plane or 0.1
					block.far_plane = pass.far_plane or 1.0
					block.max_distance = pass.max_distance or pass.far_plane or 1.0
					block.has_source_depth_texture = pass.source_depth_texture and 1 or 0
					return block
				end,
				shader = (
						[[
			layout(std430, set = 0, binding = 0) buffer DepthHistogramBuffer {
				uint values[];
			} out_depth_histogram;
			layout(set = 0, binding = 1) uniform sampler2D source_depth_tex;

			float depth_to_linear(float depth) {
				if (depth <= 0.0 || depth >= 1.0) return 0.0;
				float denom = compute.far_plane - depth * (compute.far_plane - compute.near_plane);
				if (denom <= 1e-6) return 0.0;
				return (compute.near_plane * compute.far_plane) / denom;
			}

			void accumulate_distance(float linear_distance) {
				if (linear_distance <= 0.0 || linear_distance > compute.max_distance) return;
				float normalized = (linear_distance - compute.near_plane) / max(compute.max_distance - compute.near_plane, 1e-6);
				uint bin_index = uint(clamp(floor(normalized * float(]] .. LISPSM_DEPTH_HISTOGRAM_BINS .. [[)), 0.0, float(]] .. (
							LISPSM_DEPTH_HISTOGRAM_BINS - 1
						) .. [[)));
				atomicAdd(out_depth_histogram.values[bin_index], 1u);
				atomicAdd(out_depth_histogram.values[]] .. LISPSM_DEPTH_HISTOGRAM_BINS .. [[], 1u);
			}

			void main() {
				ivec2 pos = ivec2(gl_GlobalInvocationID.xy);
				ivec2 dst_size = ivec2(compute.output_width, compute.output_height);

				if (pos.x >= dst_size.x || pos.y >= dst_size.y) return;

				if (compute.has_source_depth_texture == 0) return;

				ivec2 src_size = textureSize(source_depth_tex, 0);
				vec2 tile_min = vec2(pos) * vec2(src_size) / vec2(dst_size);
				vec2 tile_max = vec2(pos + ivec2(1)) * vec2(src_size) / vec2(dst_size);
				vec2 tile_extent = max(tile_max - tile_min, vec2(1.0));
				float min_distance = 1e30;
				float max_distance = 0.0;
				bool has_sample = false;

				for (int sample_y = 0; sample_y < ]] .. LISPSM_DEPTH_REDUCTION_TAPS .. [[; ++sample_y) {
					for (int sample_x = 0; sample_x < ]] .. LISPSM_DEPTH_REDUCTION_TAPS .. [[; ++sample_x) {
						vec2 sample_uv = tile_min + (vec2(sample_x + 0.5, sample_y + 0.5) / vec2(]] .. LISPSM_DEPTH_REDUCTION_TAPS .. [[)) * tile_extent;
						ivec2 sample_pos = clamp(ivec2(sample_uv), ivec2(0), src_size - ivec2(1));
						float linear_distance = depth_to_linear(texelFetch(source_depth_tex, sample_pos, 0).r);

						if (linear_distance > 0.0 && linear_distance <= compute.max_distance) {
							min_distance = min(min_distance, linear_distance);
							max_distance = max(max_distance, linear_distance);
							has_sample = true;
						}
					}
				}

				if (!has_sample) return;

				accumulate_distance(min_distance);
				accumulate_distance(max_distance);
			}
		]]
					),
			}
			slot = {
				buffer = result_buffer,
				data = mapped_result,
				pass = pass,
				cmd = render.GetCommandPool():AllocateCommandBuffer(),
				fence = Fence.New(render.GetDevice()),
				last_depth_view = nil,
				last_sampler = nil,
				pending_frame_number = nil,
				completed_frame_number = nil,
			}
			slots[slot_index] = slot
		end
	end

	return slots
end

local function update_visible_depth_reduce_slot_completion(slot, queue)
	if slot.pending_frame_number and slot.fence:IsSignaled() then
		if queue:HasPendingSubmission(slot.fence) then
			queue:RetireFence(slot.fence)
		end

		slot.completed_frame_number = slot.pending_frame_number
		slot.pending_frame_number = nil
	end
end

local function submit_reduced_visible_depth_buffer(self, depth_texture, near_plane, far_plane, max_distance, frame_number)
	local slots = get_visible_depth_reduce_pass(self)
	local queue = render.GetQueue()
	local slot_index = (frame_number % #slots) + 1
	local slot = slots[slot_index]
	update_visible_depth_reduce_slot_completion(slot, queue)

	if slot.pending_frame_number then return false end

	local pass = slot.pass
	local depth_view = depth_texture:GetView()
	local sampler = depth_texture.sampler or render.CreateSampler(depth_texture:GetSamplerConfig())
	pass.source_depth_texture = depth_texture
	pass.near_plane = near_plane
	pass.far_plane = far_plane
	pass.max_distance = max_distance

	if slot.last_depth_view ~= depth_view or slot.last_sampler ~= sampler then
		pass:UpdateDescriptorSet("combined_image_sampler", 1, 1, 0, depth_view, sampler)
		slot.last_depth_view = depth_view
		slot.last_sampler = sampler
	end

	local cmd = slot.cmd
	ffi.fill(slot.data, slot.buffer.size, 0)
	cmd:Reset()
	cmd:Begin()
	pass:DispatchForSize(cmd, LISPSM_DEPTH_SAMPLE_GRID, LISPSM_DEPTH_SAMPLE_GRID, 1, 1)
	cmd:PipelineBarrier{
		srcStage = "compute",
		dstStage = "host",
		bufferBarriers = {
			{
				buffer = slot.buffer,
				size = slot.buffer.size,
				srcAccessMask = "shader_write",
				dstAccessMask = "host_read",
			},
		},
	}
	cmd:End()
	render.Submit(cmd, slot.fence)
	slot.pending_frame_number = frame_number
	slot.near_plane = near_plane
	slot.far_plane = far_plane
	slot.max_distance = max_distance
	return true
end

local function get_latest_reduced_visible_depth_buffer(self, max_distance)
	local slots = self.visible_depth_reduce_slots

	if not slots then return nil end

	local queue = render.GetQueue()
	local best_slot = nil

	for i = 1, #slots do
		local slot = slots[i]
		update_visible_depth_reduce_slot_completion(slot, queue)

		if
			slot.completed_frame_number and
			slot.max_distance == max_distance and
			(
				not best_slot or
				slot.completed_frame_number > best_slot.completed_frame_number
			)
		then
			best_slot = slot
		end
	end

	if not best_slot then return nil end

	return best_slot.data, best_slot.completed_frame_number
end

local function get_histogram_percentile_distance(histogram, near_plane, max_distance, percentile, total_count, use_upper_edge)
	if total_count <= 0 then return nil end

	local target = math.max(1, math.floor(math.clamp(percentile, 0, 1) * (total_count - 1) + 1.5))
	local accumulated = 0
	local span = math.max(max_distance - near_plane, LISPSM_MIN_NEAR_DISTANCE)

	for bin_index = 0, LISPSM_DEPTH_HISTOGRAM_BINS - 1 do
		local bin_count = tonumber(histogram[bin_index])
		local previous_accumulated = accumulated
		accumulated = accumulated + bin_count

		if accumulated >= target then
			local bin_near = near_plane + (bin_index / LISPSM_DEPTH_HISTOGRAM_BINS) * span
			local bin_far = near_plane + ((bin_index + 1) / LISPSM_DEPTH_HISTOGRAM_BINS) * span

			if bin_count <= 0 then return use_upper_edge and bin_far or bin_near end

			local bin_fraction = math.clamp((target - previous_accumulated) / bin_count, 0, 1)

			if use_upper_edge then
				bin_fraction = math.max(bin_fraction, 0.5)
			else
				bin_fraction = math.min(bin_fraction, 0.5)
			end

			return bin_near + (bin_far - bin_near) * bin_fraction
		end
	end

	return max_distance
end

local function stabilize_visible_depth_range(self, max_distance, near_plane, near_distance, far_distance)
	local span = math.max(far_distance - near_distance, LISPSM_MIN_NEAR_DISTANCE)
	local quantize_step = math.max(span / LISPSM_DEPTH_STABILIZATION_STEPS, LISPSM_MIN_NEAR_DISTANCE)
	local hysteresis_step = quantize_step * LISPSM_DEPTH_HYSTERESIS_STEPS
	near_distance = math.max(near_plane, math.floor(near_distance / quantize_step + 0.5) * quantize_step)
	far_distance = math.min(max_distance, math.floor(far_distance / quantize_step + 0.5) * quantize_step)
	local state = self.visible_depth_fit_state

	if state and state.max_distance == max_distance then
		if math.abs(near_distance - state.near_distance) <= hysteresis_step then
			near_distance = state.near_distance
		end

		if math.abs(far_distance - state.far_distance) <= hysteresis_step then
			far_distance = state.far_distance
		end
	end

	if far_distance <= near_distance + LISPSM_MIN_NEAR_DISTANCE then
		far_distance = math.min(max_distance, near_distance + math.max(quantize_step, 32.0))
	end

	self.visible_depth_fit_state = {
		max_distance = max_distance,
		near_distance = near_distance,
		far_distance = far_distance,
	}
	return near_distance, far_distance
end

local function get_visible_depth_fit_range(self, max_distance)
	render3d = render3d or import("goluwa/render3d/render3d.lua")
	local frame_number = system.GetFrameNumber and system.GetFrameNumber() or 0
	local cache = self.visible_depth_fit_cache

	if
		cache and
		cache.frame_number == frame_number and
		cache.max_distance == max_distance
	then
		return cache.near_distance, cache.far_distance
	end

	local pipelines = render3d.pipelines
	local gbuffer = pipelines and pipelines.gbuffer or nil
	local framebuffer = gbuffer and gbuffer.GetFramebuffer and gbuffer:GetFramebuffer() or nil
	local depth_texture = framebuffer and
		framebuffer.GetDepthTexture and
		framebuffer:GetDepthTexture() or
		nil

	if not depth_texture then return nil end

	local cam = render3d.GetCamera()

	if not cam then return nil end

	local near_plane = cam:GetNearZ()
	local far_plane = math.min(cam:GetFarZ(), max_distance)
	submit_reduced_visible_depth_buffer(self, depth_texture, near_plane, far_plane, max_distance, frame_number)
	local histogram, reduced_frame_number = get_latest_reduced_visible_depth_buffer(self, max_distance)

	if not histogram then return nil end

	local total_count = tonumber(histogram[LISPSM_DEPTH_HISTOGRAM_BINS]) or 0

	if total_count < LISPSM_MIN_DEPTH_SAMPLES then return nil end

	local near_distance = get_histogram_percentile_distance(
		histogram,
		near_plane,
		max_distance,
		LISPSM_DEPTH_NEAR_PERCENTILE,
		total_count,
		false
	)
	local far_distance = get_histogram_percentile_distance(
		histogram,
		near_plane,
		max_distance,
		LISPSM_DEPTH_FAR_PERCENTILE,
		total_count,
		true
	)

	if not near_distance or not far_distance then return nil end

	near_distance = math.max(near_plane, near_distance)
	far_distance = math.min(max_distance, far_distance)
	local minimum_fit_span = math.max(LISPSM_MIN_FIT_SPAN_ABSOLUTE, max_distance * LISPSM_MIN_FIT_SPAN_RATIO)

	if far_distance - near_distance < minimum_fit_span then
		local missing_span = minimum_fit_span - (far_distance - near_distance)
		local near_pull = missing_span * 0.75
		local far_push = missing_span - near_pull
		near_distance = math.max(near_plane, near_distance - near_pull)
		far_distance = math.min(max_distance, far_distance + far_push)

		if far_distance - near_distance < minimum_fit_span then
			near_distance = math.max(near_plane, far_distance - minimum_fit_span)
		end
	end

	near_distance, far_distance = stabilize_visible_depth_range(self, max_distance, near_plane, near_distance, far_distance)

	if far_distance <= near_distance + LISPSM_MIN_NEAR_DISTANCE then
		far_distance = math.min(max_distance, near_distance + 32.0)
	end

	self.visible_depth_fit_cache = {
		frame_number = reduced_frame_number or frame_number,
		max_distance = max_distance,
		near_distance = near_distance,
		far_distance = far_distance,
	}
	return near_distance, far_distance
end

function M.UpdateLocalDirectional(
	self,
	light_position,
	light_rotation,
	range,
	get_frustum_slice_corners,
	set_directional_cascade_state
)
	local max_distance = math.min(range or self.far_plane, self.max_shadow_distance or math.huge)
	local cam = nil
	local corners = nil
	local split_near = nil
	local split_far = nil

	do
		render3d = render3d or import("goluwa/render3d/render3d.lua")
		cam = render3d.GetCamera()

		if not cam then return false end

		split_near, split_far = get_visible_depth_fit_range(self, max_distance)

		if not split_near or not split_far then
			split_near = cam:GetNearZ()
			split_far = math.min(cam:GetFarZ(), max_distance)
		end

		if split_far <= split_near then return false end

		corners = get_frustum_slice_corners(cam, split_near, split_far)
	end

	if not cam or not corners then return false end

	local view_dir = cam:GetRotation():GetForward():GetNormalized()
	local light_dir = light_rotation:GetForward():GetNormalized()
	local dot = math.abs(view_dir:GetDot(light_dir))
	local sin_gamma = math.sqrt(math.max(0, 1 - dot * dot))

	if sin_gamma < LISPSM_MIN_SIN_GAMMA then return false end

	local world_to_light = light_rotation:GetConjugated():GetMatrix()
	local min_x, min_y, min_z = math.huge, math.huge, math.huge
	local max_x, max_y, max_z = -math.huge, -math.huge, -math.huge

	for i = 1, #corners do
		local corner = world_to_light:TransformVector(corners[i])

		if corner.x < min_x then min_x = corner.x end

		if corner.x > max_x then max_x = corner.x end

		if corner.y < min_y then min_y = corner.y end

		if corner.y > max_y then max_y = corner.y end

		if corner.z < min_z then min_z = corner.z end

		if corner.z > max_z then max_z = corner.z end
	end

	local receiver_width = math.max(max_x - min_x, 0.0001)
	local receiver_height = math.max(max_y - min_y, 0.0001)
	local receiver_depth = math.max(max_z - min_z, 0.0001)
	local receiver_span = math.max(receiver_width, receiver_height)
	local cascade_size = self.cascade[1].size or self.size
	local texel_world_size = math.max(receiver_width / cascade_size.w, receiver_height / cascade_size.h)
	local eye_offset = math.max(receiver_depth * 2.0, receiver_span / sin_gamma)
	eye_offset = math.min(eye_offset, receiver_depth * LISPSM_MAX_EYE_OFFSET_MULTIPLIER)
	eye_offset = math.max(eye_offset, LISPSM_MIN_NEAR_DISTANCE)
	local eye_z = max_z + eye_offset
	local near_distance = math.max(eye_offset, LISPSM_MIN_NEAR_DISTANCE)
	local caster_depth_padding = math.max(receiver_depth * 4.0, split_far - split_near, 100.0)
	local caster_min_z = min_z - caster_depth_padding
	local caster_max_z = max_z + receiver_depth
	local far_distance = math.max(eye_z - caster_min_z, near_distance + LISPSM_MIN_NEAR_DISTANCE)
	local proj_min_x, proj_min_y = math.huge, math.huge
	local proj_max_x, proj_max_y = -math.huge, -math.huge

	for i = 1, #corners do
		local corner = world_to_light:TransformVector(corners[i])
		local distance = eye_z - corner.z

		if distance <= LISPSM_MIN_NEAR_DISTANCE then return false end

		local scale = near_distance / distance
		local proj_x = corner.x * scale
		local proj_y = corner.y * scale

		if proj_x < proj_min_x then proj_min_x = proj_x end

		if proj_x > proj_max_x then proj_max_x = proj_x end

		if proj_y < proj_min_y then proj_min_y = proj_y end

		if proj_y > proj_max_y then proj_max_y = proj_y end
	end

	local projected_width = math.max(proj_max_x - proj_min_x, LISPSM_MIN_NEAR_DISTANCE)
	local projected_height = math.max(proj_max_y - proj_min_y, LISPSM_MIN_NEAR_DISTANCE)
	local projected_pad_x = projected_width * 0.02
	local projected_pad_y = projected_height * 0.02
	local projected_center_x = (proj_min_x + proj_max_x) * 0.5
	local projected_center_y = (proj_min_y + proj_max_y) * 0.5
	local projected_half_width = (projected_width * 0.5) + projected_pad_x
	local projected_half_height = (projected_height * 0.5) + projected_pad_y
	local projected_texel_x = math.max((projected_half_width * 2.0) / cascade_size.w, LISPSM_MIN_NEAR_DISTANCE)
	local projected_texel_y = math.max((projected_half_height * 2.0) / cascade_size.h, LISPSM_MIN_NEAR_DISTANCE)
	projected_center_x = math.floor(projected_center_x / projected_texel_x + 0.5) * projected_texel_x
	projected_center_y = math.floor(projected_center_y / projected_texel_y + 0.5) * projected_texel_y
	local warp_view = Matrix44()
	warp_view:Translate(0, 0, -eye_z)
	local projection = Matrix44()

	do
		local left = projected_center_x - projected_half_width
		local right = projected_center_x + projected_half_width
		local bottom = projected_center_y - projected_half_height
		local top = projected_center_y + projected_half_height
		local width = math.max(right - left, LISPSM_MIN_NEAR_DISTANCE)
		local height = math.max(top - bottom, LISPSM_MIN_NEAR_DISTANCE)
		local depth = math.max(far_distance - near_distance, LISPSM_MIN_NEAR_DISTANCE)
		projection.m00 = (2.0 * near_distance) / width
		projection.m01 = 0.0
		projection.m02 = 0.0
		projection.m03 = 0.0
		projection.m10 = 0.0
		projection.m11 = orientation.PROJECTION_Y_FLIP * (2.0 * near_distance) / height
		projection.m12 = 0.0
		projection.m13 = 0.0
		projection.m20 = (right + left) / width
		projection.m21 = orientation.PROJECTION_Y_FLIP * ((top + bottom) / height)
		projection.m22 = -far_distance / depth
		projection.m23 = -1.0
		projection.m30 = 0.0
		projection.m31 = 0.0
		projection.m32 = -(far_distance * near_distance) / depth
		projection.m33 = 0.0
	end

	local view = Matrix44()
	view:Translate(-light_position.x, -light_position.y, -light_position.z)
	view:Multiply(light_rotation:GetConjugated():GetMatrix())
	local cascade = self.cascade[1]
	set_directional_cascade_state(
		self,
		cascade,
		light_position,
		view,
		(view * warp_view) * projection,
		texel_world_size,
		AABB(min_x, min_y, caster_min_z, max_x, max_y, caster_max_z),
		split_far
	)
	return true
end

return M
