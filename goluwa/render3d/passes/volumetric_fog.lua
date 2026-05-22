local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local Texture = import("goluwa/render/texture.lua")
local MAX_CASCADES = directional_shadows.MAX_CASCADES
local FROXEL_TILE_SIZE = 8
local FROXEL_SLICE_COUNT = 64
local volumetric_froxels = {
	texture = nil,
	layer_views = nil,
	width = 0,
	height = 0,
	current_slice = 0,
	sampler = nil,
}
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local write_scene_fog_shadow_block = directional_shadows.WriteFogShadowBlock

local function destroy_volumetric_froxel_resources()
	if volumetric_froxels.layer_views then
		for _, view in pairs(volumetric_froxels.layer_views) do
			if view and view.Remove then view:Remove() end
		end
	end

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

local function ensure_volumetric_froxel_resources()
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

local function write_shared_fog_atmosphere_constants(self, block)
	block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
	get_primary_sun_direction():CopyToFloatPointer(block.primary_sun_direction)
	block.primary_sun_intensity = get_primary_sun_intensity()
	write_scene_fog_shadow_block(self, block.shadows, render3d.GetLights())
end

local function write_primary_sun_intensity_field(self, block, key)
	block[key] = get_primary_sun_intensity()
end

local function write_primary_sun_direction_field(self, block, key)
	get_primary_sun_direction():CopyToFloatPointer(block[key])
end

local function write_atmosphere_transmittance_texture_field(self, block, key)
	block[key] = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())
end

local function write_fog_shadow_block_field(self, block, key)
	write_scene_fog_shadow_block(self, block[key], render3d.GetLights())
end

local function build_shared_fog_light_block_fields()
	return {
		{
			"primary_sun_intensity",
			"float",
			write_primary_sun_intensity_field,
		},
		{
			"primary_sun_direction",
			"vec4",
			write_primary_sun_direction_field,
		},
		{
			"atmosphere_transmittance_texture_index",
			"int",
			write_atmosphere_transmittance_texture_field,
		},
		{
			"shadows",
			directional_shadows.BuildFogShadowBlockLayout(),
			write_fog_shadow_block_field,
		},
	}
end

local function write_scene_fog_constants(self, block)
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	get_raw_scene_source_texture(self, block, "source_tex")
	write_ocean_distance_texture(self, block, "ocean_distance_tex")
	write_shared_fog_atmosphere_constants(self, block)
	return block
end

local function write_volumetric_froxel_build_constants(self, block)
	ensure_volumetric_froxel_resources()
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	write_ocean_distance_texture(self, block, "ocean_distance_tex")
	block.near_z = render3d.camera:GetNearZ()
	block.far_z = render3d.camera:GetFarZ()
	block.froxel_resolution[0] = volumetric_froxels.width
	block.froxel_resolution[1] = volumetric_froxels.height
	block.current_slice = volumetric_froxels.current_slice or 0
	block.slice_count = FROXEL_SLICE_COUNT
	write_shared_fog_atmosphere_constants(self, block)
	return block
end

local function write_volumetric_fog_constants(self, block)
	ensure_volumetric_froxel_resources()
	render3d.WriteCameraBlock(self, block)
	render3d.WriteGBufferBlock(self, block)
	get_scene_source_texture(self, block, "source_tex")
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
						{"near_z", "float"},
						{"far_z", "float"},
						{"froxel_resolution", "vec2"},
						{"current_slice", "int"},
						{"slice_count", "int"},
						unpack(build_shared_fog_light_block_fields()),
					},
					write = write_volumetric_froxel_build_constants,
				},
			},
			shader = [[
			#define ATMOSPHERE_SUN_INTENSITY froxel_data.primary_sun_intensity
			const int VOLUMETRIC_FROXEL_SLICE_COUNT = ]] .. FROXEL_SLICE_COUNT .. [[;
			const int VOLUMETRIC_SLICE_INTEGRATION_STEPS = 4;

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

				if (!get_scenery_fog_segment(fog_ray_origin, ray_dir, max_fog_distance, fog_near, fog_length)) {
					return false;
				}

				fog_near_world = fog_near / fog_distance_scale;
				fog_length_world = fog_length / fog_distance_scale;
				return true;
			}

			vec3 get_volumetric_scattering_light(vec3 ray_dir, vec3 sun_dir, float sun_visibility) {
				float day_factor = smoothstep(-0.08, 0.2, sun_dir.y);
				float horizon_visibility = get_fog_sun_horizon_visibility(sun_dir);
				float forward_scatter = pow(clamp(dot(ray_dir, sun_dir) * 0.5 + 0.5, 0.0, 1.0), 16.0);
				vec3 sun_tint = mix(vec3(1.0, 0.6, 0.42), vec3(1.0, 0.97, 0.92), day_factor);
				float direct_visibility = horizon_visibility * clamp(sun_visibility, 0.0, 1.0);
				return sun_tint * (0.015 + 0.14 * forward_scatter) * direct_visibility * ATMOSPHERE_SUN_INTENSITY;
			}

			void main() {
				vec3 ray_dir = get_world_ray();
				vec3 sun_dir = froxel_data.primary_sun_direction.xyz;

				if (length(sun_dir) < 0.0001) {
					sun_dir = vec3(0.0, 1.0, 0.0);
				} else {
					sun_dir = normalize(sun_dir);
				}

				float fog_near_world;
				float fog_length_world;
				float max_world_distance = length(get_world_pos_at_view_depth(froxel_data.far_z) - froxel_data.camera_position.xyz);
				if (!get_fog_world_segment(ray_dir, max_world_distance, fog_near_world, fog_length_world)) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				float fog_far_world = fog_near_world + fog_length_world;
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
						float segment_start = max(sub_slice_start_world, fog_near_world);
						float segment_end = min(sub_slice_end_world, fog_far_world);

						if (segment_end <= segment_start) continue;

						float sample_distance = 0.5 * (segment_start + segment_end);
						float step_world = segment_end - segment_start;
						float step_fog = step_world * fog_distance_scale;
						float sample_view_depth = 0.5 * (sub_slice_start_view + sub_slice_end_view);
						vec3 world_sample = get_world_pos_at_view_depth(sample_view_depth);
						vec3 fog_sample = fog_ray_origin + ray_dir * (sample_distance * fog_distance_scale);
						float density = scenery_fog_density(fog_sample);

						if (density <= 1e-6) continue;

						float tau = density * SCENERY_FOG_EXTINCTION * step_fog;
						float segment_transmittance = exp(-tau);
						float sun_visibility = get_fog_sun_visibility(world_sample, sun_dir);
						vec3 scattering_light = get_volumetric_scattering_light(ray_dir, sun_dir, sun_visibility);
						total_scattering += total_transmittance * scattering_light * (1.0 - segment_transmittance);
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
						unpack(build_shared_fog_light_block_fields()),
					},
					write = write_scene_fog_constants,
				},
			},
			shader = [[
			#define ATMOSPHERE_SUN_INTENSITY fog_data.primary_sun_intensity

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

				if (!get_scenery_fog_segment(fog_ray_origin, ray_dir, max_fog_distance, fog_near, fog_length)) {
					return false;
				}

				fog_near_world = fog_near / fog_distance_scale;
				fog_length_world = fog_length / fog_distance_scale;
				return true;
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

			float get_fog_geometry_sun_visibility(vec3 ray_dir, vec3 world_pos, float max_world_distance, vec3 sun_dir) {
				if (get_fog_sun_horizon_visibility(sun_dir) <= 0.0001) {
					return 0.0;
				}

				return get_fog_sun_visibility(world_pos, get_normal(), sun_dir);
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
				vec3 sun_dir = fog_data.primary_sun_direction.xyz;

				if (length(sun_dir) < 0.0001) {
					sun_dir = vec3(0.0, 1.0, 0.0);
				} else {
					sun_dir = normalize(sun_dir);
				}

				vec3 color = scene.rgb;
				float max_world_distance = ocean_distance > 0.0
					? ocean_distance
					: length(world_pos - fog_data.camera_position.xyz);

				if (is_sky) {
					float sun_visibility = get_fog_ray_sun_visibility(ray_dir, -1.0, sun_dir);

					color = apply_scenery_fog_ray(
						scene.rgb,
						ray_dir,
						sun_dir,
						fog_data.camera_position.xyz,
						-1.0,
						sun_visibility
					);
				} else {
					float sun_visibility = get_fog_geometry_sun_visibility(ray_dir, world_pos, max_world_distance, sun_dir);

					color = apply_scenery_fog(
						scene.rgb,
						world_pos,
						sun_dir,
						fog_data.camera_position.xyz,
						sun_visibility
					);
				}

				set_color(vec4(color, scene.a));
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
						local texture = ensure_volumetric_froxel_resources() or Texture.GetFallback()
						local sampler = volumetric_froxels.sampler or render.CreateSampler(texture:GetSamplerConfig())
						return {texture:GetView(), sampler}
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
				if (volumetric_data.source_tex == -1 || volumetric_data.volume_enabled == 0) {
					set_color(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec4 scene = texture(TEXTURE(volumetric_data.source_tex), in_uv);
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

				vec3 froxel_scattering0 = texture(froxel_volume, vec3(in_uv, base_layer)).rgb;
				vec3 froxel_scattering1 = texture(froxel_volume, vec3(in_uv, next_layer)).rgb;
				vec3 froxel_scattering = mix(froxel_scattering0, froxel_scattering1, layer_frac);

				set_color(vec4(scene.rgb + froxel_scattering, scene.a));
			}
			]],
		},
		CullMode = "none",
		DepthTest = false,
		DepthWrite = false,
	},
}
return r
