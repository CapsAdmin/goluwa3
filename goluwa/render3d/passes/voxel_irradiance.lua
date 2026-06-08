local Vec3 = import("goluwa/structs/vec3.lua")
local assets = import("goluwa/assets.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local lightprobes = import("goluwa/render3d/lightprobes.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local get_primary_sun = directional_shadows.GetPrimarySun
local get_primary_sun_direction = directional_shadows.GetPrimarySunDirection
local get_primary_sun_intensity = directional_shadows.GetPrimarySunIntensity
local MAX_VOXEL_GI_CLIPMAPS = 3
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local voxel_gi_fallback = {
	texture = nil,
	view = nil,
	sampler = nil,
}

local function get_voxel_fallback_descriptor()
	if
		voxel_gi_fallback.texture and
		voxel_gi_fallback.texture.IsValid and
		voxel_gi_fallback.texture:IsValid() and
		voxel_gi_fallback.view and
		voxel_gi_fallback.view.IsValid and
		voxel_gi_fallback.view:IsValid() and
		voxel_gi_fallback.sampler and
		voxel_gi_fallback.sampler.IsValid and
		voxel_gi_fallback.sampler:IsValid()
	then
		return voxel_gi_fallback.view, voxel_gi_fallback.sampler
	end

	voxel_gi_fallback.texture = nil
	voxel_gi_fallback.view = nil
	voxel_gi_fallback.sampler = nil
	voxel_gi_fallback.texture = Texture.New{
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
	voxel_gi_fallback.view = voxel_gi_fallback.texture:GetImage():CreateView{
		view_type = "2d_array",
		base_array_layer = 0,
		layer_count = 1,
		base_mip_level = 0,
		level_count = 1,
	}
	voxel_gi_fallback.sampler = render.CreateSampler(voxel_gi_fallback.texture:GetSamplerConfig())
	return voxel_gi_fallback.view, voxel_gi_fallback.sampler
end

local function get_voxel_axis_descriptor(clipmap_index, axis_name)
	return function()
		local voxelizer = render3d.GetSceneVoxelizer and render3d.GetSceneVoxelizer() or nil
		local target = voxelizer and
			voxelizer.GetClipmapLightingAxisTarget and
			voxelizer.GetClipmapLightingAxisTarget(clipmap_index, axis_name) or
			nil

		if
			target and
			target.sample_view and
			target.sample_view.IsValid and
			target.sample_view:IsValid() and
			target.sampler and
			target.sampler.IsValid and
			target.sampler:IsValid()
		then
			return {target.sample_view, target.sampler}
		end

		local fallback_view, fallback_sampler = get_voxel_fallback_descriptor()
		return {fallback_view, fallback_sampler}
	end
end

local function resolve_lighting_frame_index(self, frame_index)
	local descriptor_set_count = self.pipeline.descriptor_sets and #self.pipeline.descriptor_sets or 0

	if descriptor_set_count > 0 then
		return math.clamp(render.GetCurrentFrame() or frame_index or 1, 1, descriptor_set_count)
	end

	if frame_index then return frame_index end

	if self.framebuffers and #self.framebuffers > 0 then
		return system.GetFrameNumber() % #self.framebuffers + 1
	end

	return 1
end

local function update_voxel_gi_descriptors(self, frame_index)
	local voxelizer = render3d.GetSceneVoxelizer and render3d.GetSceneVoxelizer() or nil
	local descriptors = {
		{1, "x", 0},
		{1, "y", 1},
		{1, "z", 2},
		{2, "x", 3},
		{2, "y", 4},
		{2, "z", 5},
		{3, "x", 6},
		{3, "y", 7},
		{3, "z", 8},
	}
	local descriptor_set_count = self.pipeline.descriptor_sets and #self.pipeline.descriptor_sets or 0
	local target_frame_index = resolve_lighting_frame_index(self, frame_index)

	if descriptor_set_count > 0 then
		target_frame_index = math.clamp(target_frame_index, 1, descriptor_set_count)
	else
		target_frame_index = 1
	end

	for _, descriptor in ipairs(descriptors) do
		local clipmap_index = descriptor[1]
		local axis_name = descriptor[2]
		local binding_index = descriptor[3]
		local target = voxelizer and
			voxelizer.GetClipmapLightingAxisTarget and
			voxelizer.GetClipmapLightingAxisTarget(clipmap_index, axis_name) or
			nil
		local target_view
		local target_sampler

		if
			target and
			target.sample_view and
			target.sample_view.IsValid and
			target.sample_view:IsValid() and
			target.sampler and
			target.sampler.IsValid and
			target.sampler:IsValid()
		then
			target_view = target.sample_view
			target_sampler = target.sampler
		else
			target_view, target_sampler = get_voxel_fallback_descriptor()
		end

		self:UpdateDescriptorSet(
			"combined_image_sampler",
			target_frame_index,
			binding_index,
			2,
			target_view,
			target_sampler
		)
	end
end

return {
	{
		name = "voxel_irradiance",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"main", "rgba"}},
		},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = 0,
				attachment = 1,
				dst_stage = "fragment",
			},
		},
		on_pre_draw = function(self, _, frame_index, descriptor_frame_index)
			update_voxel_gi_descriptors(self, descriptor_frame_index or frame_index)
		end,
		descriptor_sets = {
			{
				type = "combined_image_sampler",
				binding_index = 0,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(1, "x"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 1,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(1, "y"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 2,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(1, "z"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 3,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(2, "x"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 4,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(2, "y"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 5,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(2, "z"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 6,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(3, "x"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 7,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(3, "y"),
			},
			{
				type = "combined_image_sampler",
				binding_index = 8,
				set_index = 2,
				update_after_bind = true,
				args = get_voxel_axis_descriptor(3, "z"),
			},
		},
		uniform_buffers = {
			{
				name = "lighting_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					{"ssao_kernel", "vec3", 64},
					{"lights", scene_lights.BuildLightsBlockLayout(), 128},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					render3d.debug_block,
					render3d.gbuffer_block,
					{"env_tex", "int"},
					{"brdf_lut_tex", "int"},
					{"blue_noise_tex", "int"},
					render3d.last_frame_block,
					render3d.common_block,
					{"primary_sun_intensity", "float"},
					{"primary_sun_color", "vec4"},
					{"primary_sun_direction", "vec4"},
					{"stars_texture_index", "int"},
					{"atmosphere_sky_view_texture_index", "int"},
					{"voxel_gi_clipmap_count", "int"},
					{"voxel_gi_strength", "float"},
					{"voxel_gi_clipmap_origins", "vec4", 3},
					{"voxel_gi_clipmap_data", "vec4", 3},
					{"atmosphere_transmittance_texture_index", "int"},
					{"ssr_tex", "int"},
					{"ssgi_filter_2_tex", "int"},
					{"ssgi_raw_tex", "int"},
					{"ssgi_filter_1_tex", "int"},
					{"ssgi_debug_mode", "int"},
					{"probe_color_textures", "int", 64},
					{"probe_depth_textures", "int", 64},
					{"probe_positions", "vec4", 64},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteDebugBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
					block.brdf_lut_tex = self:GetTextureIndex(assets.GetTexture("textures/render/brdf_lut.lua"))
					block.blue_noise_tex = self:GetTextureIndex(assets.GetTexture("textures/render/blue_noise.lua"))
					render3d.WriteLastFrameBlock(self, block)
					render3d.WriteCommonBlock(self, block)
					local primary_sun = get_primary_sun(lights)
					get_primary_sun_direction(lights):CopyToFloatPointer(block.primary_sun_direction)
					block.primary_sun_intensity = get_primary_sun_intensity(lights)
					block.primary_sun_color[0] = primary_sun and primary_sun.Color.x or 1
					block.primary_sun_color[1] = primary_sun and primary_sun.Color.y or 1
					block.primary_sun_color[2] = primary_sun and primary_sun.Color.z or 1
					block.primary_sun_color[3] = 0
					block.stars_texture_index = self:GetTextureIndex(atmosphere.GetStarsTexture())
					block.atmosphere_sky_view_texture_index = self:GetTextureIndex(
						atmosphere.GetSkyViewTexture(render3d.GetCamera():GetPosition(), get_primary_sun_direction(lights))
					)
					block.voxel_gi_clipmap_count = 0
					block.voxel_gi_strength = 0.2

					for i = 0, MAX_VOXEL_GI_CLIPMAPS - 1 do
						block.voxel_gi_clipmap_origins[i][0] = 0
						block.voxel_gi_clipmap_origins[i][1] = 0
						block.voxel_gi_clipmap_origins[i][2] = 0
						block.voxel_gi_clipmap_origins[i][3] = 0
						block.voxel_gi_clipmap_data[i][0] = 0
						block.voxel_gi_clipmap_data[i][1] = 0
						block.voxel_gi_clipmap_data[i][2] = 0
						block.voxel_gi_clipmap_data[i][3] = 0
					end

					local voxelizer = render3d.GetSceneVoxelizer and render3d.GetSceneVoxelizer() or nil

					if voxelizer and voxelizer.IsEnabled and voxelizer:IsEnabled() then
						local clipmap_count = math.min(voxelizer.clipmap_count or 0, MAX_VOXEL_GI_CLIPMAPS)

						for i = 1, clipmap_count do
							local clipmap = voxelizer.GetClipmap and voxelizer.GetClipmap(i) or nil
							local target = voxelizer.GetClipmapLightingAxisTarget and
								voxelizer.GetClipmapLightingAxisTarget(i, "x") or
								nil
							local lighting_origin = voxelizer.GetClipmapLightingOrigin and
								voxelizer.GetClipmapLightingOrigin(i) or
								nil
							local idx = i - 1

							if
								clipmap and
								lighting_origin and
								clipmap.has_valid_data == true and
								target and
								target.sample_view and
								target.sampler
							then
								block.voxel_gi_clipmap_count = i
								block.voxel_gi_clipmap_origins[idx][0] = lighting_origin.x
								block.voxel_gi_clipmap_origins[idx][1] = lighting_origin.y
								block.voxel_gi_clipmap_origins[idx][2] = lighting_origin.z
								block.voxel_gi_clipmap_origins[idx][3] = 1
								block.voxel_gi_clipmap_data[idx][0] = clipmap.voxel_size or 0
								block.voxel_gi_clipmap_data[idx][1] = clipmap.world_span or 0
								block.voxel_gi_clipmap_data[idx][2] = clipmap.resolution or 0
								block.voxel_gi_clipmap_data[idx][3] = 1
							end
						end
					end

					block.atmosphere_transmittance_texture_index = self:GetTextureIndex(atmosphere.GetTransmittanceTexture())

					if not render3d.pipelines.ssr or not render3d.pipelines.ssr.framebuffers then
						block.ssr_tex = -1
					else
						local current_idx = system.GetFrameNumber() % 2 + 1
						local current_ssr_fb = render3d.pipelines.ssr:GetFramebuffer(current_idx)
						block.ssr_tex = self:GetTextureIndex(current_ssr_fb:GetAttachment(1))
					end

					if render3d.pipelines.ssgi then
						block.ssgi_raw_tex = self:GetTextureIndex(render3d.pipelines.ssgi:GetFramebuffer(system.GetFrameNumber() % 3 + 1):GetAttachment(1))
						block.ssgi_filter_2_tex = self:GetTextureIndex(render3d.pipelines.ssgi_filter_2:GetFramebuffer(1):GetAttachment(1))
						block.ssgi_filter_1_tex = self:GetTextureIndex(render3d.pipelines.ssgi_filter_1:GetFramebuffer(1):GetAttachment(1))
						block.ssgi_debug_mode = render3d.ssgi_debug_mode or 0
					end

					return block
				end,
			},
		},
		custom_declarations = [[
            layout(set = 0, binding = 0, rgba16f) uniform writeonly image2D out_main;
			layout(set = 2, binding = 0) uniform sampler2DArray voxel_volume_x_1;
			layout(set = 2, binding = 1) uniform sampler2DArray voxel_volume_y_1;
			layout(set = 2, binding = 2) uniform sampler2DArray voxel_volume_z_1;
			layout(set = 2, binding = 3) uniform sampler2DArray voxel_volume_x_2;
			layout(set = 2, binding = 4) uniform sampler2DArray voxel_volume_y_2;
			layout(set = 2, binding = 5) uniform sampler2DArray voxel_volume_z_2;
			layout(set = 2, binding = 6) uniform sampler2DArray voxel_volume_x_3;
			layout(set = 2, binding = 7) uniform sampler2DArray voxel_volume_y_3;
			layout(set = 2, binding = 8) uniform sampler2DArray voxel_volume_z_3;
			]],
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			vec2 get_compute_uv() {
				return get_screen_uv(get_screen_pos(), imageSize(out_main));
			}

			vec2 in_uv;

			void set_voxel_gi(vec4 value) {
				imageStore(out_main, get_screen_pos(), value);
			}

			vec3 get_albedo() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).rgb;
			}

			float get_alpha() {
				return texture(TEXTURE(lighting_data.albedo_tex), in_uv).a;
			}

			float get_depth() {
				return texture(TEXTURE(lighting_data.depth_tex), in_uv).r;
			}

			vec3 get_normal() {
				return texture(TEXTURE(lighting_data.normal_tex), in_uv).xyz;
			}

			float get_metallic() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.r;
			}

			float get_roughness() {
				vec3 mra = texture(TEXTURE(lighting_data.mra_tex), in_uv).rgb;
				return mra.g;
			}

			vec3 get_emissive() {
				return texture(TEXTURE(lighting_data.emissive_tex), in_uv).rgb;
			}


			#define ATMOSPHERE_SUN_INTENSITY lighting_data.primary_sun_intensity

			]] .. atmosphere.GetGLSLCode() .. [[


			#define SSR 1
			#define PARALLAX_CORRECTION 1
			#define uv in_uv
			float hash(vec2 p) {
				p = fract(p * vec2(123.34, 456.21));
				p += dot(p, p + 45.32);
				return fract(p.x * p.y);
			}

			vec3 random_vec3(vec2 p) {
				return vec3(hash(p), hash(p + 1.0), hash(p + 2.0)) * 2.0 - 1.0;
			}

			#define saturate(x) clamp(x, 0.0, 1.0)
			]] .. ibl.GetEnvironmentGLSLCode() .. [[

			float random(vec2 co)
			{
				return fract(sin(dot(co.xy ,vec2(12.9898,78.233))) * 43758.5453);
			}
			vec3 get_noise3_world(vec3 world_pos)
			{
				float x = random(world_pos.xy);
				float y = random(world_pos.yz * x);
				float z = random(world_pos.xz * y);

				return vec3(x, y, z) * 2.0 - 1.0;
			}

			vec3 get_ssgi_indirect(vec2 uv, vec3 world_pos, vec3 N, vec3 V) {
				vec4 ssgi = texture(TEXTURE(lighting_data.ssgi_filter_2_tex), uv);
				return ssgi.rgb;
			}
			bool voxel_in_bounds(ivec3 voxel, int resolution) {
				return all(greaterThanEqual(voxel, ivec3(0))) && all(lessThan(voxel, ivec3(resolution)));
			}

			vec4 sample_voxel_axis_layer(int clipmap_index, int axis_index, ivec3 coord) {
				if (clipmap_index == 0) {
					if (axis_index == 0) return texelFetch(voxel_volume_x_1, coord, 0);
					if (axis_index == 1) return texelFetch(voxel_volume_y_1, coord, 0);
					return texelFetch(voxel_volume_z_1, coord, 0);
				}

				if (clipmap_index == 1) {
					if (axis_index == 0) return texelFetch(voxel_volume_x_2, coord, 0);
					if (axis_index == 1) return texelFetch(voxel_volume_y_2, coord, 0);
					return texelFetch(voxel_volume_z_2, coord, 0);
				}

				if (axis_index == 0) return texelFetch(voxel_volume_x_3, coord, 0);
				if (axis_index == 1) return texelFetch(voxel_volume_y_3, coord, 0);
				return texelFetch(voxel_volume_z_3, coord, 0);
			}

			vec4 sample_voxel_axes(int clipmap_index, ivec3 voxel, int resolution) {
				int max_index = resolution - 1;
				vec4 sx = sample_voxel_axis_layer(clipmap_index, 0, ivec3(max_index - voxel.z, max_index - voxel.y, voxel.x));
				vec4 sy = sample_voxel_axis_layer(clipmap_index, 1, ivec3(max_index - voxel.x, voxel.z, voxel.y));
				vec4 sz = sample_voxel_axis_layer(clipmap_index, 2, ivec3(max_index - voxel.x, max_index - voxel.y, voxel.z));
				float occupancy = max(sx.a, max(sy.a, sz.a));
				vec3 color = vec3(0.0);
				float contributors = 0.0;

				if (sx.a >= 0.5) {
					color += sx.rgb;
					contributors += 1.0;
				}

				if (sy.a >= 0.5) {
					color += sy.rgb;
					contributors += 1.0;
				}

				if (sz.a >= 0.5) {
					color += sz.rgb;
					contributors += 1.0;
				}

				if (contributors > 0.0) color /= contributors;
				return vec4(color, occupancy);
			}

			vec4 sample_voxel_gi_neighborhood(int clipmap_index, ivec3 voxel, int resolution) {
				vec3 accum = vec3(0.0);
				float total_weight = 0.0;
				float occupied_weight = 0.0;

				for (int z = -1; z <= 1; z++) {
					for (int y = -1; y <= 1; y++) {
						for (int x = -1; x <= 1; x++) {
							ivec3 coord = voxel + ivec3(x, y, z);

							if (!voxel_in_bounds(coord, resolution)) continue;

							vec4 sample_val = sample_voxel_axes(clipmap_index, coord, resolution);

							if (sample_val.a < 0.5) continue;

							float distance2 = float(x * x + y * y + z * z);
							float weight = 1.0 / (1.0 + distance2);
							accum += sample_val.rgb * weight;
							total_weight += weight;
							occupied_weight += weight;
						}
					}
				}

				if (total_weight <= 0.0) return vec4(0.0);

				return vec4(accum / total_weight, occupied_weight > 0.0 ? 1.0 : 0.0);
			}

			ivec3 world_to_voxel(vec3 world_pos, vec3 clipmap_origin, float world_span, float voxel_size) {
				vec3 min_corner = clipmap_origin - vec3(world_span * 0.5);
				vec3 local_pos = (world_pos - min_corner) / max(voxel_size, 1e-6);
				return ivec3(floor(local_pos));
			}

			vec3 voxel_to_world_center(ivec3 voxel, vec3 clipmap_origin, float world_span, float voxel_size) {
				vec3 min_corner = clipmap_origin - vec3(world_span * 0.5);
				return min_corner + (vec3(voxel) + 0.5) * voxel_size;
			}

			bool get_voxel_clipmap_params(vec3 world_pos, out int clipmap_index, out vec3 clipmap_origin, out float voxel_size, out float world_span, out int resolution) {
				for (int i = 0; i < lighting_data.voxel_gi_clipmap_count; i++) {
					vec4 origin_data = lighting_data.voxel_gi_clipmap_origins[i];
					vec4 clipmap_data = lighting_data.voxel_gi_clipmap_data[i];

					if (clipmap_data.w < 0.5) continue;

					clipmap_origin = origin_data.xyz;
					voxel_size = clipmap_data.x;
					world_span = clipmap_data.y;
					resolution = int(clipmap_data.z + 0.5);
					vec3 half_span = vec3(world_span * 0.5);

					if (
						all(greaterThanEqual(world_pos, clipmap_origin - half_span)) &&
						all(lessThan(world_pos, clipmap_origin + half_span))
					) {
						clipmap_index = i;
						return true;
					}
				}

				clipmap_index = -1;
				clipmap_origin = vec3(0.0);
				voxel_size = 0.0;
				world_span = 0.0;
				resolution = 0;
				return false;
			}

			vec3 trace_voxel_gi_direction(vec3 world_pos, vec3 N, vec3 dir) {
				float travel = 0.35;

				for (int step = 0; step < 12; step++) {
					vec3 sample_pos = world_pos + N * 0.3 + dir * travel;
					int clipmap_index;
					vec3 clipmap_origin;
					float voxel_size;
					float world_span;
					int resolution;

					if (!get_voxel_clipmap_params(sample_pos, clipmap_index, clipmap_origin, voxel_size, world_span, resolution)) {
						travel += 1.0;
						continue;
					}

					ivec3 voxel = world_to_voxel(sample_pos, clipmap_origin, world_span, voxel_size);

					if (!voxel_in_bounds(voxel, resolution)) {
						travel += max(voxel_size * 1.5, 0.5);
						continue;
					}

					vec4 voxel_sample = sample_voxel_gi_neighborhood(clipmap_index, voxel, resolution);
					if (voxel_sample.a < 0.5) {
						ivec3 surface_voxel = voxel - ivec3(sign(dir));

						if (voxel_in_bounds(surface_voxel, resolution)) {
							voxel_sample = sample_voxel_gi_neighborhood(clipmap_index, surface_voxel, resolution);
						}
					}

					if (voxel_sample.a >= 0.5) {
						float receiver_weight = max(dot(N, dir), 0.0);
						float distance_weight = 1.0 / (1.0 + travel * travel * 0.2);
						return voxel_sample.rgb * receiver_weight * distance_weight;
					}

					travel += max(voxel_size * 1.5, 0.5);
				}

				return vec3(0.0);
			}

			vec3 get_voxel_indirect_irradiance(vec3 world_pos, vec3 N) {
				if (lighting_data.voxel_gi_clipmap_count <= 0) return vec3(0.0);
				vec3 basis_up = abs(N.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
				vec3 tangent = normalize(cross(basis_up, N));
				vec3 bitangent = normalize(cross(N, tangent));
				vec3 irradiance = vec3(0.0);

				irradiance += trace_voxel_gi_direction(world_pos, N, N);
				irradiance += trace_voxel_gi_direction(world_pos, N, normalize(N + tangent * 0.4));
				irradiance += trace_voxel_gi_direction(world_pos, N, normalize(N - tangent * 0.4));
				irradiance += trace_voxel_gi_direction(world_pos, N, normalize(N + bitangent * 0.4));
				return irradiance * (0.25 * lighting_data.voxel_gi_strength);
			}

			]] .. screen_reconstruct.GetWorldPosGLSL("lighting_data") .. [[

			vec3 get_view_normal(vec3 world_pos) {
				return normalize(lighting_data.camera_position.xyz - world_pos);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_main);

				if (!is_screen_pos_in_bounds(pos, size)) return;
				in_uv = get_compute_uv();

				float depth = get_depth();

				if (depth == 1.0) {
					set_voxel_gi(vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				float alpha = get_alpha();

				if (alpha == 0.0) {
					set_voxel_gi(vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				vec3 N = get_normal();
				vec3 world_pos = get_world_pos(depth);
				vec3 voxel_irradiance = get_voxel_indirect_irradiance(world_pos, N);
				set_voxel_gi(vec4(voxel_irradiance, alpha));
			}
		]],
	},
}
