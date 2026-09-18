local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local assets = import("goluwa/assets.lua")
local Texture = import("goluwa/render/texture.lua")
local MAX_CASCADES = directional_shadows.MAX_CASCADES
local ENABLE_VOLUMETRIC_FOG = true
local FOG_DEBUG_MODE = 0

if os.getenv("FOG_DEBUG") == "froxel" then
	FOG_DEBUG_MODE = 1
elseif os.getenv("FOG_DEBUG") == "scenefog" then
	FOG_DEBUG_MODE = 2
elseif os.getenv("FOG_DEBUG") == "slices" then
	FOG_DEBUG_MODE = 3
elseif os.getenv("FOG_DEBUG") == "samples" then
	FOG_DEBUG_MODE = 4
elseif os.getenv("FOG_DEBUG") == "substeps" then
	FOG_DEBUG_MODE = 5
end

local DEBUG_GOD_RAY_BOOST = 1.0
local DEBUG_GOD_RAY_SUN_FACING_BOOST = 1
local DEBUG_GOD_RAY_SHADOW_CONTRAST = 1.0
local DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE = 1.0
local FROXEL_TILE_SIZE = 16
local FROXEL_SLICE_COUNT = 12
local FROXEL_INTEGRATION_STEPS = 8 -- sub-steps per slice; more = tighter light falloff integration
local FROXEL_LIGHT_TAPS = 2 -- 1 = light at sub-step midpoint, 2 = two taps averaged
local FROXEL_OCCLUSION_SOFTNESS = 0.15 -- 0 = hard BVH oct occlusion step, >0 = soft margin as fraction of occluder distance
local FROXEL_NEAR_BREAK = 10.0 -- meters
local FROXEL_NEAR_SLICE_RATIO = 0.6
local volumetric_froxels = {
	texture = nil,
	view = nil,
	layer_views = nil,
	sampler = nil,
	width = 0,
	height = 0,
	current_slice = 0,
}
local volumetric_froxel_fallback = {
	texture = nil,
	view = nil,
	sampler = nil,
}

local function destroy_volumetric_froxel_resources()
	if volumetric_froxels.view and volumetric_froxels.view.Remove then
		volumetric_froxels.view:Remove()
	end

	if volumetric_froxels.layer_views then
		for _, view in pairs(volumetric_froxels.layer_views) do
			if view and view.Remove then view:Remove() end
		end
	end

	volumetric_froxels.view = nil
	volumetric_froxels.layer_views = nil

	if volumetric_froxels.texture and volumetric_froxels.texture.Remove then
		volumetric_froxels.texture:Remove()
	end

	volumetric_froxels.texture = nil
	volumetric_froxels.sampler = nil
	volumetric_froxels.width = 0
	volumetric_froxels.height = 0
	volumetric_froxels.current_slice = 0
end

local function ensure_volumetric_froxel_fallback_resources()
	if volumetric_froxel_fallback.texture then
		return volumetric_froxel_fallback.texture,
		volumetric_froxel_fallback.view,
		volumetric_froxel_fallback.sampler
	end

	local texture = Texture.New{
		width = 1,
		height = 1,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = 1,
			usage = {"sampled", "transfer_dst"},
		},
		view = false,
		sampler = {
			min_filter = "nearest",
			mag_filter = "nearest",
			wrap_s = "clamp_to_edge",
			wrap_t = "clamp_to_edge",
			wrap_r = "clamp_to_edge",
		},
	}
	local view = texture:GetImage():CreateView{
		view_type = "2d_array",
		base_array_layer = 0,
		layer_count = 1,
		base_mip_level = 0,
		level_count = 1,
	}
	local sampler = render.CreateSampler(texture:GetSamplerConfig())
	volumetric_froxel_fallback.texture = texture
	volumetric_froxel_fallback.view = view
	volumetric_froxel_fallback.sampler = sampler
	return texture, view, sampler
end

local function ensure_volumetric_froxel_resources()
	if not ENABLE_VOLUMETRIC_FOG then
		destroy_volumetric_froxel_resources()
		return nil
	end

	local size = render.GetRenderImageSize()
	local width = math.max(1, math.ceil(size.x / FROXEL_TILE_SIZE))
	local height = math.max(1, math.ceil(size.y / FROXEL_TILE_SIZE))

	if
		not volumetric_froxels.texture or
		volumetric_froxels.width ~= width or
		volumetric_froxels.height ~= height
	then
		destroy_volumetric_froxel_resources()
		volumetric_froxels.width = width
		volumetric_froxels.height = height
		local texture = Texture.New{
			width = width,
			height = height,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = 1,
			image = {
				array_layers = FROXEL_SLICE_COUNT,
				usage = {"color_attachment", "sampled"},
			},
			view = {
				view_type = "2d_array",
				layer_count = FROXEL_SLICE_COUNT,
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				wrap_s = "clamp_to_edge",
				wrap_t = "clamp_to_edge",
				wrap_r = "clamp_to_edge",
			},
		}
		texture:SetDebugName("render3d volumetric froxels")
		volumetric_froxels.texture = texture
		volumetric_froxels.view = texture:GetImage():CreateView{
			view_type = "2d_array",
			base_array_layer = 0,
			layer_count = FROXEL_SLICE_COUNT,
			base_mip_level = 0,
			level_count = 1,
		}
		volumetric_froxels.sampler = render.CreateSampler(texture:GetSamplerConfig())
		volumetric_froxels.layer_views = {}

		for layer = 0, FROXEL_SLICE_COUNT - 1 do
			volumetric_froxels.layer_views[layer] = texture:GetImage():CreateView{
				view_type = "2d",
				base_array_layer = layer,
				layer_count = 1,
				base_mip_level = 0,
				level_count = 1,
			}

			if volumetric_froxels.layer_views[layer].SetDebugName then
				volumetric_froxels.layer_views[layer]:SetDebugName("render3d volumetric froxels layer " .. tostring(layer))
			end
		end
	end

	return volumetric_froxels.texture
end

local function write_ocean_distance_texture(self, block, key)
	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
	else
		block[key] = -1
	end
end

local function get_froxel_volume_descriptor()
	local texture = ensure_volumetric_froxel_resources()

	if texture and volumetric_froxels.view then
		return {volumetric_froxels.view, volumetric_froxels.sampler}
	end

	local _, fallback_view, fallback_sampler = ensure_volumetric_froxel_fallback_resources()
	return {fallback_view, fallback_sampler}
end

local function draw_volumetric_froxel_build(self, cmd)
	if not ENABLE_VOLUMETRIC_FOG then return end

	local texture = ensure_volumetric_froxel_resources()

	if not texture then return end

	render.TransitionResourceTo(
		texture,
		"color_attachment_optimal",
		{
			cmd = cmd,
			srcStage = "fragment_shader",
			srcAccess = "shader_read",
			dstStage = "color_attachment_output",
			dstAccess = "color_attachment_write",
			base_array_layer = 0,
			layer_count = FROXEL_SLICE_COUNT,
			base_mip_level = 0,
			level_count = 1,
		}
	)

	for slice = 0, FROXEL_SLICE_COUNT - 1 do
		volumetric_froxels.current_slice = slice
		cmd:BeginRendering{
			color_attachments = {
				{
					color_image_view = volumetric_froxels.layer_views[slice],
					clear_color = {0, 0, 0, 1},
					load_op = "clear",
					store_op = "store",
				},
			},
			w = volumetric_froxels.width,
			h = volumetric_froxels.height,
		}
		cmd:SetViewport(0, 0, volumetric_froxels.width, volumetric_froxels.height, 0, 1)
		cmd:SetScissor(0, 0, volumetric_froxels.width, volumetric_froxels.height)
		self:Bind(cmd)
		self:UploadConstants()
		cmd:Draw(3, 1, 0, 0)
		cmd:EndRendering()
	end

	render.TransitionResourceFrom(
		texture,
		"shader_read_only_optimal",
		{
			cmd = cmd,
			srcStage = "color_attachment_output",
			srcAccess = "color_attachment_write",
			dstStage = "fragment_shader",
			dstAccess = "shader_read",
			base_array_layer = 0,
			layer_count = FROXEL_SLICE_COUNT,
			base_mip_level = 0,
			level_count = 1,
		}
	)
end

local get_raw_scene_source_texture = post_source.WriteRawSceneSourceTexture
local get_scene_source_texture = post_source.WriteSceneSourceTexture

local function build_scene_light_block_fields()
	return {
		{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
		{"light_count", "int"},
		{"shadows", scene_lights.BuildShadowsBlockLayout()},
		atmosphere.GetBlockLayout(),
		unpack(light_occlusion.GetBlockLayout()),
	}
end

local function write_atmosphere_block(self, block)
	atmosphere.WriteBlock(
		self,
		block,
		render3d.GetRenderCamera():GetPosition(),
		directional_shadows.GetPrimarySunDirection(render3d.GetLights())
	)
end

local function write_fog_common_block(self, block)
	local lights, light_instance_indices = scene_lights.GetVisibleLights()
	scene_lights.WriteLightsBlock(block.lights, lights)
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	write_atmosphere_block(self, block)
	light_occlusion.WriteOcclusionBlock(block, lights, light_instance_indices)
	return block
end

local function get_sun_helpers_glsl(data_block)
	return (
			[[
	int get_current_primary_sun_index() {
		for (int i = 0; i < ]] .. data_block .. [[.light_count; i++) {
			if (get_light_type(]] .. data_block .. [[.lights[i]) == 0) {
				return i;
			}
		}

		return -1;
	}

	vec3 get_current_primary_sun_direction() {
		int sun_index = get_current_primary_sun_index();

		if (sun_index < 0) {
			return vec3(0.0, 1.0, 0.0);
		}

		vec3 light_dir = ]] .. data_block .. [[.lights[sun_index].direction.xyz;

		if (length(light_dir) < 1e-4) {
			return vec3(0.0, 1.0, 0.0);
		}

		return normalize(-light_dir);
	}

	float get_current_primary_sun_intensity() {
		int sun_index = get_current_primary_sun_index();
		return sun_index < 0 ? 1.0 : ]] .. data_block .. [[.lights[sun_index].color.a;
	}
	]]
		)
end

local r = {
	{
		name = "volumetric_froxel_build",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		on_draw = draw_volumetric_froxel_build,
		fragment = {
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					set_index = 2,
					args = light_occlusion.GetOcclusionDescriptor,
				},
			},
			custom_declarations = light_occlusion.GetDeclarationGLSL(0, 2) .. [[
			]],
			uniform_buffers = {
				{
					name = "froxel_data",
					binding_index = 4,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{"ocean_distance_tex", "int"},
						{"time", "float"},
						{"blue_noise_tex", "int"},
						{"near_z", "float"},
						{"far_z", "float"},
						{"froxel_resolution", "vec2"},
						{"current_slice", "int"},
						{"slice_count", "int"},
						unpack(build_scene_light_block_fields()),
					},
					write = function(self, block)
						ensure_volumetric_froxel_resources()
						render3d.WriteCameraBlock(self, block)
						render3d.WriteGBufferBlock(self, block)
						write_ocean_distance_texture(self, block, "ocean_distance_tex")
						block.time = system.GetElapsedTime()
						block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
						block.near_z = render3d.GetRenderCamera():GetNearZ()
						block.far_z = render3d.GetRenderCamera():GetFarZ()
						block.froxel_resolution[0] = volumetric_froxels.width
						block.froxel_resolution[1] = volumetric_froxels.height
						block.current_slice = volumetric_froxels.current_slice or 0
						block.slice_count = FROXEL_SLICE_COUNT
						return write_fog_common_block(self, block)
					end,
				},
			},
			shader = (
					"const int FOG_DEBUG_MODE = %d;\n"
				):format(FOG_DEBUG_MODE) .. light_occlusion.GetSamplingGLSL("froxel_data") .. [[
			const int VOLUMETRIC_FROXEL_SLICE_COUNT = ]] .. FROXEL_SLICE_COUNT .. [[;
			const int VOLUMETRIC_SLICE_INTEGRATION_STEPS = ]] .. FROXEL_INTEGRATION_STEPS .. [[;
			const int VOLUMETRIC_LOCAL_LIGHT_LIMIT = 8;
			const int FROXEL_LIGHT_TAPS = ]] .. FROXEL_LIGHT_TAPS .. [[;
			const float FROXEL_OCCLUSION_SOFTNESS = ]] .. FROXEL_OCCLUSION_SOFTNESS .. [[;
			const float FROXEL_NEAR_BREAK = ]] .. FROXEL_NEAR_BREAK .. [[;
			const float FROXEL_NEAR_SLICE_RATIO = ]] .. FROXEL_NEAR_SLICE_RATIO .. [[;
			const float DEBUG_GOD_RAY_BOOST = ]] .. DEBUG_GOD_RAY_BOOST .. [[;
			const float DEBUG_GOD_RAY_SUN_FACING_BOOST = ]] .. DEBUG_GOD_RAY_SUN_FACING_BOOST .. [[;
			const float DEBUG_GOD_RAY_SHADOW_CONTRAST = ]] .. DEBUG_GOD_RAY_SHADOW_CONTRAST .. [[;
			const float DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE = ]] .. DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE .. [[;

			]] .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_intensity()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. [[

			float get_slice_view_depth(float slice_index) {
				float near_z = max(froxel_data.near_z, 0.001);
				float far_z = max(froxel_data.far_z, near_z + 0.001);
				float u = clamp(slice_index / float(max(froxel_data.slice_count, 1)), 0.0, 1.0);
				float break_distance = max(min(FROXEL_NEAR_BREAK, far_z * 0.5), near_z * 1.01);
				if (u <= FROXEL_NEAR_SLICE_RATIO) {
					return near_z * pow(break_distance / near_z, u / FROXEL_NEAR_SLICE_RATIO);
				}
				return break_distance * pow(far_z / break_distance, (u - FROXEL_NEAR_SLICE_RATIO) / (1.0 - FROXEL_NEAR_SLICE_RATIO));
			}

			vec2 get_froxel_uv() {
				return gl_FragCoord.xy / max(froxel_data.froxel_resolution, vec2(1.0));
			}

			vec3 get_view_ray(vec2 froxel_uv) {
				vec4 near_clip_pos = vec4(froxel_uv * 2.0 - 1.0, 0.0, 1.0);
				vec4 far_clip_pos = vec4(froxel_uv * 2.0 - 1.0, 1.0, 1.0);
				vec4 near_view_pos = froxel_data.inv_projection * near_clip_pos;
				vec4 far_view_pos = froxel_data.inv_projection * far_clip_pos;
				near_view_pos /= near_view_pos.w;
				far_view_pos /= far_view_pos.w;
				return far_view_pos.xyz - near_view_pos.xyz;
			}

			vec3 get_near_view_pos(vec2 froxel_uv) {
				vec4 near_clip_pos = vec4(froxel_uv * 2.0 - 1.0, 0.0, 1.0);
				vec4 near_view_pos = froxel_data.inv_projection * near_clip_pos;
				near_view_pos /= near_view_pos.w;
				return near_view_pos.xyz;
			}

			vec3 get_world_pos_at_view_depth(float view_depth) {
				vec2 froxel_uv = get_froxel_uv();
				vec3 near_view_pos = get_near_view_pos(froxel_uv);
				vec3 view_ray = get_view_ray(froxel_uv);
				float ray_t = (-view_depth - near_view_pos.z) / min(view_ray.z, -1e-4);
				vec3 view_pos = near_view_pos + view_ray * ray_t;
				return (froxel_data.inv_view * vec4(view_pos, 1.0)).xyz;
			}

			vec3 get_world_ray() {
				vec3 view_dir = get_view_ray(get_froxel_uv());
				return normalize(mat3(froxel_data.inv_view) * view_dir);
			}

			float get_scene_hit_distance() {
				float d = texture(TEXTURE(froxel_data.depth_tex), get_froxel_uv()).r;

				if (d >= 0.9999) return -1.0;

				vec4 clip_pos = vec4(get_froxel_uv() * 2.0 - 1.0, d, 1.0);
				vec4 view_pos = froxel_data.inv_projection * clip_pos;
				view_pos /= view_pos.w;
				vec3 world_pos = (froxel_data.inv_view * vec4(view_pos.xyz, 1.0)).xyz;
				return length(world_pos - froxel_data.camera_position.xyz);
			}

			vec3 get_volumetric_scattering_light(vec3 ray_dir, vec3 sun_dir, float sun_visibility) {
				float day_factor = smoothstep(-0.08, 0.2, sun_dir.y);
				float horizon_visibility = get_fog_sun_horizon_visibility(sun_dir);
				float sun_facing = clamp(dot(ray_dir, sun_dir) * 0.5 + 0.5, 0.0, 1.0);
				float forward_scatter = pow(sun_facing, 16.0);
				float sun_facing_boost = 1.0 + DEBUG_GOD_RAY_SUN_FACING_BOOST * pow(sun_facing, 48.0);
				vec3 sun_tint = mix(vec3(1.0, 0.6, 0.42), vec3(1.0, 0.97, 0.92), day_factor);
				float shadow_visibility = pow(clamp(sun_visibility, 0.0, 1.0), DEBUG_GOD_RAY_SHADOW_CONTRAST);
				float direct_visibility = horizon_visibility * shadow_visibility;
				return sun_tint * (0.015 + 0.14 * forward_scatter) * direct_visibility * ATMOSPHERE_SUN_INTENSITY * DEBUG_GOD_RAY_BOOST * sun_facing_boost;
			}

			float get_froxel_sun_visibility(vec3 world_pos, vec3 sun_dir) {
				return get_fog_sun_visibility(world_pos, sun_dir);
			}

			float calculateLocalDirectionalMediumShadow(vec3 world_pos, vec3 light_dir) {
				int shadow_map_idx = froxel_data.shadows.local_directional_shadow_map_index;
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectMediumShadowMap(
					froxel_data.shadows.local_directional_light_space_matrix,
					world_pos,
					light_dir,
					froxel_data.shadows.local_directional_shadow_texel_world_size,
					proj_coords
				)) {
					return 1.0;
				}

				return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			float get_froxel_light_occlusion(int slot, vec3 light_pos, float range, vec3 world_pos) {
				if (FROXEL_OCCLUSION_SOFTNESS <= 0.0) {
					return light_oct_shadow_factor(slot, light_pos, range, world_pos);
				}

				if (slot < 0 || slot >= LIGHT_OCCL_MAX_SLOTS || froxel_data.bvh_oct_active == 0) return 1.0;

				vec3 to_pos = world_pos - light_pos;
				float dist = length(to_pos);
				if (dist >= range) return 1.0;

				float occl = light_oct_fetch(slot, to_pos / max(dist, 1e-5));
				if (occl <= 0.0) return 1.0;

				float margin = (dist - occl * (1.0 + froxel_data.bvh_oct_bias)) / max(occl * FROXEL_OCCLUSION_SOFTNESS, 1e-5);
				return 1.0 - smoothstep(0.0, 1.0, margin);
			}

			vec3 get_additional_volumetric_light(vec3 ray_dir, vec3 world_pos) {
				vec3 fog_light = vec3(0.0);
				int processed_local_lights = 0;

				for (int i = 0; i < froxel_data.light_count; i++) {
					lights_t light = froxel_data.lights[i];
					int type = get_light_type(light);
					if (type == 0) continue;
					if (processed_local_lights >= VOLUMETRIC_LOCAL_LIGHT_LIMIT) break;

					vec3 light_color = light.color.rgb * light.color.a;
					vec3 L = vec3(0.0);
					float attenuation = 1.0;

					if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation)) {
						continue;
					}

					if (attenuation <= 0.0001) continue;

					float occlusion_factor = get_froxel_light_occlusion(froxel_data.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);

					if (occlusion_factor <= 0.0) continue;

					processed_local_lights++;

					float shadow_factor = 1.0;

					if (type == 1) {
						int point_shadow_slot = getPointShadowSlot(i);

						if (point_shadow_slot >= 0) {
							shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, L, L);
						}
					} else if (
						type == 2 &&
						i == froxel_data.shadows.local_directional_shadow_light_index &&
						froxel_data.shadows.local_directional_shadow_map_index >= 0
					) {
						shadow_factor = calculateLocalDirectionalMediumShadow(world_pos, L);
					}

					float view_alignment = clamp(dot(ray_dir, L) * 0.5 + 0.5, 0.0, 1.0);
					float phase = type == 2
						? 0.08 + 0.20 * pow(view_alignment, 2.0)
						: 0.03 + 0.18 * pow(view_alignment, 6.0);
					fog_light += light_color * attenuation * shadow_factor * occlusion_factor * phase;
				}

				return fog_light;
			}

			void main() {
				vec3 ray_dir = get_world_ray();
				vec3 sun_dir = get_current_primary_sun_direction();

				float max_world_distance = length(get_world_pos_at_view_depth(froxel_data.far_z) - froxel_data.camera_position.xyz);

				float scene_hit_distance = get_scene_hit_distance();

				if (scene_hit_distance > 0.0) {
					max_world_distance = min(max_world_distance, scene_hit_distance + 0.1);
				}
				vec3 fog_ray_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float slice_start_view = get_slice_view_depth(float(froxel_data.current_slice));
				float slice_end_view = get_slice_view_depth(float(froxel_data.current_slice + 1));
				vec3 slice_start_world_pos = get_world_pos_at_view_depth(slice_start_view);
				vec3 slice_end_world_pos = get_world_pos_at_view_depth(slice_end_view);
				float slice_start_world = length(slice_start_world_pos - froxel_data.camera_position.xyz);
				float slice_end_world = length(slice_end_world_pos - froxel_data.camera_position.xyz);

				if (FOG_DEBUG_MODE == 4) {
					float near_z = max(froxel_data.near_z, 0.001);
					float far_z = max(froxel_data.far_z, near_z + 0.001);
					float log_scale = 1.0 / log(far_z / near_z);
					float slice_thickness = max(slice_end_world - slice_start_world, 1e-4);
					float substep_width = slice_thickness / float(VOLUMETRIC_SLICE_INTEGRATION_STEPS);
					vec3 world_center = get_world_pos_at_view_depth(0.5 * (slice_start_view + slice_end_view));
					float sample_offset = abs(length(world_center - froxel_data.camera_position.xyz) - 0.5 * (slice_start_world + slice_end_world)) / slice_thickness;
					set_color(
						vec4(
							float(froxel_data.current_slice) / max(float(froxel_data.slice_count), 1.0),
							clamp(log(max(substep_width, 1e-4) / near_z) * log_scale, 0.0, 1.0),
							clamp(sample_offset, 0.0, 1.0),
							1.0
						)
					);
					return;
				}

				if (FOG_DEBUG_MODE == 5) {
					float sun_visibility_min = 1.0;
					float sun_visibility_max = 0.0;
					vec3 sun_center = vec3(0.0);
					vec3 light_center = vec3(0.0);
					for (int step = 0; step < VOLUMETRIC_SLICE_INTEGRATION_STEPS; step++) {
						float step_u = (float(step) + 0.5) / float(VOLUMETRIC_SLICE_INTEGRATION_STEPS);
						vec3 world_sample = get_world_pos_at_view_depth(mix(slice_start_view, slice_end_view, step_u));
						float sun_visibility = get_froxel_sun_visibility(world_sample, sun_dir);
						sun_visibility_min = min(sun_visibility_min, sun_visibility);
						sun_visibility_max = max(sun_visibility_max, sun_visibility);
						if (step == VOLUMETRIC_SLICE_INTEGRATION_STEPS / 2) {
							sun_center = get_volumetric_scattering_light(ray_dir, sun_dir, sun_visibility);
							light_center = get_additional_volumetric_light(ray_dir, world_sample);
						}
					}
					set_color(
						vec4(
							length(sun_center),
							length(light_center),
							clamp(sun_visibility_max - sun_visibility_min, 0.0, 1.0),
							1.0
						)
					);
					return;
				}

				vec3 total_scattering = vec3(0.0);
				float total_transmittance = 1.0;

				for (int i = 0; i < VOLUMETRIC_FROXEL_SLICE_COUNT; i++) {
					if (i > froxel_data.current_slice) break;

					float accum_slice_start_view = get_slice_view_depth(float(i));
					float accum_slice_end_view = get_slice_view_depth(float(i + 1));
					for (int step = 0; step < VOLUMETRIC_SLICE_INTEGRATION_STEPS; step++) {
						float step_start_u = float(step) / float(VOLUMETRIC_SLICE_INTEGRATION_STEPS);
						float step_end_u = float(step + 1) / float(VOLUMETRIC_SLICE_INTEGRATION_STEPS);
						float sub_slice_start_view = mix(accum_slice_start_view, accum_slice_end_view, step_start_u);
						float sub_slice_end_view = mix(accum_slice_start_view, accum_slice_end_view, step_end_u);
						vec3 sub_slice_start_world_pos = get_world_pos_at_view_depth(sub_slice_start_view);
						vec3 sub_slice_end_world_pos = get_world_pos_at_view_depth(sub_slice_end_view);
						float sub_slice_start_world = length(sub_slice_start_world_pos - froxel_data.camera_position.xyz);
						float sub_slice_end_world = length(sub_slice_end_world_pos - froxel_data.camera_position.xyz);
						float segment_start = sub_slice_start_world;
						float segment_end = min(sub_slice_end_world, max_world_distance);

						if (segment_end <= segment_start) continue;

						float sample_distance = 0.5 * (segment_start + segment_end);
						float step_world = segment_end - segment_start;
						float step_fog = step_world * fog_distance_scale;
						float sample_view_depth = 0.5 * (sub_slice_start_view + sub_slice_end_view);
						vec3 world_sample = get_world_pos_at_view_depth(sample_view_depth);
						vec3 fog_sample = fog_ray_origin + ray_dir * (sample_distance * fog_distance_scale);
						float fog_density = scenery_fog_density(fog_sample);

						if (fog_density <= 1e-6) continue;

						float tau = fog_density * SCENERY_FOG_EXTINCTION * step_fog;
						float segment_transmittance = exp(-tau);
						float segment_scatter_amount = 1.0 - exp(-tau * 1);
						float sun_visibility = get_froxel_sun_visibility(world_sample, sun_dir);
						vec3 sun_scattering_light = get_volumetric_scattering_light(ray_dir, sun_dir, sun_visibility);
						vec3 scattering_light = sun_scattering_light;

						if (FROXEL_LIGHT_TAPS <= 1) {
							scattering_light += get_additional_volumetric_light(ray_dir, world_sample);
						} else {
							vec3 light_tap_a = get_world_pos_at_view_depth(mix(sub_slice_start_view, sub_slice_end_view, 1.0 / 3.0));
							vec3 light_tap_b = get_world_pos_at_view_depth(mix(sub_slice_start_view, sub_slice_end_view, 2.0 / 3.0));
							scattering_light += 0.5 * (
								get_additional_volumetric_light(ray_dir, light_tap_a) +
								get_additional_volumetric_light(ray_dir, light_tap_b)
							);
						}

						float segment_weight = total_transmittance * segment_scatter_amount;
						total_scattering += scattering_light * segment_weight;
						total_transmittance *= segment_transmittance;
					}
				}

				set_color(vec4(total_scattering, total_transmittance));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "scene_fog",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					set_index = 2,
					args = light_occlusion.GetOcclusionDescriptor,
				},
			},
			custom_declarations = light_occlusion.GetDeclarationGLSL(0, 2),
			uniform_buffers = {
				{
					name = "fog_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{"source_tex", "int"},
						{"ocean_distance_tex", "int"},
						unpack(build_scene_light_block_fields()),
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						render3d.WriteGBufferBlock(self, block)
						get_raw_scene_source_texture(self, block, "source_tex")
						write_ocean_distance_texture(self, block, "ocean_distance_tex")
						return write_fog_common_block(self, block)
					end,
				},
			},
			shader = (
					"const int FOG_DEBUG_MODE = %d;\n"
				):format(FOG_DEBUG_MODE) .. light_occlusion.GetSamplingGLSL("fog_data") .. [[
			]] .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("fog_data") .. atmosphere.GetGLSLDefines("fog_data", "get_current_primary_sun_intensity()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetSurfaceDirectionalShadowGLSL("fog_data", "get_fog_sun_visibility") .. [[


			]] .. screen_reconstruct.GetWorldPosGLSL("fog_data") .. [[
			]] .. screen_reconstruct.GetWorldRayGLSL("fog_data") .. [[

			vec3 get_normal() {
				return texture(TEXTURE(fog_data.normal_tex), in_uv).xyz * 2.0 - 1.0;
			}

			bool get_fog_world_segment(vec3 ray_dir, float max_world_distance, out float fog_near_world, out float fog_length_world) {
				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_near;
				float fog_length;
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float max_fog_distance = max_world_distance > 0.0 ? max_world_distance * fog_distance_scale : -1.0;

				if (!get_scenery_fog_segment_with_ground_clip(fog_ray_origin, ray_dir, max_fog_distance, false, fog_near, fog_length)) {
					return false;
				}

				fog_near_world = fog_near / fog_distance_scale;
				fog_length_world = fog_length / fog_distance_scale;
				return true;
			}

			bool get_atmosphere_world_segment(vec3 ray_dir, float max_world_distance, out float segment_near_world, out float segment_length_world) {
				vec3 ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				vec2 atmosphere_hit = ray_sphere_intersect(ray_origin, ray_dir, ATMOSPHERE_RADIUS);

				if (atmosphere_hit.y <= 0.0) {
					return false;
				}

				segment_near_world = max(atmosphere_hit.x, 0.0) / fog_distance_scale;
				float segment_far_world = atmosphere_hit.y / fog_distance_scale;

				if (max_world_distance > 0.0) {
					segment_far_world = min(segment_far_world, max_world_distance);
				}

				segment_length_world = segment_far_world - segment_near_world;
				return segment_length_world > 1e-5;
			}

			float get_medium_density(vec3 sample_point) {
				return scenery_fog_density(sample_point);
			}

			float get_medium_extinction(vec3 sample_point) {
				return scenery_fog_density(sample_point) * SCENERY_FOG_EXTINCTION;
			}

			float get_sky_medium_sun_visibility(vec3 ray_dir, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				float segment_near_world;
				float segment_length_world;
				if (!get_atmosphere_world_segment(ray_dir, max_world_distance, segment_near_world, segment_length_world)) {
					return 1.0;
				}

				const int MEDIUM_VISIBILITY_STEPS = 8;
				float step_size = segment_length_world / float(MEDIUM_VISIBILITY_STEPS);
				float weighted_distance = 0.0;
				float total_weight = 0.0;
				vec3 ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;

				for (int i = 0; i < MEDIUM_VISIBILITY_STEPS; i++) {
					float world_t = segment_near_world + (float(i) + 0.5) * step_size;
					vec3 sample_point = ray_origin + ray_dir * (world_t * fog_distance_scale);
					float weight = max(get_medium_density(sample_point), 1e-4);
					weighted_distance += world_t * weight;
					total_weight += weight;
				}

				float representative_world_t = total_weight > 0.0
					? weighted_distance / total_weight
					: segment_near_world + segment_length_world * 0.5;
				vec3 representative_world_pos = fog_data.camera_position.xyz + ray_dir * representative_world_t;
				return get_fog_sun_visibility(representative_world_pos, vec3(0.0), sun_dir);
			}

			float get_sky_medium_transmittance(vec3 ray_dir, float max_world_distance) {
				float segment_near_world;
				float segment_length_world;
				if (!get_atmosphere_world_segment(ray_dir, max_world_distance, segment_near_world, segment_length_world)) {
					return 1.0;
				}

				vec3 ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float step_size = segment_length_world / float(AERIAL_PERSPECTIVE_STEPS);
				float medium_od = 0.0;

				for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
					float world_t = segment_near_world + (float(i) + 0.5) * step_size;
					vec3 sample_point = ray_origin + ray_dir * (world_t * fog_distance_scale);
					medium_od += get_medium_extinction(sample_point) * (step_size * fog_distance_scale);
				}

				return exp(-medium_od);
			}

			float get_fog_ray_sun_visibility(vec3 ray_dir, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				float fog_near_world;
				float fog_length_world;
				if (!get_fog_world_segment(ray_dir, max_world_distance, fog_near_world, fog_length_world)) {
					return 1.0;
				}

				const int FOG_VISIBILITY_STEPS = 8;
				float step_size = fog_length_world / float(FOG_VISIBILITY_STEPS);
				float weighted_distance = 0.0;
				float total_weight = 0.0;
				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;

				for (int i = 0; i < FOG_VISIBILITY_STEPS; i++) {
					float sample_u = (float(i) + 0.5) / float(FOG_VISIBILITY_STEPS);
					float world_t = fog_near_world + (float(i) + 0.5) * step_size;
					vec3 fog_sample = fog_ray_origin + ray_dir * (world_t * fog_distance_scale);
					float front_bias = mix(1.0, 0.35, sample_u);
					float weight = max(scenery_fog_density(fog_sample) * front_bias, 1e-4);
					weighted_distance += world_t * weight;
					total_weight += weight;
				}

				float representative_world_t = total_weight > 0.0
					? weighted_distance / total_weight
					: fog_near_world + fog_length_world * 0.35;
				vec3 representative_world_pos = fog_data.camera_position.xyz + ray_dir * representative_world_t;
				return get_fog_sun_visibility(representative_world_pos, vec3(0.0), sun_dir);
			}

			float get_fog_transmittance(vec3 ray_dir, float max_world_distance) {
				float fog_near_world;
				float fog_length_world;

				if (!get_fog_world_segment(ray_dir, max_world_distance, fog_near_world, fog_length_world)) {
					return 1.0;
				}

				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float step_size = fog_length_world / float(AERIAL_PERSPECTIVE_STEPS);
				float scenery_fog_od = 0.0;

				for (int i = 0; i < AERIAL_PERSPECTIVE_STEPS; i++) {
					float world_t = fog_near_world + (float(i) + 0.5) * step_size;
					vec3 sample_point = fog_ray_origin + ray_dir * (world_t * fog_distance_scale);
					scenery_fog_od += scenery_fog_density(sample_point) * (step_size * fog_distance_scale);
				}

				return exp(-scenery_fog_od * SCENERY_FOG_EXTINCTION);
			}

		]] .. scene_lights.GetPointShadowGLSL("fog_data") .. directional_shadows.GetLocalDirectionalShadowGLSL("fog_data") .. [[

			vec3 get_additional_scene_fog_light(vec3 ray_dir, vec3 world_pos, vec3 normal) {
				vec3 fog_light = vec3(0.0);

				for (int i = 0; i < fog_data.light_count; i++) {
					lights_t light = fog_data.lights[i];
					int type = get_light_type(light);
					if (type == 0) continue;

					vec3 light_color = light.color.rgb * light.color.a;
					vec3 L = vec3(0.0);
					float attenuation = 1.0;

					if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation)) {
						continue;
					}

					if (attenuation <= 0.0001) continue;

					float shadow_factor = 1.0;

					if (type == 1) {
						int point_shadow_slot = getPointShadowSlot(i);
						if (point_shadow_slot >= 0) {
							shadow_factor = calculatePointShadow(point_shadow_slot, world_pos, normal, L);
						}
					} else if (
						type == 2 &&
						i == fog_data.shadows.local_directional_shadow_light_index &&
						fog_data.shadows.local_directional_shadow_map_index >= 0
					) {
						shadow_factor = calculateLocalDirectionalShadow(world_pos, normal, L);
					}

					float occlusion_factor = light_oct_shadow_factor(fog_data.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);

					if (occlusion_factor <= 0.0) continue;

					float NoL = max(dot(normal, L), 0.0);
					float view_alignment = clamp(dot(ray_dir, L) * 0.5 + 0.5, 0.0, 1.0);
					float phase = type == 2
						? 0.22 + 0.32 * pow(view_alignment, 2.0)
						: 0.15 + 0.35 * pow(view_alignment, 4.0);
					fog_light += light_color * attenuation * shadow_factor * occlusion_factor * max(NoL * 0.5 + phase, 0.0) * 0.25;
				}

				return fog_light;
			}

			void main() {
				if (fog_data.source_tex == -1) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				float ocean_distance = -1.0;
				vec3 ray_dir = get_world_ray();

				if (fog_data.ocean_distance_tex != -1) {
					ocean_distance = texture(TEXTURE(fog_data.ocean_distance_tex), in_uv).r;
				}

				bool is_sky = depth == 1.0 && ocean_distance <= 0.0;

				vec3 world_pos = ocean_distance > 0.0
					? fog_data.camera_position.xyz + ray_dir * ocean_distance
					: get_world_pos(depth);
				vec3 sun_dir = get_current_primary_sun_direction();

				vec3 color = scene.rgb;
				float max_world_distance = ocean_distance > 0.0
					? ocean_distance
					: length(world_pos - fog_data.camera_position.xyz);
				float fog_transmittance = is_sky ? get_sky_medium_transmittance(ray_dir, -1.0) : get_fog_transmittance(ray_dir, max_world_distance);
				float fog_amount = 1.0 - fog_transmittance;

				if (is_sky) {
					float sun_visibility = get_sky_medium_sun_visibility(ray_dir, -1.0, sun_dir);

					color = apply_scenery_fog_ray(
						scene.rgb,
						ray_dir,
						sun_dir,
						fog_data.camera_position.xyz,
						-1.0,
						sun_visibility
					);
				} else {
					float sun_visibility = get_fog_ray_sun_visibility(ray_dir, max_world_distance, sun_dir);

					color = apply_scenery_fog(
						scene.rgb,
						world_pos,
						sun_dir,
						fog_data.camera_position.xyz,
						sun_visibility
					);

					vec3 additional_fog_light = vec3(0.0);
					if (fog_amount > 1e-4) {
						additional_fog_light = get_additional_scene_fog_light(ray_dir, world_pos, get_normal()) * fog_amount;
						color += additional_fog_light;
					}

					if (FOG_DEBUG_MODE == 2) {
						set_color(vec4(additional_fog_light, 1.0));
						return;
					}
				}

				set_color(vec4(color, fog_transmittance));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
	{
		name = "volumetric_fog",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		fragment = {
			descriptor_sets = {
				{
					type = "combined_image_sampler",
					binding_index = 0,
					set_index = 2,
					args = get_froxel_volume_descriptor,
				},
			},
			uniform_buffers = {
				{
					name = "volumetric_data",
					binding_index = 5,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{"source_tex", "int"},
						{"raw_source_tex", "int"},
						{"ocean_distance_tex", "int"},
						{"near_z", "float"},
						{"far_z", "float"},
						{"slice_count", "int"},
						{"volume_enabled", "int"},
						{"froxel_resolution", "vec2"},
					},
					write = function(self, block)
						ensure_volumetric_froxel_resources()
						render3d.WriteCameraBlock(self, block)
						render3d.WriteGBufferBlock(self, block)
						get_scene_source_texture(self, block, "source_tex")
						get_raw_scene_source_texture(self, block, "raw_source_tex")
						write_ocean_distance_texture(self, block, "ocean_distance_tex")
						block.near_z = render3d.GetRenderCamera():GetNearZ()
						block.far_z = render3d.GetRenderCamera():GetFarZ()
						block.slice_count = FROXEL_SLICE_COUNT
						block.volume_enabled = volumetric_froxels.texture and 1 or 0
						block.froxel_resolution[0] = volumetric_froxels.width
						block.froxel_resolution[1] = volumetric_froxels.height
						return block
					end,
				},
			},
			custom_declarations = [[
			layout(set = 2, binding = 0) uniform sampler2DArray froxel_volume;
			]],
			shader = (
					"const int FOG_DEBUG_MODE = %d;\n"
				):format(FOG_DEBUG_MODE) .. [[
			const float FROXEL_NEAR_BREAK = ]] .. FROXEL_NEAR_BREAK .. [[;
			const float FROXEL_NEAR_SLICE_RATIO = ]] .. FROXEL_NEAR_SLICE_RATIO .. [[;

			]] .. screen_reconstruct.GetWorldPosGLSL("volumetric_data") .. [[
			]] .. screen_reconstruct.GetWorldRayGLSL("volumetric_data") .. [[

			float get_layer_index(float view_depth) {
				float near_z = max(volumetric_data.near_z, 0.001);
				float far_z = max(volumetric_data.far_z, near_z + 0.001);
				float clamped_distance = clamp(view_depth, near_z, far_z);
				float break_distance = max(min(FROXEL_NEAR_BREAK, far_z * 0.5), near_z * 1.01);
				float slice_u;
				float slice_offset;
				float slice_scale;
				if (clamped_distance <= break_distance) {
					slice_u = log(clamped_distance / near_z) / log(break_distance / near_z);
					slice_offset = 0.0;
					slice_scale = FROXEL_NEAR_SLICE_RATIO;
				} else {
					slice_u = log(clamped_distance / break_distance) / log(far_z / break_distance);
					slice_offset = FROXEL_NEAR_SLICE_RATIO;
					slice_scale = 1.0 - FROXEL_NEAR_SLICE_RATIO;
				}
				return (slice_offset + slice_u * slice_scale) * float(volumetric_data.slice_count);
			}

			vec3 hsv2rgb(vec3 c) {
				vec4 rgba = vec4(c.xyz, 1.0);
				vec3 rgb = clamp(abs(mod(rgba.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
				return rgba.z + rgba.y * (rgb - 0.5) * (1.0 - abs(2.0 * rgba.z - 1.0));
			}

			void main() {
				if (volumetric_data.source_tex == -1) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec4 scene = texture(TEXTURE(volumetric_data.source_tex), in_uv);

				if (volumetric_data.raw_source_tex == -1 || volumetric_data.volume_enabled == 0) {
					set_color(scene);
					return;
				}

				vec4 raw_scene = texture(TEXTURE(volumetric_data.raw_source_tex), in_uv);
				float depth = texture(TEXTURE(volumetric_data.depth_tex), in_uv).r;
				float ocean_distance = -1.0;

				if (volumetric_data.ocean_distance_tex != -1) {
					ocean_distance = texture(TEXTURE(volumetric_data.ocean_distance_tex), in_uv).r;
				}

				vec3 ray_dir = get_world_ray();
				float ray_view_depth_scale = max(-normalize(mat3(volumetric_data.view) * ray_dir).z, 1e-4);
				float view_depth;
				if (ocean_distance > 0.0) {
					view_depth = ocean_distance * ray_view_depth_scale;
				} else if (depth == 1.0) {
					view_depth = volumetric_data.far_z;
				} else {
					view_depth = -(volumetric_data.view * vec4(get_world_pos(depth), 1.0)).z;
				}

				float layer = get_layer_index(view_depth);
				bool at_far = layer >= float(volumetric_data.slice_count) - 1e-4;
				float base_layer = at_far ? float(volumetric_data.slice_count - 1) : floor(layer);
				float layer_frac = at_far ? 1.0 : layer - base_layer;
				bool is_sky = depth == 1.0 && ocean_distance <= 0.0;

				vec4 froxel_volume0 = base_layer > 0.5
					? texture(froxel_volume, vec3(in_uv, base_layer - 1.0))
					: vec4(0.0);
				vec4 froxel_volume1 = texture(froxel_volume, vec3(in_uv, base_layer));
				vec4 froxel_volume_sample = mix(froxel_volume0, froxel_volume1, layer_frac);
				vec3 froxel_scattering = froxel_volume_sample.rgb;
				float froxel_transmittance = clamp(froxel_volume_sample.a, 0.0, 1.0);
				float effective_transmittance = is_sky ? 1.0 : froxel_transmittance;

				if (FOG_DEBUG_MODE == 1 || FOG_DEBUG_MODE == 4 || FOG_DEBUG_MODE == 5) {
					set_color(vec4(froxel_scattering, 1.0));
					return;
				}
				bool has_scene_fog_source = volumetric_data.source_tex != volumetric_data.raw_source_tex;
				float scene_fog_transmittance = has_scene_fog_source ? clamp(scene.a, 0.0, 1.0) : 1.0;
				vec3 scene_fog_scattering = has_scene_fog_source
					? max(scene.rgb - raw_scene.rgb * scene_fog_transmittance, vec3(0.0))
					: vec3(0.0);
				vec3 color = raw_scene.rgb * (scene_fog_transmittance * effective_transmittance) + scene_fog_scattering + froxel_scattering;

				if (FOG_DEBUG_MODE == 3) {
					vec3 slice_band = hsv2rgb(vec3(base_layer / max(float(volumetric_data.slice_count), 1.0), 0.7, 1.0));
					float slice_boundary = 1.0 - smoothstep(0.0, 0.06, layer_frac);
					vec2 fuv = in_uv * max(volumetric_data.froxel_resolution, vec2(1.0));
					vec2 grid = abs(fract(fuv - 0.5) - 0.5) / max(fuv, vec2(1.0));
					float grid_line = 1.0 - clamp(min(grid.x, grid.y) * 12.0, 0.0, 1.0);
					set_color(
						vec4(mix(color, slice_band, 0.55) + vec3(grid_line * 0.3 + slice_boundary * 0.5), raw_scene.a)
					);
					return;
				}

				set_color(vec4(color, raw_scene.a));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
return r
