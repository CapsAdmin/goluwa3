local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local assets = import("goluwa/assets.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local Texture = import("goluwa/render/texture.lua")
local MAX_CASCADES = directional_shadows.MAX_CASCADES
local ENABLE_VOLUMETRIC_FOG = false
local DEBUG_GOD_RAY_BOOST = 1.0
local DEBUG_GOD_RAY_SUN_FACING_BOOST = 1
local DEBUG_GOD_RAY_SHADOW_CONTRAST = 1.0
local DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE = 1.0
local FROXEL_TILE_SIZE = 16
local FROXEL_SLICE_COUNT = 32
local volumetric_froxels = {
	texture = nil,
	sample_view = nil,
	layer_views = nil,
	width = 0,
	height = 0,
	current_slice = 0,
	sampler = nil,
}
local volumetric_froxel_fallback = {
	texture = nil,
	view = nil,
	sampler = nil,
}
local write_scene_fog_shadow_block = directional_shadows.WriteFogShadowBlock

local function destroy_volumetric_froxel_resources()
	if volumetric_froxels.sample_view and volumetric_froxels.sample_view.Remove then
		volumetric_froxels.sample_view:Remove()
	end

	if volumetric_froxels.layer_views then
		for _, view in pairs(volumetric_froxels.layer_views) do
			if view and view.Remove then view:Remove() end
		end
	end

	volumetric_froxels.sample_view = nil
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
		volumetric_froxels.texture and
		volumetric_froxels.width == width and
		volumetric_froxels.height == height
	then
		return volumetric_froxels.texture
	end

	destroy_volumetric_froxel_resources()
	local texture = Texture.New{
		width = width,
		height = height,
		format = "r16g16b16a16_sfloat",
		mip_map_levels = 1,
		image = {
			array_layers = FROXEL_SLICE_COUNT,
			usage = {"color_attachment", "sampled", "transfer_src", "transfer_dst"},
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
	volumetric_froxels.sample_view = texture:GetImage():CreateView{
		view_type = "2d_array",
		base_array_layer = 0,
		layer_count = FROXEL_SLICE_COUNT,
		base_mip_level = 0,
		level_count = 1,
	}
	volumetric_froxels.layer_views = {}
	volumetric_froxels.width = width
	volumetric_froxels.height = height

	for slice = 0, FROXEL_SLICE_COUNT - 1 do
		volumetric_froxels.layer_views[slice] = texture:GetImage():CreateView{
			view_type = "2d",
			base_array_layer = slice,
			layer_count = 1,
			base_mip_level = 0,
			level_count = 1,
		}

		if volumetric_froxels.layer_views[slice].SetDebugName then
			volumetric_froxels.layer_views[slice]:SetDebugName("render3d volumetric froxels slice " .. tostring(slice))
		end
	end

	volumetric_froxels.sampler = render.CreateSampler(texture:GetSamplerConfig())
	return texture
end

local function write_ocean_distance_texture(self, block, key)
	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
		local current_idx = system.GetFrameNumber() % 2 + 1
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
	else
		block[key] = -1
	end
end

local function draw_volumetric_froxel_build(self, cmd)
	if not ENABLE_VOLUMETRIC_FOG then return end

	local texture = ensure_volumetric_froxel_resources()

	if not texture then return end

	local image = texture:GetImage()
	cmd:PipelineBarrier{
		srcStage = "fragment_shader",
		dstStage = "color_attachment_output",
		imageBarriers = {
			{
				image = image,
				oldLayout = image.layout or "shader_read_only_optimal",
				newLayout = "color_attachment_optimal",
				srcAccessMask = "shader_read",
				dstAccessMask = "color_attachment_write",
				base_array_layer = 0,
				layer_count = FROXEL_SLICE_COUNT,
				base_mip_level = 0,
				level_count = 1,
			},
		},
	}

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

	cmd:PipelineBarrier{
		srcStage = "color_attachment_output",
		dstStage = "fragment_shader",
		imageBarriers = {
			{
				image = image,
				oldLayout = "color_attachment_optimal",
				newLayout = "shader_read_only_optimal",
				srcAccessMask = "color_attachment_write",
				dstAccessMask = "shader_read",
				base_array_layer = 0,
				layer_count = FROXEL_SLICE_COUNT,
				base_mip_level = 0,
				level_count = 1,
			},
		},
	}
	image.layout = "shader_read_only_optimal"
end

local get_raw_scene_source_texture = post_source.WriteRawSceneSourceTexture
local get_scene_source_texture = post_source.WriteSceneSourceTexture

local function write_atmosphere_transmittance_texture_field(self, block, key)
	block[key] = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
end

local function write_scene_fog_lights_field(self, block, key)
	scene_lights.WriteLightsBlock(block[key], render3d.GetLights())
end

local function write_scene_fog_light_count_field(self, block, key)
	block[key] = math.min(#render3d.GetLights(), scene_lights.MAX_LIGHTS)
end

local function write_scene_fog_scene_shadows_field(self, block, key)
	scene_lights.WriteShadowBlock(self, block[key], render3d.GetLights())
end

local function write_fog_shadow_block_field(self, block, key)
	write_scene_fog_shadow_block(self, block[key], render3d.GetLights())
end

local function build_scene_light_block_fields()
	return {
		{
			"lights",
			scene_lights.BuildLightsBlockLayout(),
			write_scene_fog_lights_field,
			scene_lights.MAX_LIGHTS,
		},
		{
			"light_count",
			"int",
			write_scene_fog_light_count_field,
		},
		{
			"shadows",
			scene_lights.BuildShadowsBlockLayout(),
			write_scene_fog_scene_shadows_field,
		},
		{
			"atmosphere_transmittance_texture_index",
			"int",
			write_atmosphere_transmittance_texture_field,
		},
	}
end

local function write_scene_fog_constants(self, block)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	get_raw_scene_source_texture(self, block, "source_tex")
	write_ocean_distance_texture(self, block, "ocean_distance_tex")
	block.time = system.GetElapsedTime()
	block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
	scene_lights.WriteLightsBlock(block.lights, render3d.GetLights())
	block.light_count = math.min(#render3d.GetLights(), scene_lights.MAX_LIGHTS)
	scene_lights.WriteShadowBlock(self, block.shadows, render3d.GetLights())
	block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
	return block
end

local function write_volumetric_froxel_build_constants(self, block)
	ensure_volumetric_froxel_resources()
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	write_ocean_distance_texture(self, block, "ocean_distance_tex")
	block.time = system.GetElapsedTime()
	block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
	block.near_z = render3d.camera:GetNearZ()
	block.far_z = render3d.camera:GetFarZ()
	block.froxel_resolution[0] = volumetric_froxels.width
	block.froxel_resolution[1] = volumetric_froxels.height
	block.current_slice = volumetric_froxels.current_slice or 0
	block.slice_count = FROXEL_SLICE_COUNT
	scene_lights.WriteLightsBlock(block.lights, render3d.GetLights())
	block.light_count = math.min(#render3d.GetLights(), scene_lights.MAX_LIGHTS)
	scene_lights.WriteShadowBlock(self, block.shadows, render3d.GetLights())
	block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
	return block
end

local function write_volumetric_fog_constants(self, block)
	ensure_volumetric_froxel_resources()
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	get_scene_source_texture(self, block, "source_tex")
	get_raw_scene_source_texture(self, block, "raw_source_tex")
	write_ocean_distance_texture(self, block, "ocean_distance_tex")
	block.near_z = render3d.camera:GetNearZ()
	block.far_z = render3d.camera:GetFarZ()
	block.slice_count = FROXEL_SLICE_COUNT
	block.volume_enabled = volumetric_froxels.texture and 1 or 0
	return block
end

local r = {
	{
		name = "volumetric_froxel_build",
		ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
		dont_create_framebuffers = true,
		on_draw = draw_volumetric_froxel_build,
		fragment = {
			uniform_buffers = {
				{
					name = "froxel_data",
					binding_index = 4,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{
							"ocean_distance_tex",
							"int",
							write_ocean_distance_texture,
						},
						{"time", "float"},
						{"blue_noise_tex", "int"},
						{"near_z", "float"},
						{"far_z", "float"},
						{"froxel_resolution", "vec2"},
						{"current_slice", "int"},
						{"slice_count", "int"},
						unpack(build_scene_light_block_fields()),
					},
					write = write_volumetric_froxel_build_constants,
				},
			},
			shader = [[
			const int VOLUMETRIC_FROXEL_SLICE_COUNT = ]] .. FROXEL_SLICE_COUNT .. [[;
			const int VOLUMETRIC_SLICE_INTEGRATION_STEPS = 4;
			const int VOLUMETRIC_LOCAL_LIGHT_LIMIT = 8;
			const float DEBUG_GOD_RAY_BOOST = ]] .. DEBUG_GOD_RAY_BOOST .. [[;
			const float DEBUG_GOD_RAY_SUN_FACING_BOOST = ]] .. DEBUG_GOD_RAY_SUN_FACING_BOOST .. [[;
			const float DEBUG_GOD_RAY_SHADOW_CONTRAST = ]] .. DEBUG_GOD_RAY_SHADOW_CONTRAST .. [[;
			const float DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE = ]] .. DEBUG_GOD_RAY_SCATTERING_DENSITY_SCALE .. [[;
			const float CLOUD_MEDIUM_EXTINCTION = 1.8;
			const float CLOUD_DENSITY_SCALE = 1.35;

			]] .. scene_lights.GetLightGLSLCode() .. [[

			int get_current_primary_sun_index() {
				for (int i = 0; i < froxel_data.light_count; i++) {
					if (get_light_type(froxel_data.lights[i]) == 0) {
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

				vec3 light_dir = froxel_data.lights[sun_index].direction.xyz;

				if (length(light_dir) < 1e-4) {
					return vec3(0.0, 1.0, 0.0);
				}

				return normalize(-light_dir);
			}

			float get_current_primary_sun_intensity() {
				int sun_index = get_current_primary_sun_index();
				return sun_index < 0 ? 1.0 : froxel_data.lights[sun_index].color.a;
			}

			#define ATMOSPHERE_SUN_INTENSITY get_current_primary_sun_intensity()

			]] .. atmosphere.GetAerialPerspectiveGLSLCode() .. [[
			]] .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. [[

			float get_slice_view_depth(float slice_index) {
				float near_z = max(froxel_data.near_z, 0.001);
				float far_z = max(froxel_data.far_z, near_z + 0.001);
				float u = clamp(slice_index / float(max(froxel_data.slice_count, 1)), 0.0, 1.0);
				return near_z * pow(far_z / near_z, u);
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

			bool get_fog_world_segment(vec3 ray_dir, float max_world_distance, out float fog_near_world, out float fog_length_world) {
				vec3 fog_ray_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
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

			float get_froxel_cloud_sun_visibility(vec3 world_pos, vec3 fog_sample, vec3 sun_dir) {
				vec3 camera_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
				vec3 up = normalize(camera_origin);
				float scene_visibility = get_fog_sun_visibility(world_pos, sun_dir);
				float cloud_visibility = get_cloud_shadow_visibility(camera_origin, fog_sample, up, sun_dir, froxel_data.time, froxel_data.blue_noise_tex);
				return scene_visibility * cloud_visibility;
			}

			int getPointShadowSlot(int light_index) {
				for (int i = 0; i < froxel_data.shadows.point_shadow_count; i++) {
					if (froxel_data.shadows.point_shadow_light_indices[i] == light_index) {
						return i;
					}
				}

				return -1;
			}

			float samplePointShadowProjection(int shadow_map_idx, vec3 sample_dir, float current_depth, float bias, float filter_radius_texels) {
				vec3 lookup_dir = normalize(vec3(-sample_dir.x, sample_dir.y, sample_dir.z));
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float angular_radius = filter_radius_texels / max(face_size, 1.0);
				vec3 up = abs(lookup_dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, lookup_dir));
				vec3 bitangent = cross(lookup_dir, tangent);
				float visibility = 0.0;
				const vec2 POISSON_DISK[8] = vec2[8](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893)
				);

				for (int i = 0; i < 8; i++) {
					vec2 offset = POISSON_DISK[i] * angular_radius;
					vec3 tap_dir = normalize(lookup_dir + tangent * offset.x + bitangent * offset.y);
					float stored_depth = texture(CUBEMAP(shadow_map_idx), tap_dir).r;
					visibility += current_depth - bias > stored_depth ? 0.0 : 1.0;
				}

				return visibility / 8.0;
			}

			float calculatePointMediumShadow(int shadow_slot, vec3 world_pos, vec3 light_dir_to_surface) {
				if (shadow_slot < 0 || shadow_slot >= froxel_data.shadows.point_shadow_count) return 1.0;

				int shadow_map_idx = froxel_data.shadows.point_shadow_map_indices[shadow_slot];
				if (shadow_map_idx < 0) return 1.0;

				vec3 light_pos = froxel_data.shadows.point_shadow_positions[shadow_slot].xyz;
				float far_plane = froxel_data.shadows.point_shadow_positions[shadow_slot].w;
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float texel_world_size = far_plane / max(face_size, 1.0);
				float world_bias = max(texel_world_size * 1.5, 0.02);
				vec3 offset_pos = world_pos + light_dir_to_surface * world_bias;
				vec3 light_to_sample = offset_pos - light_pos;
				float light_distance = length(light_to_sample);

				if (light_distance <= 0.0001 || light_distance >= far_plane) return 1.0;

				vec3 sample_dir = light_to_sample / light_distance;
				float current_depth = light_distance / max(far_plane, 0.0001);
				float normalized_bias = max(world_bias / max(far_plane, 0.0001), 0.0005);
				return samplePointShadowProjection(shadow_map_idx, sample_dir, current_depth, normalized_bias, 1.25);
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

					if (type == 1) {
						vec3 to_light = light.position.xyz - world_pos;
						float dist = length(to_light);
						float range = max(light.params.x, 0.0001);
						if (dist <= 0.0001 || dist >= range) continue;
						L = to_light / dist;
						attenuation = 1.0 / max(dist * dist, 0.0025);
					} else if (type == 2 || type == 3) {
						vec3 light_dir = normalize(light.direction.xyz);
						vec3 cone_axis = light_dir;
						vec3 from_light = world_pos - light.position.xyz;
						float dist = length(from_light);
						float range = max(light.params.x, 0.0001);
						if (dist <= 0.0001 || dist >= range) continue;

						if (type == 2) {
							L = normalize(-light_dir);
						} else {
							L = -from_light / dist;
						}

						float inner_cone = clamp(light.params.y, -1.0, 1.0);
						float outer_cone = clamp(light.params.z, -1.0, inner_cone);
						float cone_attenuation = smoothstep(outer_cone, inner_cone, dot(cone_axis, from_light / dist));
						attenuation = cone_attenuation / max(dist * dist, 0.0025);
					} else {
						continue;
					}

					if (attenuation <= 0.0001) continue;
					processed_local_lights++;

					float shadow_factor = 1.0;

					if (type == 1) {
						int point_shadow_slot = getPointShadowSlot(i);
						if (point_shadow_slot >= 0) {
							shadow_factor = calculatePointMediumShadow(point_shadow_slot, world_pos, L);
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
					fog_light += light_color * attenuation * shadow_factor * phase;
				}

				return fog_light;
			}

			void main() {
				vec3 ray_dir = get_world_ray();
				vec3 sun_dir = get_current_primary_sun_direction();

				float max_world_distance = length(get_world_pos_at_view_depth(froxel_data.far_z) - froxel_data.camera_position.xyz);
				vec3 fog_ray_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
				float fog_distance_scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float slice_start_view = get_slice_view_depth(float(froxel_data.current_slice));
				float slice_end_view = get_slice_view_depth(float(froxel_data.current_slice + 1));
				vec3 slice_start_world_pos = get_world_pos_at_view_depth(slice_start_view);
				vec3 slice_end_world_pos = get_world_pos_at_view_depth(slice_end_view);
				float slice_start_world = length(slice_start_world_pos - froxel_data.camera_position.xyz);
				float slice_end_world = length(slice_end_world_pos - froxel_data.camera_position.xyz);

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
						float cloud_density = get_cloud_medium_density(fog_sample, froxel_data.time, froxel_data.blue_noise_tex) * CLOUD_DENSITY_SCALE;
						float density = fog_density + cloud_density;

						if (density <= 1e-6) continue;

						float tau = (fog_density * SCENERY_FOG_EXTINCTION + cloud_density * CLOUD_MEDIUM_EXTINCTION) * step_fog;
						float segment_transmittance = exp(-tau);
						float segment_scatter_amount = 1.0 - exp(-tau * 1);
						float sun_visibility = get_froxel_cloud_sun_visibility(world_sample, fog_sample, sun_dir);
						vec3 scattering_light = get_volumetric_scattering_light(ray_dir, sun_dir, sun_visibility);
						float cloud_weight = clamp(cloud_density / max(density, 1e-5), 0.0, 1.0);
						scattering_light *= mix(1.0, 1.45, cloud_weight);
						scattering_light += get_additional_volumetric_light(ray_dir, world_sample);
						total_scattering += total_transmittance * scattering_light * segment_scatter_amount;
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
			uniform_buffers = {
				{
					name = "fog_data",
					binding_index = 3,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{
							"source_tex",
							"int",
							get_raw_scene_source_texture,
						},
						{
							"ocean_distance_tex",
							"int",
							function(self, block, key)
								if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
									local current_idx = system.GetFrameNumber() % 2 + 1
									block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(current_idx):GetAttachment(2))
								else
									block[key] = -1
								end
							end,
						},
						{"time", "float"},
						{"blue_noise_tex", "int"},
						unpack(build_scene_light_block_fields()),
					},
					write = write_scene_fog_constants,
				},
			},
			shader = [[
			]] .. scene_lights.GetLightGLSLCode() .. [[

			int get_current_primary_sun_index() {
				for (int i = 0; i < fog_data.light_count; i++) {
					if (get_light_type(fog_data.lights[i]) == 0) {
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

				vec3 light_dir = fog_data.lights[sun_index].direction.xyz;

				if (length(light_dir) < 1e-4) {
					return vec3(0.0, 1.0, 0.0);
				}

				return normalize(-light_dir);
			}

			float get_current_primary_sun_intensity() {
				int sun_index = get_current_primary_sun_index();
				return sun_index < 0 ? 1.0 : fog_data.lights[sun_index].color.a;
			}

			#define ATMOSPHERE_SUN_INTENSITY get_current_primary_sun_intensity()

			]] .. atmosphere.GetAerialPerspectiveGLSLCode() .. [[
			]] .. directional_shadows.GetSurfaceDirectionalShadowGLSL("fog_data", "get_fog_sun_visibility", {normal_expr = "normalize(normal)"}) .. [[


			]] .. screen_reconstruct.GetWorldPosGLSL("fog_data") .. [[
			]] .. screen_reconstruct.GetWorldRayGLSL("fog_data") .. [[

			vec3 get_normal() {
				return texture(TEXTURE(fog_data.normal_tex), in_uv).xyz;
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
				float fog_density = scenery_fog_density(sample_point);
				float cloud_density = get_cloud_medium_density(sample_point, fog_data.time, fog_data.blue_noise_tex) * 1.35;
				return fog_density + cloud_density;
			}

			float get_medium_extinction(vec3 sample_point) {
				float fog_density = scenery_fog_density(sample_point);
				float cloud_density = get_cloud_medium_density(sample_point, fog_data.time, fog_data.blue_noise_tex) * 1.35;
				return fog_density * SCENERY_FOG_EXTINCTION + cloud_density * 1.8;
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
				vec3 representative_sample = ray_origin + ray_dir * (representative_world_t * fog_distance_scale);
				float scene_visibility = get_fog_sun_visibility(representative_world_pos, vec3(0.0), sun_dir);
				float cloud_visibility = get_cloud_shadow_visibility(
					ray_origin,
					representative_sample,
					normalize(ray_origin),
					sun_dir,
					fog_data.time,
					fog_data.blue_noise_tex
				);
				return scene_visibility * cloud_visibility;
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
				vec3 representative_fog_sample = fog_ray_origin + ray_dir * (representative_world_t * fog_distance_scale);
				float scene_visibility = get_fog_sun_visibility(representative_world_pos, vec3(0.0), sun_dir);
				float cloud_visibility = get_cloud_shadow_visibility(
					fog_ray_origin,
					representative_fog_sample,
					normalize(fog_ray_origin),
					sun_dir,
					fog_data.time,
					-1
				);
				return scene_visibility * cloud_visibility;
			}

			float get_fog_geometry_sun_visibility(vec3 ray_dir, vec3 world_pos, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				vec3 fog_ray_origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				vec3 fog_sample = fog_ray_origin + (world_pos - fog_data.camera_position.xyz) * (CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER);
				float scene_visibility = get_fog_sun_visibility(world_pos, get_normal(), sun_dir);
				float cloud_visibility = get_cloud_shadow_visibility(
					fog_ray_origin,
					fog_sample,
					normalize(fog_ray_origin),
					sun_dir,
					fog_data.time,
					-1
				);
				return scene_visibility * cloud_visibility;
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

			int getPointShadowSlot(int light_index) {
				for (int i = 0; i < fog_data.shadows.point_shadow_count; i++) {
					if (fog_data.shadows.point_shadow_light_indices[i] == light_index) {
						return i;
					}
				}

				return -1;
			}

			float samplePointShadowProjection(int shadow_map_idx, vec3 sample_dir, float current_depth, float bias, float filter_radius_texels) {
				vec3 lookup_dir = normalize(vec3(-sample_dir.x, sample_dir.y, sample_dir.z));
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float angular_radius = filter_radius_texels / max(face_size, 1.0);
				vec3 up = abs(lookup_dir.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
				vec3 tangent = normalize(cross(up, lookup_dir));
				vec3 bitangent = cross(lookup_dir, tangent);
				float visibility = 0.0;
				const vec2 POISSON_DISK[8] = vec2[8](
					vec2(-0.326, -0.406),
					vec2(-0.840, -0.074),
					vec2(-0.696,  0.457),
					vec2(-0.203,  0.621),
					vec2( 0.962, -0.195),
					vec2( 0.473, -0.480),
					vec2( 0.519,  0.767),
					vec2( 0.185, -0.893)
				);

				for (int i = 0; i < 8; i++) {
					vec2 offset = POISSON_DISK[i] * angular_radius;
					vec3 tap_dir = normalize(lookup_dir + tangent * offset.x + bitangent * offset.y);
					float stored_depth = texture(CUBEMAP(shadow_map_idx), tap_dir).r;
					visibility += current_depth - bias > stored_depth ? 0.0 : 1.0;
				}

				return visibility / 8.0;
			}

			float calculatePointFogShadow(int shadow_slot, vec3 world_pos, vec3 normal, vec3 light_dir) {
				if (shadow_slot < 0 || shadow_slot >= fog_data.shadows.point_shadow_count) return 1.0;

				int shadow_map_idx = fog_data.shadows.point_shadow_map_indices[shadow_slot];
				if (shadow_map_idx < 0) return 1.0;

				vec3 light_pos = fog_data.shadows.point_shadow_positions[shadow_slot].xyz;
				float far_plane = fog_data.shadows.point_shadow_positions[shadow_slot].w;
				float face_size = float(textureSize(CUBEMAP(shadow_map_idx), 0).x);
				float texel_world_size = far_plane / max(face_size, 1.0);
				float normal_bias = max(texel_world_size * 2.0, 0.01);
				float bias_val = normal_bias * max(1.0 - dot(normal, light_dir), 0.2);
				vec3 offset_pos = world_pos + normal * bias_val;
				vec3 light_to_surface = offset_pos - light_pos;
				float light_distance = length(light_to_surface);

				if (light_distance <= 0.0001 || light_distance >= far_plane) return 1.0;

				vec3 sample_dir = light_to_surface / light_distance;
				float current_depth = light_distance / max(far_plane, 0.0001);
				float normalized_bias = max(bias_val / max(far_plane, 0.0001), 0.0005);
				return samplePointShadowProjection(shadow_map_idx, sample_dir, current_depth, normalized_bias, 1.25);
			}

			float calculateLocalDirectionalFogShadow(vec3 world_pos, vec3 normal, vec3 light_dir) {
				int shadow_map_idx = fog_data.shadows.local_directional_shadow_map_index;
				if (shadow_map_idx < 0) return 1.0;

				vec3 proj_coords;

				if (!projectShadowMap(
					fog_data.shadows.local_directional_light_space_matrix,
					world_pos,
					normal,
					light_dir,
					fog_data.shadows.local_directional_shadow_texel_world_size,
					proj_coords
				)) {
					return 1.0;
				}

				return sampleShadowProjection(shadow_map_idx, proj_coords, 1.35);
			}

			vec3 get_additional_scene_fog_light(vec3 ray_dir, vec3 world_pos, vec3 normal) {
				vec3 fog_light = vec3(0.0);
				float view_scatter = 0.25 + 0.75 * pow(clamp(dot(-ray_dir, normalize(ray_dir)) * 0.5 + 0.5, 0.0, 1.0), 2.0);

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
							shadow_factor = calculatePointFogShadow(point_shadow_slot, world_pos, normal, L);
						}
					} else if (
						type == 2 &&
						i == fog_data.shadows.local_directional_shadow_light_index &&
						fog_data.shadows.local_directional_shadow_map_index >= 0
					) {
						shadow_factor = calculateLocalDirectionalFogShadow(world_pos, normal, L);
					}

					float NoL = max(dot(normal, L), 0.0);
					float view_alignment = clamp(dot(ray_dir, L) * 0.5 + 0.5, 0.0, 1.0);
					float phase = type == 2
						? 0.22 + 0.32 * pow(view_alignment, 2.0)
						: 0.15 + 0.35 * pow(view_alignment, 4.0);
					fog_light += light_color * attenuation * shadow_factor * max(NoL * 0.5 + phase, 0.0) * view_scatter;
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
					float geometry_sun_visibility = get_fog_geometry_sun_visibility(ray_dir, world_pos, max_world_distance, sun_dir);
					float fog_shadow_weight = smoothstep(0.12, 0.45, fog_transmittance);
					fog_shadow_weight *= fog_shadow_weight;
					float sun_visibility = mix(1.0, geometry_sun_visibility, fog_shadow_weight);

					color = apply_scenery_fog(
						scene.rgb,
						world_pos,
						sun_dir,
						fog_data.camera_position.xyz,
						sun_visibility
					);

					if (fog_amount > 1e-4) {
						color += get_additional_scene_fog_light(ray_dir, world_pos, get_normal()) * fog_amount;
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
					args = function()
						local texture = ensure_volumetric_froxel_resources()

						if texture and volumetric_froxels.sample_view then
							return {volumetric_froxels.sample_view, volumetric_froxels.sampler}
						end

						local _, fallback_view, fallback_sampler = ensure_volumetric_froxel_fallback_resources()
						return {fallback_view, fallback_sampler}
					end,
				},
			},
			uniform_buffers = {
				{
					name = "volumetric_data",
					binding_index = 5,
					block = {
						render3d.camera_block,
						render3d.gbuffer_block,
						{
							"source_tex",
							"int",
							get_scene_source_texture,
						},
						{
							"raw_source_tex",
							"int",
							get_raw_scene_source_texture,
						},
						{
							"ocean_distance_tex",
							"int",
							write_ocean_distance_texture,
						},
						{"near_z", "float"},
						{"far_z", "float"},
						{"slice_count", "int"},
						{"volume_enabled", "int"},
					},
					write = write_volumetric_fog_constants,
				},
			},
			custom_declarations = [[
			layout(set = 2, binding = 0) uniform sampler2DArray froxel_volume;
			]],
			shader = [[

			]] .. screen_reconstruct.GetWorldPosGLSL("volumetric_data") .. [[
			]] .. screen_reconstruct.GetWorldRayGLSL("volumetric_data") .. [[

			float get_slice_view_depth(float slice_index) {
				float near_z = max(volumetric_data.near_z, 0.001);
				float far_z = max(volumetric_data.far_z, near_z + 0.001);
				float u = clamp(slice_index / float(max(volumetric_data.slice_count, 1)), 0.0, 1.0);
				return near_z * pow(far_z / near_z, u);
			}

			float get_layer_index(float view_depth) {
				float near_z = max(volumetric_data.near_z, 0.001);
				float far_z = max(volumetric_data.far_z, near_z + 0.001);
				float clamped_distance = clamp(view_depth, near_z, far_z);
				float slice_u = log(clamped_distance / near_z) / log(far_z / near_z);
				return clamp(slice_u * float(volumetric_data.slice_count - 1), 0.0, float(volumetric_data.slice_count - 1));
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
				float base_layer = floor(layer);
				float next_layer = min(base_layer + 1.0, float(volumetric_data.slice_count - 1));
				float layer_frac = layer - base_layer;
				bool is_sky = depth == 1.0 && ocean_distance <= 0.0;

				vec4 froxel_volume0 = texture(froxel_volume, vec3(in_uv, base_layer));
				vec4 froxel_volume1 = texture(froxel_volume, vec3(in_uv, next_layer));
				vec4 froxel_volume_sample = mix(froxel_volume0, froxel_volume1, layer_frac);
				vec3 froxel_scattering = froxel_volume_sample.rgb;
				float froxel_transmittance = clamp(froxel_volume_sample.a, 0.0, 1.0);
				float effective_transmittance = is_sky ? 1.0 : froxel_transmittance;
				bool has_scene_fog_source = volumetric_data.source_tex != volumetric_data.raw_source_tex;
				float scene_fog_transmittance = has_scene_fog_source ? clamp(scene.a, 0.0, 1.0) : 1.0;
				vec3 scene_fog_scattering = has_scene_fog_source
					? max(scene.rgb - raw_scene.rgb * scene_fog_transmittance, vec3(0.0))
					: vec3(0.0);
				vec3 color = raw_scene.rgb * (scene_fog_transmittance * effective_transmittance) + scene_fog_scattering + froxel_scattering;

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
