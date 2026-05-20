local render3d = library()
import.loaded["goluwa/render3d/render3d.lua"] = render3d
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local event = import("goluwa/event.lua")
local orientation = import("goluwa/render3d/orientation.lua")
local Material = import("goluwa/render3d/material.lua")
local Matrix44 = import("goluwa/structs/matrix44.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Rect = import("goluwa/structs/rect.lua")
local Camera3D = import("goluwa/render3d/camera3d.lua")
local assets = import("goluwa/assets.lua")
local Framebuffer = import("goluwa/render/framebuffer.lua")
local VertexBuffer = import("goluwa/render/vertex_buffer.lua")
local system = import("goluwa/system.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local Light = import("goluwa/ecs/components/3d/light.lua")
local prototype = import("goluwa/prototype.lua")
local INSTANCE_MATRIX_ATTRIBUTES = {
	{
		lua_name = "instance_world",
		lua_type = ffi.typeof("float[16]"),
		offset = 0,
	},
}
local NO_INDEX_BUFFER_KEY = {}
local NO_MODEL_PATH_KEY = {}

local function new_instancing_reuse_summary()
	return {
		unique_keys = 0,
		singleton_keys = 0,
		repeated_keys = 0,
		repeated_instances = 0,
		max_instances_per_key = 0,
	}
end

local function reset_instancing_reuse_summary(summary)
	summary = summary or new_instancing_reuse_summary()
	summary.unique_keys = 0
	summary.singleton_keys = 0
	summary.repeated_keys = 0
	summary.repeated_instances = 0
	summary.max_instances_per_key = 0
	return summary
end

local function copy_instancing_reuse_summary(dst, src)
	dst = reset_instancing_reuse_summary(dst)
	dst.unique_keys = src.unique_keys
	dst.singleton_keys = src.singleton_keys
	dst.repeated_keys = src.repeated_keys
	dst.repeated_instances = src.repeated_instances
	dst.max_instances_per_key = src.max_instances_per_key
	return dst
end

local function observe_instancing_reuse(summary, counts, key)
	key = key == nil and NO_MODEL_PATH_KEY or key
	local count = counts[key]

	if not count then
		counts[key] = 1
		summary.unique_keys = summary.unique_keys + 1
		summary.singleton_keys = summary.singleton_keys + 1

		if summary.max_instances_per_key < 1 then summary.max_instances_per_key = 1 end

		return
	end

	count = count + 1
	counts[key] = count

	if count == 2 then
		summary.singleton_keys = summary.singleton_keys - 1
		summary.repeated_keys = summary.repeated_keys + 1
		summary.repeated_instances = summary.repeated_instances + 2
	else
		summary.repeated_instances = summary.repeated_instances + 1
	end

	if count > summary.max_instances_per_key then
		summary.max_instances_per_key = count
	end
end

local function new_instancing_reuse_observations()
	return {
		model_path = {},
		mesh_object = {},
		batch_key = {},
	}
end

local function new_instancing_counters()
	return {
		queue_attempts = 0,
		queued_batches = 0,
		queued_instances = 0,
		flushed_batches = 0,
		flushed_instances = 0,
		instanced_draws = 0,
		singleton_fallback_draws = 0,
		completed_frame = 0,
		queued_batches_by_material_key_kind = {
			raw = 0,
			vmt = 0,
			crymtl = 0,
		},
		singleton_fallback_draws_by_material_key_kind = {
			raw = 0,
			vmt = 0,
			crymtl = 0,
		},
		instanced_draws_by_material_key_kind = {
			raw = 0,
			vmt = 0,
			crymtl = 0,
		},
		observed_reuse_by_model_path = new_instancing_reuse_summary(),
		observed_reuse_by_mesh_object = new_instancing_reuse_summary(),
		observed_reuse_by_batch_key = new_instancing_reuse_summary(),
		rejected = {
			missing_args = 0,
			missing_pipeline = 0,
			wireframe = 0,
			tessellated = 0,
			vertex_animation = 0,
			missing_mesh = 0,
		},
	}
end

local function reset_instancing_counters(target)
	target = target or new_instancing_counters()
	target.queue_attempts = 0
	target.queued_batches = 0
	target.queued_instances = 0
	target.flushed_batches = 0
	target.flushed_instances = 0
	target.instanced_draws = 0
	target.singleton_fallback_draws = 0
	target.completed_frame = 0
	target.queued_batches_by_material_key_kind = target.queued_batches_by_material_key_kind or {}
	target.queued_batches_by_material_key_kind.raw = 0
	target.queued_batches_by_material_key_kind.vmt = 0
	target.queued_batches_by_material_key_kind.crymtl = 0
	target.singleton_fallback_draws_by_material_key_kind = target.singleton_fallback_draws_by_material_key_kind or {}
	target.singleton_fallback_draws_by_material_key_kind.raw = 0
	target.singleton_fallback_draws_by_material_key_kind.vmt = 0
	target.singleton_fallback_draws_by_material_key_kind.crymtl = 0
	target.instanced_draws_by_material_key_kind = target.instanced_draws_by_material_key_kind or {}
	target.instanced_draws_by_material_key_kind.raw = 0
	target.instanced_draws_by_material_key_kind.vmt = 0
	target.instanced_draws_by_material_key_kind.crymtl = 0
	target.observed_reuse_by_model_path = reset_instancing_reuse_summary(target.observed_reuse_by_model_path)
	target.observed_reuse_by_mesh_object = reset_instancing_reuse_summary(target.observed_reuse_by_mesh_object)
	target.observed_reuse_by_batch_key = reset_instancing_reuse_summary(target.observed_reuse_by_batch_key)
	target.rejected = target.rejected or {}
	target.rejected.missing_args = 0
	target.rejected.missing_pipeline = 0
	target.rejected.wireframe = 0
	target.rejected.tessellated = 0
	target.rejected.vertex_animation = 0
	target.rejected.missing_mesh = 0
	return target
end

local function copy_instancing_counters(dst, src)
	dst = reset_instancing_counters(dst)
	dst.queue_attempts = src.queue_attempts
	dst.queued_batches = src.queued_batches
	dst.queued_instances = src.queued_instances
	dst.flushed_batches = src.flushed_batches
	dst.flushed_instances = src.flushed_instances
	dst.instanced_draws = src.instanced_draws
	dst.singleton_fallback_draws = src.singleton_fallback_draws
	dst.completed_frame = src.completed_frame
	dst.queued_batches_by_material_key_kind.raw = src.queued_batches_by_material_key_kind.raw
	dst.queued_batches_by_material_key_kind.vmt = src.queued_batches_by_material_key_kind.vmt
	dst.queued_batches_by_material_key_kind.crymtl = src.queued_batches_by_material_key_kind.crymtl
	dst.singleton_fallback_draws_by_material_key_kind.raw = src.singleton_fallback_draws_by_material_key_kind.raw
	dst.singleton_fallback_draws_by_material_key_kind.vmt = src.singleton_fallback_draws_by_material_key_kind.vmt
	dst.singleton_fallback_draws_by_material_key_kind.crymtl = src.singleton_fallback_draws_by_material_key_kind.crymtl
	dst.instanced_draws_by_material_key_kind.raw = src.instanced_draws_by_material_key_kind.raw
	dst.instanced_draws_by_material_key_kind.vmt = src.instanced_draws_by_material_key_kind.vmt
	dst.instanced_draws_by_material_key_kind.crymtl = src.instanced_draws_by_material_key_kind.crymtl
	dst.observed_reuse_by_model_path = copy_instancing_reuse_summary(dst.observed_reuse_by_model_path, src.observed_reuse_by_model_path)
	dst.observed_reuse_by_mesh_object = copy_instancing_reuse_summary(dst.observed_reuse_by_mesh_object, src.observed_reuse_by_mesh_object)
	dst.observed_reuse_by_batch_key = copy_instancing_reuse_summary(dst.observed_reuse_by_batch_key, src.observed_reuse_by_batch_key)
	dst.rejected.missing_args = src.rejected.missing_args
	dst.rejected.missing_pipeline = src.rejected.missing_pipeline
	dst.rejected.wireframe = src.rejected.wireframe
	dst.rejected.tessellated = src.rejected.tessellated
	dst.rejected.vertex_animation = src.rejected.vertex_animation
	dst.rejected.missing_mesh = src.rejected.missing_mesh
	return dst
end

do
	render3d.debug_block = {
		{
			"debug_cascade_colors",
			"int",
			function(self, block, key)
				block[key] = render3d.debug_cascade_colors and 1 or 0
			end,
		},
		{
			"debug_mode",
			"int",
			function(self, block, key)
				block[key] = render3d.debug_mode or 1
			end,
		},
		{
			"gbuffer_normal_debug_view",
			"int",
			function(self, block, key)
				block[key] = render3d.gbuffer_normal_debug_view or 0
			end,
		},
		{
			"near_z",
			"float",
			function(self, block, key)
				block[key] = render3d.camera:GetNearZ()
			end,
		},
		{
			"far_z",
			"float",
			function(self, block, key)
				block[key] = render3d.camera:GetFarZ()
			end,
		},
		{
			"debug_camera_position",
			"vec3",
			function(self, block, key)
				render3d.camera:GetPosition():CopyToFloatPointer(block[key])
			end,
		},
	}
	local debug_modes = {
		"none",
		"normals",
		"irradiance",
		"ambient_occlusion",
		"ssr",
		"probe",
		"wireframe",
	}
	render3d.debug_mode = render3d.debug_mode or 1
	render3d.gbuffer_normal_debug_view = render3d.gbuffer_normal_debug_view or 0
	local gbuffer_normal_debug_views = {
		combined = 0,
		normal_map = 1,
		vertex_normal = 2,
		tangent = 3,
		bitangent = 4,
		vertex_color = 5,
		vertex_color_r = 6,
		vertex_color_g = 7,
		vertex_color_b = 8,
		vertex_color_a = 9,
	}

	function render3d.SetDebugMode(mode_name)
		for i, name in ipairs(debug_modes) do
			if name == mode_name then
				render3d.debug_mode = i
				return true
			end
		end

		return false
	end

	function render3d.GetDebugModes()
		return debug_modes
	end

	function render3d.CycleDebugMode()
		render3d.debug_mode = render3d.debug_mode % #debug_modes + 1
		return debug_modes[render3d.debug_mode]
	end

	function render3d.GetDebugModeName()
		return debug_modes[render3d.debug_mode]
	end

	function render3d.IsWireframeDebugMode(mode_name)
		return (mode_name or render3d.GetDebugModeName()) == "wireframe"
	end

	function render3d.SetGBufferNormalDebugView(mode_name)
		local mode = gbuffer_normal_debug_views[mode_name]

		if mode == nil then return false end

		render3d.gbuffer_normal_debug_view = mode
		return true
	end

	function render3d.GetGBufferNormalDebugView()
		for name, mode in pairs(gbuffer_normal_debug_views) do
			if mode == render3d.gbuffer_normal_debug_view then return name end
		end

		return "combined"
	end

	render3d.debug_mode_glsl = [[
		int debug_mode = lighting_data.debug_mode - 1;

		if (debug_mode == 1) {
			color = N * 0.5 + 0.5;
		} else if (debug_mode == 2) {
			color = irradiance;
		} else if (debug_mode == 3) {
			color = vec3(ambient_occlusion);
		} else if (debug_mode == 4) {
			color = texture(TEXTURE(lighting_data.ssr_tex), in_uv).rgb;
		} else if (debug_mode == 5) {
			// Probe debug - show probe cubemap contribution
			color = get_reflection(N, 0, V, world_pos);
		}
	]]
end

function render3d.WriteDebugBlock(self, block)
	block.debug_cascade_colors = render3d.debug_cascade_colors and 1 or 0
	block.debug_mode = render3d.debug_mode or 1
	block.gbuffer_normal_debug_view = render3d.gbuffer_normal_debug_view or 0
	block.near_z = render3d.camera:GetNearZ()
	block.far_z = render3d.camera:GetFarZ()
	render3d.camera:GetPosition():CopyToFloatPointer(block.debug_camera_position)
	return block
end

render3d.camera_block = {
	{
		"inv_view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"inv_projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():GetInverse():CopyToFloatPointer(block[key])
		end,
	},
	{
		"view",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildViewMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"projection",
		"mat4",
		function(self, block, key)
			render3d.camera:BuildProjectionMatrix():CopyToFloatPointer(block[key])
		end,
	},
	{
		"render_size",
		"vec2",
		function(self, block, key)
			local size = render.GetRenderImageSize()
			block[key][0] = size and size.x or 1
			block[key][1] = size and size.y or 1
		end,
	},
	{
		"camera_position",
		"vec3",
		function(self, block, key)
			render3d.camera:GetPosition():CopyToFloatPointer(block[key])
		end,
	},
}

function render3d.WriteCameraBlock(self, block)
	local view = render3d.camera:BuildViewMatrix()
	local projection = render3d.camera:BuildProjectionMatrix()
	view:GetInverse():CopyToFloatPointer(block.inv_view)
	projection:GetInverse():CopyToFloatPointer(block.inv_projection)
	view:CopyToFloatPointer(block.view)
	projection:CopyToFloatPointer(block.projection)
	local size = render.GetRenderImageSize()
	block.render_size[0] = size and size.x or 1
	block.render_size[1] = size and size.y or 1
	render3d.camera:GetPosition():CopyToFloatPointer(block.camera_position)
	return block
end

function render3d.WriteCameraDebugBlock(self, block)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteDebugBlock(self, block)
	return block
end

render3d.common_block = {
	{
		"time",
		"float",
		function(self, block, key)
			block[key] = system.GetElapsedTime()
		end,
	},
}

function render3d.WriteCommonBlock(self, block)
	block.time = system.GetElapsedTime()
	return block
end

render3d.gbuffer_block = {
	{
		"albedo_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(1))
		end,
	},
	{
		"normal_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(2))
		end,
	},
	{
		"mra_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(3))
		end,
	},
	{
		"emissive_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetAttachment(4))
		end,
	},
	{
		"depth_tex",
		"int",
		function(self, block, key)
			block[key] = self:GetTextureIndex(render3d.pipelines.gbuffer:GetFramebuffer():GetDepthTexture())
		end,
	},
}

function render3d.WriteGBufferBlock(self, block)
	local framebuffer = render3d.pipelines.gbuffer:GetFramebuffer()
	block.albedo_tex = self:GetTextureIndex(framebuffer:GetAttachment(1))
	block.normal_tex = self:GetTextureIndex(framebuffer:GetAttachment(2))
	block.mra_tex = self:GetTextureIndex(framebuffer:GetAttachment(3))
	block.emissive_tex = self:GetTextureIndex(framebuffer:GetAttachment(4))
	block.depth_tex = self:GetTextureIndex(framebuffer:GetDepthTexture())
	return block
end

render3d.last_frame_block = {
	{
		"last_frame_tex",
		"int",
		function(self, block, key)
			if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
				block[key] = -1
				return
			end

			local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
			block[key] = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(prev_idx):GetAttachment(1))
		end,
	},
}

function render3d.WriteLastFrameBlock(self, block)
	if not render3d.pipelines.lighting or not render3d.pipelines.lighting.framebuffers then
		block.last_frame_tex = -1
		return block
	end

	local prev_idx = (system.GetFrameNumber() + 1) % 2 + 1
	block.last_frame_tex = self:GetTextureIndex(render3d.pipelines.lighting:GetFramebuffer(prev_idx):GetAttachment(1))
	return block
end

function render3d.Initialize()
	render3d.pipelines = {}
	render3d.pipelines_i = {}
	local i = 1
	local pipelines = list.flatten{
		import("goluwa/render3d/passes/gbuffer.lua"),
		import("goluwa/render3d/passes/ssr.lua"),
		import("goluwa/render3d/passes/lighting.lua"),
		import("goluwa/render3d/passes/ocean.lua"),
		import("goluwa/render3d/passes/forward_overlay.lua"),
		--import("goluwa/render3d/passes/smaa.lua"),
		import("goluwa/render3d/passes/blit.lua"),
	}

	for i, config in ipairs(pipelines) do
		render3d.pipelines_i[i] = EasyPipeline.New(config)
		render3d.pipelines[config.name] = render3d.pipelines_i[i]
		--
		render3d.pipelines_i[i].name = config.name
		render3d.pipelines_i[i].post_draw = config.post_draw
		render3d.pipelines_i[i].draw_in_prerender = config.draw_in_prerender ~= false
	end

	local size = render.GetRenderImageSize()
	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))

	event.AddListener("PreRenderPass", "render3d", function()
		if not render3d.pipelines.gbuffer then return end

		local sampler_config = render.GetSamplerFilterConfig()

		for _, pipeline in ipairs(render3d.pipelines_i) do
			pipeline:SetSamplerConfig(sampler_config)

			if pipeline.name ~= "blit" and pipeline.draw_in_prerender then
				pipeline:Draw()
			end
		end
	end)

	event.AddListener("Draw", "render3d", function(dt)
		render3d.Draw(dt)
	end)

	event.Call("Render3DInitialized")
end

function render3d.ResetState()
	render3d.camera = Camera3D.New()
	render3d.camera_stack = {}
	render3d.world_matrix = Matrix44()
	render3d.prev_view_matrix = Matrix44()
	render3d.prev_projection_matrix = Matrix44()
	render3d.current_material = render3d.GetDefaultMaterial()
	render3d.current_polygon3d = nil
	render3d.forward_overlay_clip_plane_enabled = false
	render3d.forward_overlay_clip_plane_origin = Vec3(0, 0, 0)
	render3d.forward_overlay_clip_plane_normal = Vec3(0, 0, 1)
	render3d.environment_texture = nil
	render3d.ocean_enabled = true
	render3d.ocean_level = nil
	render3d.debug_cascade_colors = false
	render3d.debug_mode = 1
	render3d.gbuffer_normal_debug_view = 0
	render3d.gbuffer_instance_batches = {}
	render3d.queued_gbuffer_instance_batches = {}
	render3d.pending_gbuffer_instance_entries = {}
	render3d.queued_gbuffer_pending_entries = {}
	render3d.instancing_reuse_observations = new_instancing_reuse_observations()
	render3d.instancing_counters = reset_instancing_counters(render3d.instancing_counters)
	render3d.last_instancing_counters = render3d.last_instancing_counters or new_instancing_counters()
end

function render3d.Draw(dt)
	if not render3d.pipelines.blit then return end

	local cmd = render.GetCommandBuffer()
	local sampler_config = render.GetSamplerFilterConfig()

	for _, pipeline in ipairs(render3d.pipelines_i) do
		pipeline:SetSamplerConfig(sampler_config)
	end

	-- render to the screen
	render3d.pipelines.blit:Draw(cmd)

	for _, pipeline in ipairs(render3d.pipelines_i) do
		if pipeline.post_draw then pipeline:post_draw(cmd, dt) end
	end

	render3d.prev_view_matrix = render3d.camera:BuildViewMatrix():Copy()
	render3d.prev_projection_matrix = render3d.camera:BuildProjectionMatrix():Copy()
end

local function use_tessellated_gbuffer(material)
	return material and
		material:GetHeightTexture() and
		material:GetHeightScale() > 0 and
		material:GetTessellationFactor() > 1.0 and
		render3d.pipelines.gbuffer_tess
end

local function material_has_vertex_animation(material)
	return material and
		(
			material:GetWindAmplitude() > 0 or
			material:GetWindDetailAmplitude() > 0
		)
end

local function get_gbuffer_instance_material_key(material)
	if not material then return material end

	if material.vmt_path then return "vmt:" .. material.vmt_path end

	if material.cry_mtl_path then
		return "crymtl:" .. material.cry_mtl_path .. "#" .. tostring(material.cry_sub_material_name or "")
	end

	return material
end

local function get_gbuffer_instance_material_key_kind(material)
	if not material then return "raw" end

	if material.vmt_path then return "vmt" end

	if material.cry_mtl_path then return "crymtl" end

	return "raw"
end

local function get_gbuffer_instance_mesh_key(mesh)
	if not mesh or not mesh.vertex_buffer or not mesh.vertex_buffer.GetBuffer then
		return mesh, NO_INDEX_BUFFER_KEY
	end

	local vertex_buffer = mesh.vertex_buffer:GetBuffer()
	local index_buffer = mesh.index_buffer and mesh.index_buffer:GetBuffer() or NO_INDEX_BUFFER_KEY
	return vertex_buffer, index_buffer
end

local function observe_gbuffer_instance_reuse(counters, mesh, material, model_path)
	render3d.instancing_reuse_observations = render3d.instancing_reuse_observations or new_instancing_reuse_observations()
	observe_instancing_reuse(
		counters.observed_reuse_by_model_path,
		render3d.instancing_reuse_observations.model_path,
		model_path
	)
	observe_instancing_reuse(
		counters.observed_reuse_by_mesh_object,
		render3d.instancing_reuse_observations.mesh_object,
		mesh
	)
	local vertex_buffer_key, index_buffer_key = get_gbuffer_instance_mesh_key(mesh)
	local batch_key_groups = render3d.instancing_reuse_observations.batch_key[vertex_buffer_key]

	if not batch_key_groups then
		batch_key_groups = {}
		render3d.instancing_reuse_observations.batch_key[vertex_buffer_key] = batch_key_groups
	end

	local material_groups = batch_key_groups[index_buffer_key]

	if not material_groups then
		material_groups = {}
		batch_key_groups[index_buffer_key] = material_groups
	end

	observe_instancing_reuse(
		counters.observed_reuse_by_batch_key,
		material_groups,
		get_gbuffer_instance_material_key(material)
	)
end

local function get_gbuffer_instance_material_batches(storage, mesh, create)
	if not storage then
		if not create then return nil end

		storage = {}
	end

	local vertex_buffer_key, index_buffer_key = get_gbuffer_instance_mesh_key(mesh)
	local vertex_batches = storage[vertex_buffer_key]

	if not vertex_batches then
		if not create then return nil end

		vertex_batches = {}
		storage[vertex_buffer_key] = vertex_batches
	end

	local mesh_batches = vertex_batches[index_buffer_key]

	if not mesh_batches then
		if not create then return nil end

		mesh_batches = {}
		vertex_batches[index_buffer_key] = mesh_batches
	end

	return mesh_batches
end

local function find_gbuffer_instance_batch(mesh, material)
	local mesh_batches = get_gbuffer_instance_material_batches(render3d.gbuffer_instance_batches, mesh, false)

	if not mesh_batches then return nil end

	return mesh_batches[get_gbuffer_instance_material_key(material)]
end

local function get_or_create_gbuffer_instance_batch(mesh, material)
	render3d.gbuffer_instance_batches = render3d.gbuffer_instance_batches or {}
	local mesh_batches = get_gbuffer_instance_material_batches(render3d.gbuffer_instance_batches, mesh, true)
	local material_key = get_gbuffer_instance_material_key(material)
	local batch = mesh_batches[material_key]

	if batch then return batch end

	batch = {
		mesh = mesh,
		material = material,
		material_key = material_key,
		material_key_kind = get_gbuffer_instance_material_key_kind(material),
		world_matrices = {},
		count = 0,
	}
	mesh_batches[material_key] = batch
	return batch
end

local function find_gbuffer_instance_pending_entry(mesh, material)
	render3d.pending_gbuffer_instance_entries = render3d.pending_gbuffer_instance_entries or {}
	local mesh_entries = get_gbuffer_instance_material_batches(render3d.pending_gbuffer_instance_entries, mesh, false)

	if not mesh_entries then return nil end

	return mesh_entries[get_gbuffer_instance_material_key(material)]
end

local function create_gbuffer_instance_pending_entry(mesh, material, polygon3d, world_matrix)
	render3d.pending_gbuffer_instance_entries = render3d.pending_gbuffer_instance_entries or {}
	render3d.queued_gbuffer_pending_entries = render3d.queued_gbuffer_pending_entries or {}
	local mesh_entries = get_gbuffer_instance_material_batches(render3d.pending_gbuffer_instance_entries, mesh, true)
	local material_key = get_gbuffer_instance_material_key(material)
	local pending = {
		mesh = mesh,
		material = material,
		material_key = material_key,
		material_key_kind = get_gbuffer_instance_material_key_kind(material),
		first_polygon3d = polygon3d,
		first_world_matrix = world_matrix,
	}
	mesh_entries[material_key] = pending
	render3d.queued_gbuffer_pending_entries[#render3d.queued_gbuffer_pending_entries + 1] = pending
	pending.queue_index = #render3d.queued_gbuffer_pending_entries
	return pending
end

local function clear_gbuffer_instance_pending_entry(pending)
	if not pending then return end

	local mesh_entries = get_gbuffer_instance_material_batches(render3d.pending_gbuffer_instance_entries, pending.mesh, false)

	if mesh_entries then mesh_entries[pending.material_key] = nil end

	if render3d.queued_gbuffer_pending_entries and pending.queue_index then
		render3d.queued_gbuffer_pending_entries[pending.queue_index] = nil
	end

	pending.queue_index = nil
end

local function activate_gbuffer_instance_batch(batch, first_polygon3d, first_world_matrix)
	render3d.queued_gbuffer_instance_batches = render3d.queued_gbuffer_instance_batches or {}
	render3d.queued_gbuffer_instance_batches[#render3d.queued_gbuffer_instance_batches + 1] = batch
	batch.first_polygon3d = first_polygon3d
	batch.first_world_matrix = first_world_matrix
	batch.count = 0
	batch.world_matrices[1] = nil
	batch.world_matrices[2] = nil
	return batch
end

local function append_gbuffer_instance_world_matrix(batch, world_matrix)
	batch.count = batch.count + 1
	batch.world_matrices[batch.count] = world_matrix
	return batch.count
end

local function ensure_instance_buffer(batch, instance_count)
	local capacity = batch.instance_capacity or 0

	if capacity >= instance_count and batch.instance_buffer then
		return batch.instance_buffer
	end

	capacity = math.max(4, capacity)

	while capacity < instance_count do
		capacity = capacity * 2
	end

	if batch.instance_buffer then batch.instance_buffer:Remove() end

	batch.instance_buffer = VertexBuffer.New(capacity, INSTANCE_MATRIX_ATTRIBUTES, "render3d gbuffer instances")
	batch.instance_capacity = capacity
	return batch.instance_buffer
end

function render3d.ResetQueuedGBufferInstances()
	render3d.queued_gbuffer_instance_batches = render3d.queued_gbuffer_instance_batches or {}
	render3d.pending_gbuffer_instance_entries = {}
	render3d.queued_gbuffer_pending_entries = {}
	render3d.instancing_reuse_observations = new_instancing_reuse_observations()
	render3d.instancing_counters = reset_instancing_counters(render3d.instancing_counters)

	for i = 1, #render3d.queued_gbuffer_instance_batches do
		local batch = render3d.queued_gbuffer_instance_batches[i]
		batch.count = 0
		batch.first_polygon3d = nil
		batch.first_world_matrix = nil
		render3d.queued_gbuffer_instance_batches[i] = nil
	end
end

function render3d.ResetInstancingCounters()
	render3d.instancing_counters = reset_instancing_counters(render3d.instancing_counters)
	render3d.last_instancing_counters = reset_instancing_counters(render3d.last_instancing_counters)
	return render3d.last_instancing_counters
end

function render3d.GetInstancingCounters()
	render3d.last_instancing_counters = render3d.last_instancing_counters or new_instancing_counters()
	return render3d.last_instancing_counters
end

function render3d.GetLiveInstancingCounters()
	render3d.instancing_counters = render3d.instancing_counters or new_instancing_counters()
	return render3d.instancing_counters
end

function render3d.CanQueueGBufferInstance(polygon3d, material)
	local counters = render3d.GetLiveInstancingCounters()

	if not polygon3d or not material then
		counters.rejected.missing_args = counters.rejected.missing_args + 1
		return false
	end

	if not render3d.pipelines or not render3d.pipelines.gbuffer_instanced then
		counters.rejected.missing_pipeline = counters.rejected.missing_pipeline + 1
		return false
	end

	if render3d.IsWireframeDebugMode() then
		counters.rejected.wireframe = counters.rejected.wireframe + 1
		return false
	end

	if use_tessellated_gbuffer(material) then
		counters.rejected.tessellated = counters.rejected.tessellated + 1
		return false
	end

	if material_has_vertex_animation(material) then
		counters.rejected.vertex_animation = counters.rejected.vertex_animation + 1
		return false
	end

	if not (polygon3d.GetMesh and polygon3d:GetMesh() ~= nil) then
		counters.rejected.missing_mesh = counters.rejected.missing_mesh + 1
		return false
	end

	return true
end

function render3d.QueueGBufferInstance(polygon3d, material, world_matrix, model_path)
	local counters = render3d.GetLiveInstancingCounters()
	counters.queue_attempts = counters.queue_attempts + 1

	if not render3d.CanQueueGBufferInstance(polygon3d, material) then
		return false
	end

	local mesh = polygon3d:GetMesh()
	observe_gbuffer_instance_reuse(counters, mesh, material, model_path)
	local batch = find_gbuffer_instance_batch(mesh, material)

	if batch and batch.count > 0 then
		append_gbuffer_instance_world_matrix(batch, world_matrix)
		counters.queued_instances = counters.queued_instances + 1
		return true
	end

	local pending = find_gbuffer_instance_pending_entry(mesh, material)

	if pending then
		clear_gbuffer_instance_pending_entry(pending)
		batch = batch or get_or_create_gbuffer_instance_batch(mesh, material)
		activate_gbuffer_instance_batch(batch, pending.first_polygon3d, pending.first_world_matrix)
		append_gbuffer_instance_world_matrix(batch, pending.first_world_matrix)
		append_gbuffer_instance_world_matrix(batch, world_matrix)
		counters.queued_instances = counters.queued_instances + 1
		return true
	end

	create_gbuffer_instance_pending_entry(mesh, material, polygon3d, world_matrix)
	counters.queued_batches = counters.queued_batches + 1
	counters.queued_batches_by_material_key_kind[get_gbuffer_instance_material_key_kind(material)] = counters.queued_batches_by_material_key_kind[get_gbuffer_instance_material_key_kind(material)] + 1
	counters.queued_instances = counters.queued_instances + 1
	return true
end

function render3d.UploadGBufferConstants()
	if not render3d.pipelines.gbuffer then return end

	local cmd = render.GetCommandBuffer()
	local material = render3d.GetMaterial()
	local pipeline = use_tessellated_gbuffer(material) and
		render3d.pipelines.gbuffer_tess or
		render3d.pipelines.gbuffer
	local double_sided = material:GetDoubleSided()
	local cull_mode = double_sided and "none" or orientation.CULL_MODE
	local polygon_mode = render3d.IsWireframeDebugMode() and "line" or "fill"
	pipeline:UploadConstants()
	-- UploadConstants binds the graphics pipeline and reapplies its cached
	-- dynamic state, so override raster state after the bind for this draw.
	cmd:SetPolygonMode(polygon_mode)
	cmd:SetCullMode(cull_mode)
end

function render3d.UploadInstancedGBufferConstants()
	if not render3d.pipelines.gbuffer_instanced then return end

	local cmd = render.GetCommandBuffer()
	local material = render3d.GetMaterial()
	local double_sided = material:GetDoubleSided()
	local cull_mode = double_sided and "none" or orientation.CULL_MODE
	local polygon_mode = render3d.IsWireframeDebugMode() and "line" or "fill"
	render3d.pipelines.gbuffer_instanced:UploadConstants()
	cmd:SetPolygonMode(polygon_mode)
	cmd:SetCullMode(cull_mode)
end

function render3d.FlushQueuedGBufferInstances()
	if
		not render3d.queued_gbuffer_instance_batches and
		not render3d.queued_gbuffer_pending_entries
	then
		return
	end

	local counters = render3d.GetLiveInstancingCounters()

	if render3d.queued_gbuffer_pending_entries then
		for i = 1, #render3d.queued_gbuffer_pending_entries do
			local pending = render3d.queued_gbuffer_pending_entries[i]

			if pending then
				counters.flushed_batches = counters.flushed_batches + 1
				counters.flushed_instances = counters.flushed_instances + 1
				counters.singleton_fallback_draws = counters.singleton_fallback_draws + 1
				counters.singleton_fallback_draws_by_material_key_kind[pending.material_key_kind] = counters.singleton_fallback_draws_by_material_key_kind[pending.material_key_kind] + 1
				render3d.SetWorldMatrix(pending.first_world_matrix)
				render3d.SetCurrentPolygon3D(pending.first_polygon3d)
				render3d.SetMaterial(pending.material)
				render3d.UploadGBufferConstants()
				pending.first_polygon3d:Draw()
			end
		end
	end

	for i = 1, #render3d.queued_gbuffer_instance_batches do
		local batch = render3d.queued_gbuffer_instance_batches[i]

		if batch.count == 1 then
			counters.flushed_batches = counters.flushed_batches + 1
			counters.flushed_instances = counters.flushed_instances + 1
			counters.singleton_fallback_draws = counters.singleton_fallback_draws + 1
			counters.singleton_fallback_draws_by_material_key_kind[batch.material_key_kind] = counters.singleton_fallback_draws_by_material_key_kind[batch.material_key_kind] + 1
			render3d.SetWorldMatrix(batch.first_world_matrix)
			render3d.SetCurrentPolygon3D(batch.first_polygon3d)
			render3d.SetMaterial(batch.material)
			render3d.UploadGBufferConstants()
			batch.first_polygon3d:Draw()
		elseif batch.count > 1 then
			counters.flushed_batches = counters.flushed_batches + 1
			counters.flushed_instances = counters.flushed_instances + batch.count
			counters.instanced_draws = counters.instanced_draws + 1
			counters.instanced_draws_by_material_key_kind[batch.material_key_kind] = counters.instanced_draws_by_material_key_kind[batch.material_key_kind] + 1
			local instance_buffer = ensure_instance_buffer(batch, batch.count)
			local ptr = ffi.cast("float *", instance_buffer.data)

			for instance_index = 1, batch.count do
				batch.world_matrices[instance_index]:CopyToFloatPointer(ptr + (instance_index - 1) * 16)
			end

			instance_buffer.buffer:CopyData(instance_buffer.data, batch.count * instance_buffer.stride)
			render3d.SetCurrentPolygon3D(nil)
			render3d.SetMaterial(batch.material)
			render3d.UploadInstancedGBufferConstants()
			batch.mesh:DrawInstanced(render.GetCommandBuffer(), batch.count, {instance_buffer})
		end
	end

	render3d.last_instancing_counters = copy_instancing_counters(render3d.last_instancing_counters, counters)
	render3d.last_instancing_counters.completed_frame = system.GetFrameNumber()
	render3d.ResetQueuedGBufferInstances()
end

function render3d.UploadForwardOverlayConstants()
	if not render3d.pipelines.forward_overlay then return end

	local cmd = render.GetCommandBuffer()
	local material = render3d.GetMaterial()
	local double_sided = render3d.GetMaterial():GetDoubleSided()
	local translucent = material:GetTranslucent()
	local cull_mode = double_sided and "none" or orientation.CULL_MODE
	local polygon_mode = render3d.IsWireframeDebugMode() and "line" or "fill"
	render3d.pipelines.forward_overlay:UploadConstants()
	cmd:SetPolygonMode(polygon_mode)
	cmd:SetCullMode(cull_mode)
	cmd:SetColorBlendEnable(0, translucent)
	cmd:SetColorBlendEquation(
		0,
		translucent and
			{
				src_color_blend_factor = "src_alpha",
				dst_color_blend_factor = "one_minus_src_alpha",
				color_blend_op = "add",
				src_alpha_blend_factor = "one",
				dst_alpha_blend_factor = "zero",
				alpha_blend_op = "add",
			} or
			{
				src_color_blend_factor = "one",
				dst_color_blend_factor = "zero",
				color_blend_op = "add",
				src_alpha_blend_factor = "one",
				dst_alpha_blend_factor = "zero",
				alpha_blend_op = "add",
			}
	)
end

do
	render3d.camera = render3d.camera or Camera3D.New()
	render3d.camera_stack = render3d.camera_stack or {}
	render3d.world_matrix = render3d.world_matrix or Matrix44()
	render3d.prev_view_matrix = render3d.prev_view_matrix or Matrix44()
	render3d.prev_projection_matrix = render3d.prev_projection_matrix or Matrix44()

	function render3d.GetCamera()
		return render3d.camera
	end

	function render3d.SetCamera(camera)
		render3d.camera = camera or Camera3D.New()
		return render3d.camera
	end

	function render3d.PushCamera(camera)
		table.insert(render3d.camera_stack, render3d.camera)
		render3d.camera = camera or Camera3D.New()
		return render3d.camera
	end

	function render3d.PopCamera()
		local camera = table.remove(render3d.camera_stack)

		if camera then render3d.camera = camera end

		return render3d.camera
	end

	function render3d.SetWorldMatrix(world)
		render3d.world_matrix = world
	end

	function render3d.GetWorldMatrix()
		return render3d.world_matrix
	end

	local pv_cached = Matrix44()
	local pvm_cached = Matrix44()

	function render3d.GetProjectionViewMatrix()
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * V * P
		render3d.camera:BuildViewMatrix():GetMultiplied(render3d.camera:BuildProjectionMatrix(), pv_cached)
		return pv_cached
	end

	function render3d.GetProjectionViewWorldMatrix()
		-- ORIENTATION / TRANSFORMATION: Coordinate system defined in orientation.lua
		-- Row-major: v * W * V * P
		render3d.world_matrix:GetMultiplied(render3d.camera:BuildViewMatrix(), pvm_cached)
		pvm_cached:GetMultiplied(render3d.camera:BuildProjectionMatrix(), pvm_cached)
		return pvm_cached
	end
end

function render3d.GetLights()
	return Light.Instances
end

-- Debug state for cascade visualization
render3d.debug_cascade_colors = false

function render3d.SetDebugCascadeColors(enabled)
	render3d.debug_cascade_colors = enabled
end

function render3d.GetDebugCascadeColors()
	return render3d.debug_cascade_colors
end

event.AddListener("WindowFramebufferResized", "render3d", function(wnd, size)
	if render.target:IsValid() and render.target.config.offscreen then return end

	render3d.camera:SetViewport(Rect(0, 0, size.x, size.y))
end)

function render3d.SetMaterial(mat)
	render3d.current_material = mat
end

function render3d.GetMaterial()
	return render3d.current_material or render3d.GetDefaultMaterial()
end

function render3d.SetCurrentPolygon3D(poly)
	render3d.current_polygon3d = poly
end

function render3d.GetCurrentPolygon3D()
	return render3d.current_polygon3d
end

function render3d.SetForwardOverlayClipPlane(origin, normal)
	if origin and normal then
		render3d.forward_overlay_clip_plane_enabled = true
		render3d.forward_overlay_clip_plane_origin = origin
		render3d.forward_overlay_clip_plane_normal = normal
		return
	end

	render3d.forward_overlay_clip_plane_enabled = false

	if not render3d.forward_overlay_clip_plane_origin then
		render3d.forward_overlay_clip_plane_origin = Vec3(0, 0, 0)
	end

	if not render3d.forward_overlay_clip_plane_normal then
		render3d.forward_overlay_clip_plane_normal = Vec3(0, 0, 1)
	end
end

function render3d.IsForwardOverlayClipPlaneEnabled()
	return render3d.forward_overlay_clip_plane_enabled == true
end

function render3d.GetForwardOverlayClipPlaneOrigin()
	return render3d.forward_overlay_clip_plane_origin or Vec3(0, 0, 0)
end

function render3d.GetForwardOverlayClipPlaneNormal()
	return render3d.forward_overlay_clip_plane_normal or Vec3(0, 0, 1)
end

do
	local default = Material.New()

	function render3d.GetDefaultMaterial()
		return default
	end
end

function render3d.SetEnvironmentTexture(texture)
	render3d.environment_texture = texture
end

function render3d.GetEnvironmentTexture()
	return render3d.environment_texture
end

function render3d.SetOceanEnabled(enabled)
	render3d.ocean_enabled = enabled ~= false
end

function render3d.IsOceanEnabled()
	if render3d.ocean_enabled == nil then return false end

	return render3d.ocean_enabled == true
end

function render3d.SetOceanLevel(level)
	render3d.ocean_level = level
end

function render3d.GetOceanLevelOverride()
	return render3d.ocean_level
end

function render3d.GetOceanLevel()
	if render3d.ocean_level ~= nil then return render3d.ocean_level end

	return atmosphere.GetOceanLevel()
end

do -- mesh
	local Mesh = import("goluwa/render/mesh.lua")

	function render3d.CreateMesh(vertices, indices, index_type, index_count)
		return Mesh.New(
			render3d.pipelines.gbuffer:GetVertexAttributes(),
			vertices,
			indices,
			index_type,
			index_count
		)
	end
end

if HOTRELOAD then render3d.Initialize() end

return render3d
