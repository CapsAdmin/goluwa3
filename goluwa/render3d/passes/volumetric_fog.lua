local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local CLOUD_SHAFT_DISTANCE = 60
local FROXEL_HISTORY = 0.9
local LOCAL_LIGHT_LIMIT = 8
local BINDING_OUTPUT = 0
local BINDING_DDGI = 1
local BINDING_HISTORY = 2
local BINDING_OCCLUSION = 3
local BINDING_FROXEL = 4
local BINDING_SCATTER = 5
local BINDING_RAW = 6
local BINDING_LIGHT_GRID = 7
local BINDING_SCENE = 8
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local froxels = froxel_fog.froxels
local FROXEL_SLICES = froxel_fog.SLICES
local SLICE_GLSL = froxel_fog.SLICE_GLSL

local function get_sun_helpers_glsl(data_block)
	return [[
		int get_current_primary_sun_index() {
			for (int i = 0; i < ]] .. data_block .. [[.light_count; i++) {
				if (get_light_type(]] .. data_block .. [[.lights[i]) == 0) return i;
			}

			return -1;
		}

		vec3 get_current_primary_sun_direction() {
			int sun_index = get_current_primary_sun_index();

			if (sun_index < 0) return vec3(0.0, 1.0, 0.0);

			return normalize(-]] .. data_block .. [[.lights[sun_index].direction.xyz);
		}

		float get_current_primary_sun_illuminance() {
			int sun_index = get_current_primary_sun_index();
			return sun_index < 0 ? ]] .. string.format("%.17g", atmosphere.GetSunIlluminance()) .. [[ : ]] .. data_block .. [[.lights[sun_index].color.a;
		}
	]]
end

local function write_lights_block(self, block)
	local lights = render3d.GetLights()
	scene_lights.WriteLightsBlock(block.lights, lights)
	block.light_count = math.min(#lights, scene_lights.MAX_LIGHTS)
	scene_lights.WriteShadowBlock(self, block.shadows, lights)
	atmosphere.WriteBlock(
		self,
		block,
		render3d.GetCamera():GetPosition(),
		directional_shadows.GetPrimarySunDirection(render3d.GetLights())
	)
	return lights
end

local function write_gi_screen_texture(self, block, key)
	local texture = ddgi.GetScreenTexture()
	block[key] = texture and self:GetTextureIndex(texture) or -1
end

local function write_ocean_distance_texture(self, block, key)
	if
		render3d.IsWaterEnabled() and
		render3d.IsPassEnabled("ocean") and
		render3d.pipelines.ocean.framebuffers
	then
		block[key] = self:GetTextureIndex(render3d.pipelines.ocean:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(2))
	else
		block[key] = -1
	end
end

local scatter_pass = {
	name = "volumetric_froxel_scatter",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"froxel_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {
		{
			binding_index = BINDING_OUTPUT,
			dst_stage = "compute",
			get_texture = function()
				return froxels.raw
			end,
		},
	},
	sampled_images = {
		{
			binding_index = BINDING_OCCLUSION,
			get_descriptor = light_occlusion.GetOcclusionDescriptor,
		},
	},
	uniform_buffers = {
		{
			name = "ddgi_data",
			binding_index = BINDING_DDGI,
			block = ddgi.GetProbeBlockLayout(),
			write = function(self, block)
				if render3d.IsPassEnabled("ddgi") then
					return ddgi.WriteProbeBlock(self, block)
				end

				block.ddgi_cascade_count = 0
				return block
			end,
		},
		{
			name = "froxel_data",
			binding_index = BINDING_FROXEL,
			block = {
				render3d.camera_block,
				gbuffer_layout.block,
				{"froxel_size", "vec2"},
				{"frame", "int"},
				{"gi_screen_tex", "int"},
				{"ocean_distance_tex", "int"},
				{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
				{"light_count", "int"},
				{"shadows", scene_lights.BuildShadowsBlockLayout()},
				atmosphere.GetBlockLayout(),
				unpack(light_occlusion.GetBlockLayout()),
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				block.frame = system.GetFrameNumber()
				write_gi_screen_texture(self, block, "gi_screen_tex")
				write_ocean_distance_texture(self, block, "ocean_distance_tex")
				light_occlusion.WriteOcclusionBlock(block, write_lights_block(self, block))
				return block
			end,
		},
	},
	storage_buffers = {{binding_index = BINDING_LIGHT_GRID}},
	descriptor_sets = VISIBILITY_RAYS and
		{
			{
				type = "acceleration_structure_khr",
				binding_index = BINDING_SCENE,
				stageFlags = "compute",
			},
		} or
		nil,
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()
		light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)

		if VISIBILITY_RAYS then
			self:UpdateDescriptorSet(
				"acceleration_structure_khr",
				desc,
				BINDING_SCENE,
				0,
				render3d.IsPassEnabled("ddgi") and
					ddgi.GetFrameState().tlas or
					scene_bvh.GetPlaceholderTLAS(cmd)
			)
		end
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, froxels.width, froxels.height, FROXEL_SLICES, desc, self.dynamic_offsets)
	end,
	custom_declarations = (
			VISIBILITY_RAYS and
			[[
		#extension GL_EXT_ray_query : require
		#define DDGI_VISIBILITY_RAYS
		layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT ddgi_scene;
	]] or
			""
		) .. [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_scatter;
	]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID),
	shader = [[
		#define saturate(x) clamp(x, 0.0, 1.0)
	]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL() .. light_occlusion.GetSamplingGLSL("froxel_data") .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		uint froxel_hash(uvec3 v) {
			v = v * 1664525u + 1013904223u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			v ^= v >> 16u;
			v.x += v.y * v.z;
			v.y += v.z * v.x;
			v.z += v.x * v.y;
			return v.x ^ v.y ^ v.z;
		}

		float calculateLocalDirectionalMediumShadow(vec3 world_pos, vec3 light_dir) {
			int shadow_map_idx = froxel_data.shadows.local_directional_shadow_map_index;

			if (shadow_map_idx < 0) return 1.0;

			vec3 proj_coords;

			if (!projectMediumShadowMap(froxel_data.shadows.local_directional_light_space_matrix, world_pos, proj_coords)) return 1.0;

			return sampleMediumShadowProjection(shadow_map_idx, proj_coords, 1.35);
		}

		vec3 get_local_light_scattering(vec3 ray_dir, vec3 world_pos) {
			vec3 result = vec3(0.0);
			int processed = 0;

			int light_cell = light_grid_cell(world_pos);

			for (int w = 0; w < light_grid_words(froxel_data.light_count) && processed < ]] .. LOCAL_LIGHT_LIMIT .. [[; w++) {
			uint light_bits = light_grid_word(light_cell, w, froxel_data.light_count);

			while (light_bits != 0u && processed < ]] .. LOCAL_LIGHT_LIMIT .. [[) {
				int i = w * 32 + findLSB(light_bits);
				light_bits &= light_bits - 1u;
				lights_t light = froxel_data.lights[i];
				int type = get_light_type(light);

				if (type == 0) continue;

				vec3 L;
				float attenuation;

				if (!get_light_vector_and_attenuation(light, world_pos, L, attenuation) || attenuation <= 0.0001) continue;

				float occlusion = light_oct_shadow_factor(froxel_data.bvh_oct_slot[i], light.position.xyz, light.params.x, world_pos);

				if (occlusion <= 0.0) continue;

				processed++;
				float shadow = 1.0;

				if (type == 1) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) shadow = calculatePointShadow(point_shadow_slot, world_pos, L, L);
				} else if (type == 2 && i == froxel_data.shadows.local_directional_shadow_light_index) {
					shadow = calculateLocalDirectionalMediumShadow(world_pos, L);
				}

				result += light.color.rgb * light.color.a * attenuation * shadow * occlusion * henyey_greenstein_phase(dot(ray_dir, L), SCENERY_FOG_MIE_G);
			}
			}

			return result;
		}

		// radiance of the light around P averaged over all directions
		vec3 get_ambient(vec3 P, vec2 uv, vec3 ray_origin, uint seed) {
			vec3 sky = get_scenery_fog_sky_ambient(ray_origin);

			if (ddgi_data.ddgi_cascade_count > 0) {
				// past the probes: open air far from the camera. the surface
				// behind can't stand in, a froxel several pixels wide mixes the
				// light at a near leaf with that of the mountain behind it
				if (!ddgi_in_volume(P)) return sky;

				// one random direction a frame; the history averages them
				float z = float(seed & 0xffffu) / 32768.0 - 1.0;
				float phi = float(seed >> 16u) * (6.28318530718 / 65536.0);
				vec3 N = vec3(sqrt(max(1.0 - z * z, 0.0)) * vec2(cos(phi), sin(phi)), z);
				float weight;
				vec4 gi = ddgi_sample_irradiance(P, N, N, vec3(0.0), false, weight);

				if (weight > 0.0) return gi.rgb / PI;
			}

			if (froxel_data.gi_screen_tex < 0) return sky;

			// no probes here: the light at the surface behind stands in for it
			vec4 gi = texture(TEXTURE(froxel_data.gi_screen_tex), uv);
			return mix(gi.rgb / PI, sky, saturate(gi.a));
		}

		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);

			if (any(greaterThanEqual(id.xy, ivec2(froxel_data.froxel_size)))) return;

			if (ATMOSPHERE_ENABLED == 0) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

			uint seed = froxel_hash(uvec3(id.xy, uint(id.z) + uint(froxel_data.frame) * 128u));
			vec3 jitter = vec3(uvec3(seed, seed >> 10u, seed >> 20u) & 1023u) / 1023.0 - 0.5;
			vec2 uv;
			float depth = froxel_point(id, (vec2(id.xy) + 0.5 + jitter.xy) / froxel_data.froxel_size, froxel_slice_depth(float(id.z) + 0.5 + jitter.z), uv);
			vec3 view_dir = get_view_dir(uv);
			vec3 world_pos = (froxel_data.inv_view * vec4(view_dir * depth, 1.0)).xyz;
			// not from world_pos, which can land on the camera
			vec3 ray_dir = normalize(mat3(froxel_data.inv_view) * view_dir);
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 fog_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
			vec3 fog_point = get_atmosphere_camera_origin(world_pos);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			float fog_extinction = scenery_fog_density(fog_point) * SCENERY_FOG_EXTINCTION * per_meter;
			// the clear air is here too, lit by the same shadowed sun and
			// ambient, so a room or a shadow doesn't glow with sky blue
			float density_r = rayleigh_density(fog_point);
			float density_m = mie_density(fog_point);
			vec3 air_scattering = (RAYLEIGH_BETA * density_r + vec3(MIE_BETA * density_m)) * per_meter;
			// its extinction is blue, but the volume holds one channel and
			// the difference is a fraction of a percent within FROXEL_FAR
			float air_extinction = dot(RAYLEIGH_BETA * density_r + vec3(MIE_BETA_EXT * density_m), vec3(0.2126, 0.7152, 0.0722)) * per_meter;
			float mu = dot(ray_dir, sun_dir);
			vec3 sun = ATMOSPHERE_SUN_ILLUMINANCE * sample_transmittance_lut(fog_point, sun_dir) * get_fog_sun_visibility(world_pos, sun_dir);
			vec3 ambient = get_ambient(world_pos, uv, fog_origin, froxel_hash(uvec3(seed, id.z, 7u)));
			vec3 scattering = (ambient + sun * henyey_greenstein_phase(mu, SCENERY_FOG_MIE_G)) * fog_extinction;
			scattering += ambient * air_scattering + sun * (RAYLEIGH_BETA * (density_r * rayleigh_phase(mu)) + vec3(MIE_BETA * density_m * mie_phase(mu))) * per_meter;

			if (fog_extinction > 0.0) scattering += get_local_light_scattering(ray_dir, world_pos) * fog_extinction;

			// scattering per meter: the radiance alone overflows a half float
			imageStore(out_scatter, id, vec4(scattering, fog_extinction + air_extinction));
		}
	]],
}
local temporal_pass = {
	name = "volumetric_froxel_temporal",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"froxel_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {
		{
			binding_index = BINDING_OUTPUT,
			dst_stage = "compute",
			get_texture = function()
				return froxel_fog.GetScatterTexture(froxels.current)
			end,
		},
	},
	sampled_images = {
		{
			binding_index = BINDING_RAW,
			get_descriptor = function()
				return {froxels.raw:GetView(), froxels.raw_sampler}
			end,
		},
		{
			binding_index = BINDING_HISTORY,
			get_descriptor = function()
				local texture, sampler = froxel_fog.GetScatterTexture(3 - froxels.current)
				return {texture:GetView(), sampler}
			end,
		},
	},
	uniform_buffers = {
		{
			name = "froxel_data",
			binding_index = BINDING_FROXEL,
			block = {
				render3d.camera_block,
				render3d.prev_camera_block,
				gbuffer_layout.block,
				{"froxel_size", "vec2"},
				{"ocean_distance_tex", "int"},
				{"history", "float"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				render3d.WritePreviousCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				write_ocean_distance_texture(self, block, "ocean_distance_tex")
				block.history = froxels.history_valid and
					FROXEL_HISTORY ^ (
						math.min(system.GetFrameTime(), 0.1) * 60
					)
					or
					0
				return block
			end,
		},
	},
	on_pre_draw = function(self)
		froxels.current = 3 - froxels.current
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, froxels.width, froxels.height, FROXEL_SLICES, desc, self.dynamic_offsets)
		froxels.history_valid = true
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_scatter;
		layout(set = 0, binding = ]] .. BINDING_RAW .. [[) uniform sampler3D raw_scatter;
		layout(set = 0, binding = ]] .. BINDING_HISTORY .. [[) uniform sampler3D history_scatter;
	]],
	shader = SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);
			ivec3 size = ivec3(froxel_data.froxel_size, int(FROXEL_SLICES));

			if (any(greaterThanEqual(id.xy, size.xy))) return;

			vec4 current = texelFetch(raw_scatter, id, 0);

			if (froxel_data.history <= 0.0) {
				imageStore(out_scatter, id, current);
				return;
			}

			vec4 low = current;
			vec4 high = current;

			for (int i = 0; i < 27; i++) {
				vec4 v = texelFetch(raw_scatter, clamp(id + ivec3(i % 3, (i / 3) % 3, i / 9) - 1, ivec3(0), size - 1), 0);
				low = min(low, v);
				high = max(high, v);
			}

			// the point the froxel stands for, placed like its samples: in
			// front of a wall it holds the light there, and the same world
			// point last frame may have been in view (through a doorway)
			// with very different light
			vec2 uv;
			float depth = froxel_point(id, (vec2(id.xy) + 0.5) / froxel_data.froxel_size, froxel_slice_depth(float(id.z) + 0.5), uv);
			vec3 center = (froxel_data.inv_view * vec4(get_view_dir(uv) * depth, 1.0)).xyz;
			vec4 clip = froxel_data.prev_projection * froxel_data.prev_view * vec4(center, 1.0);
			vec3 previous = vec3(clip.xy / clip.w * 0.5 + 0.5, froxel_slice_coord(clip.w) / FROXEL_SLICES);
			vec4 result = current;

			if (clip.w > 0.0 && all(greaterThanEqual(previous, vec3(0.0))) && all(lessThanEqual(previous, vec3(1.0)))) {
				result = mix(current, clamp(textureLod(history_scatter, previous, 0.0), low, high), froxel_data.history);
			}

			imageStore(out_scatter, id, result);
		}
	]],
}
local integrate_pass = {
	name = "volumetric_froxel_integrate",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"froxel_dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 8, y = 8, z = 1},
	storage_images = {
		{
			binding_index = BINDING_OUTPUT,
			dst_stage = "fragment",
			get_texture = function()
				return froxels.integrated
			end,
		},
	},
	sampled_images = {
		{
			binding_index = BINDING_SCATTER,
			get_descriptor = function()
				local texture, sampler = froxel_fog.GetScatterTexture(froxels.current)
				return {texture:GetView(), sampler}
			end,
		},
	},
	uniform_buffers = {
		{
			name = "froxel_data",
			binding_index = BINDING_FROXEL,
			block = {
				render3d.camera_block,
				{"froxel_size", "vec2"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				return block
			end,
		},
	},
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, froxels.width, froxels.height, 1, desc, self.dynamic_offsets)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_integrated;
		layout(set = 0, binding = ]] .. BINDING_SCATTER .. [[) uniform sampler3D scatter;
	]],
	shader = SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, ivec2(froxel_data.froxel_size)))) return;

			// meters along the ray per meter of view depth
			float ray_scale = length(get_view_dir((vec2(id) + 0.5) / froxel_data.froxel_size));
			vec3 scattered = vec3(0.0);
			float transmittance = 1.0;

			for (int k = 0; k < int(FROXEL_SLICES); k++) {
				vec4 froxel = texelFetch(scatter, ivec3(id, k), 0);
				float step_length = (froxel_slice_depth(float(k + 1)) - froxel_slice_depth(float(k))) * ray_scale;
				float step_transmittance = exp(-froxel.a * step_length);
				// the light scattered within the slice, attenuated on its way out of it
				scattered += transmittance * froxel.rgb * (froxel.a > 1e-9 ? (1.0 - step_transmittance) / froxel.a : step_length);
				transmittance *= step_transmittance;
				imageStore(out_integrated, ivec3(id, k), vec4(scattered, transmittance));
			}
		}
	]],
}
local composite_pass = {
	name = "volumetric_fog",
	ColorFormat = {{"r16g16b16a16_sfloat", {"color", "rgba"}}},
	fragment = {
		descriptor_sets = {
			{
				type = "combined_image_sampler",
				binding_index = 0,
				set_index = 2,
				args = froxel_fog.GetVolumeDescriptor,
			},
		},
		custom_declarations = [[
			layout(set = 2, binding = 0) uniform sampler3D froxel_volume;
		]],
		uniform_buffers = {
			{
				name = "fog_data",
				binding_index = 3,
				block = {
					render3d.camera_block,
					gbuffer_layout.block,
					{"source_tex", "int"},
					{"ocean_distance_tex", "int"},
					{"gi_screen_tex", "int"},
					{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					atmosphere.GetBlockLayout(),
					post_source.pre_exposure_block,
					{"cloud_view_tex", "int"},
					{"cloud_view_depth_tex", "int"},
					{"frame", "int"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					gbuffer_layout.WriteBlock(self, block)
					post_source.WritePreExposureBlock(self, block)
					local cloud_view, cloud_view_depth = clouds.GetViewTextures()
					block.cloud_view_tex = cloud_view and self:GetTextureIndex(cloud_view) or -1
					block.cloud_view_depth_tex = cloud_view and self:GetTextureIndex(cloud_view_depth) or -1
					block.frame = system.GetFrameNumber() % 64
					block.source_tex = self:GetTextureIndex(post_source.GetOpaqueSceneTexture())
					write_ocean_distance_texture(self, block, "ocean_distance_tex")
					write_gi_screen_texture(self, block, "gi_screen_tex")
					write_lights_block(self, block)
					return block
				end,
			},
		},
		shader = scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("fog_data") .. [[
			// the air is shadowed by the clouds where fog_cloud_shadows is on, and sampled with jitter
			float get_cloud_shadow_km(vec3 point);
			bool fog_cloud_shadows = true;
			float fog_jitter = 0.5;
			#define ATMOSPHERE_CLOUD_SHADOW(point) (fog_cloud_shadows ? get_cloud_shadow_km(point) : 1.0)
			#define ATMOSPHERE_SCATTER_JITTER fog_jitter
		]] .. atmosphere.GetGLSLDefines("fog_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. clouds.GetShadowGLSL("fog_data.shadows") .. [[
			float get_cloud_shadow_km(vec3 point) {
				return get_cloud_shadow(vec3(point.x, point.y - PLANET_RADIUS - SEA_LEVEL_EYE_HEIGHT, point.z) / (CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER));
			}

			// km from the camera along dir to the planet's surface, 1e30 when it misses
			float get_planet_distance(vec3 dir) {
				float t = ray_sphere_intersect(get_atmosphere_camera_origin(fog_data.camera_position.xyz), dir, PLANET_RADIUS).x;
				return t > 0.0 ? t : 1e30;
			}
		]] .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("fog_data") .. froxel_fog.GetGLSL("fog_data", "get_current_primary_sun_direction()") .. post_source.GetPreExposureGLSL("fog_data") .. [[
			void main() {
				// the scene is pre-exposed, the fog in front of it absolute
				float pre_exposure = get_pre_exposure();
				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				scene.rgb /= pre_exposure;
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				// where the air ends at the water, 0 with the camera in it: the water pass fogs what is past it
				float air_distance = fog_data.ocean_distance_tex != -1 ? texture(TEXTURE(fog_data.ocean_distance_tex), in_uv).g : -1.0;
				vec3 view_dir = get_view_dir(in_uv);
				float hit_distance = -1.0;

				if (air_distance >= 0.0) {
					hit_distance = air_distance;
				} else if (depth < 1.0) {
					vec4 view_pos = fog_data.inv_projection * vec4(in_uv * 2.0 - 1.0, depth, 1.0);
					hit_distance = -view_pos.z / view_pos.w * length(view_dir);
				}

				// the froxel volume holds the air up to FROXEL_FAR, lit and
				// shadowed, whatever is behind it
				float scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float froxel_end = FROXEL_FAR * length(view_dir) * scale;
				vec3 sun_dir = get_current_primary_sun_direction();
				vec3 ray_dir = normalize(mat3(fog_data.inv_view) * view_dir);
				fog_jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(fog_data.frame), vec2(0.06711056, 0.00583715))));
				// the clouds in front of what the pixel sees, premultiplied, and how far they are.
				// cloud_front is what is at the clouds, the air up to them included, and scene becomes
				// what shows through them, so the fog can be split there
				vec4 cloud = vec4(0.0, 0.0, 0.0, 1.0);
				float cloud_depth = 1e30;
				vec3 cloud_front = vec3(0.0);

				if (fog_data.cloud_view_tex >= 0) {
					cloud = textureLod(TEXTURE(fog_data.cloud_view_tex), in_uv, 0.0);
					cloud.rgb /= CLOUD_RADIANCE_SCALE;
					cloud_depth = textureLod(TEXTURE(fog_data.cloud_view_depth_tex), in_uv, 0.0).r;

					if (hit_distance >= 0.0 && hit_distance < cloud_depth) cloud = vec4(0.0, 0.0, 0.0, 1.0);
				}

				if (ATMOSPHERE_ENABLED == 0) {
					// a void, no air
				} else if (hit_distance < 0.0 && fog_data.cloud_view_tex < 0) {
					// the sky carries all of the air along its ray: take out the
					// part the volume holds so it isn't there twice
					fog_cloud_shadows = false;
					vec3 air_transmittance;
					vec3 air = integrate_scattering(get_atmosphere_camera_origin(fog_data.camera_position.xyz), ray_dir, 0.0, min(froxel_end, get_planet_distance(ray_dir)), sun_dir, 16, vec2(1.0), 1.0, air_transmittance);
					scene.rgb = max(scene.rgb - air, vec3(0.0)) / air_transmittance;
				} else if (hit_distance < 0.0) {
					// the sky with clouds: the air the volume holds, then the air up to the clouds
					// in their shadows, the clouds, and the sky behind them. the sky's air is
					// unshadowed, so the air in front of the clouds is taken out of it
					vec3 origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
					// from high up the sky's rays below the horizon end on the planet
					float ground = get_planet_distance(ray_dir);
					float near = min(froxel_end, ground);
					float far = min(clamp(cloud_depth * scale, near, ]] .. string.format("%.1f", CLOUD_SHAFT_DISTANCE) .. [[), ground);
					fog_cloud_shadows = false;
					vec3 near_transmittance;
					vec3 near_air = integrate_scattering(origin, ray_dir, 0.0, near, sun_dir, 8, vec2(1.0), 1.0, near_transmittance);
					vec3 far_transmittance;
					vec3 far_air = integrate_scattering(origin, ray_dir, near, far, sun_dir, 12, vec2(1.0), 1.0, far_transmittance);
					fog_cloud_shadows = true;
					vec3 shadowed_transmittance;
					vec3 shadowed_air = integrate_scattering(origin, ray_dir, near, far, sun_dir, 16, vec2(1.0), 1.0, shadowed_transmittance);
					vec3 behind = max(scene.rgb - near_air - near_transmittance * far_air, vec3(0.0)) / max(near_transmittance * far_transmittance, vec3(1e-4));
					cloud_front = shadowed_air + far_transmittance * cloud.rgb;
					scene.rgb = far_transmittance * cloud.a * behind;
				} else if (hit_distance * scale > froxel_end) {
					// the air beyond the volume, past the sun's shadow map
					vec3 world_pos = fog_data.camera_position.xyz + normalize(mat3(fog_data.inv_view) * view_dir) * hit_distance;
					float sun_visibility = get_fog_sun_horizon_visibility(sun_dir) <= 0.0001 ? 0.0 : 1.0;
					float sky_visibility = fog_data.gi_screen_tex < 0 ? 1.0 : clamp(texture(TEXTURE(fog_data.gi_screen_tex), in_uv).a, 0.0, 1.0);
					scene.rgb = apply_atmospheric_aerial_perspective(scene.rgb, world_pos, sun_dir, fog_data.camera_position.xyz, sun_visibility, sky_visibility, froxel_end);
				}

				if (hit_distance >= 0.0) {
					cloud_front = cloud.rgb;
					scene.rgb *= cloud.a;
				}

				vec4 fog = get_volumetric_fog(in_uv, hit_distance);
				vec3 color = scene.rgb * fog.a + fog.rgb;

				if (fog_data.cloud_view_tex >= 0 && (hit_distance < 0.0 || cloud.a < 1.0)) {
					// the fog in front of the clouds covers them, the rest is behind them and shows
					// through as much as they let through
					vec4 front = get_volumetric_fog(in_uv, cloud_depth);
					color = front.rgb + front.a * cloud_front + cloud.a * (fog.rgb - front.rgb) + fog.a * scene.rgb;
				}

				set_color(vec4(min(color * pre_exposure, vec3(65504.0)), scene.a));
			}
		]],
	},
	CullMode = "none",
	DepthTest = false,
	DepthWrite = false,
}
return {scatter_pass, temporal_pass, integrate_pass, composite_pass}
