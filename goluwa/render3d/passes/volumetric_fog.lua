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
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local clouds = import("goluwa/render3d/clouds.lua")
-- where the air has thinned to a few thousandths of its density at the ground, past it a sky ray has nothing left to scatter
local AIR_END_ALTITUDE = 50
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
local BINDING_TILE_DEPTH = 9
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local froxels = froxel_fog.froxels
local FROXEL_SLICES = froxel_fog.SLICES
local SLICE_GLSL = froxel_fog.SLICE_GLSL
local HIDDEN_GLSL = [[
	bool froxel_is_hidden(ivec3 id, float tile_depth_max) {
		return froxel_slice_depth(float(id.z) - 2.0) > tile_depth_max * 1.1;
	}
]]

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

local depth_pass = {
	name = "volumetric_froxel_depth",
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
				return froxels.depth
			end,
		},
	},
	uniform_buffers = {
		{
			name = "froxel_data",
			binding_index = BINDING_FROXEL,
			block = {
				render3d.camera_block,
				gbuffer_layout.block,
				{"froxel_size", "vec2"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				return block
			end,
		},
	},
	on_pre_draw = function(self)
		froxel_fog.EnsureResources()
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, froxels.width, froxels.height, 1, desc, self.dynamic_offsets)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, r32f) uniform writeonly image2D out_depth;
	]],
	shader = compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("froxel_data") .. [[
		// the farthest view depth over the froxel's tile and a margin around it, which the
		// froxel's jittered samples and the filtering between froxels reach into
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, ivec2(froxel_data.froxel_size)))) return;

			ivec2 size = textureSize(TEXTURE(froxel_data.depth_tex), 0);
			vec2 tile_size = vec2(size) / froxel_data.froxel_size;
			ivec2 margin = ivec2(ceil(tile_size));
			ivec2 first = ivec2(floor(vec2(id) * tile_size)) - margin;
			ivec2 last = ivec2(ceil(vec2(id + 1) * tile_size)) + margin;
			float farthest = 0.0;

			for (int y = first.y; y < last.y; y++) {
				for (int x = first.x; x < last.x; x++) {
					farthest = max(farthest, gbuffer_depth(clamp(ivec2(x, y), ivec2(0), size - 1)));
				}
			}

			float view_depth = 1e30;

			if (farthest < 1.0) {
				mat4 inv_projection = froxel_data.inv_projection;
				view_depth = -(inv_projection[2][2] * farthest + inv_projection[3][2]) / (inv_projection[2][3] * farthest + inv_projection[3][3]);
			}

			imageStore(out_depth, id, vec4(view_depth));
		}
	]],
}
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
		{
			binding_index = BINDING_TILE_DEPTH,
			get_descriptor = function()
				return {froxels.depth:GetView(), froxels.depth_sampler}
			end,
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
		layout(set = 0, binding = ]] .. BINDING_TILE_DEPTH .. [[) uniform sampler2D tile_depth;
	]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID),
	shader = glsl_common.GetHashGLSL() .. [[
		#define saturate(x) clamp(x, 0.0, 1.0)
	]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL() .. light_occlusion.GetSamplingGLSL("froxel_data") .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. SLICE_GLSL .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		uint froxel_hash(uvec3 v) {
			uvec3 h = pcg3d(v);
			return h.x ^ h.y ^ h.z;
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
				// a soft core in the air for lights with a glow radius, so they glow instead of showing a hot spot
				float core_falloff = get_light_falloff(light, length(light.position.xyz - world_pos));
				attenuation *= core_falloff / max(core_falloff + light.falloff.w * light.falloff.w, 0.0001);
				float shadow = 1.0;

				if (type == 1) {
					int point_shadow_slot = getPointShadowSlot(i);

					if (point_shadow_slot >= 0) shadow = calculatePointShadow(point_shadow_slot, world_pos, L, L);
				} else if (type == 2 && i == froxel_data.shadows.local_directional_shadow_light_index) {
					shadow = calculateLocalDirectionalMediumShadow(world_pos, L);
				}

				result += light.color.rgb * light.color.a * attenuation * shadow * occlusion * henyey_greenstein_phase(dot(ray_dir, L), GROUND_FOG_MIE_G);
			}
			}

			return result;
		}

		// radiance of the light around P averaged over all directions. open_sky is how much of the air there is open to the
		// sky (1 outdoors, 0 under a roof), probe_ambient the same light from the probes alone
		vec3 get_ambient(vec3 P, vec2 uv, vec3 ray_origin, uint seed, out float open_sky, out vec3 probe_ambient) {
			vec3 sky = get_ground_fog_sky_ambient(ray_origin);
			open_sky = 1.0;
			probe_ambient = sky;

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
				vec4 gi = ddgi_sample_irradiance(P, N, N, vec3(0.0), false, DDGI_VISIBILITY_MIN_WEIGHT, weight);

				if (weight > 0.0) {
					// under open sky the analytic sky, validated against a path tracer, is the light: the probes' sky
					// lags a moving sun and steps with the environment probe and the cascades' update intervals,
					// and the air of a whole frame followed it (the haze flickered). Where the point can not see the sky
					// (a room, a roof) the probes' light is what is there. The overhead sky visibility tells which
					float up_weight;
					vec4 up = ddgi_sample_irradiance(P, vec3(0.0, 1.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(0.0), false, DDGI_VISIBILITY_MIN_WEIGHT, up_weight);
					open_sky = up_weight > 0.0 ? saturate(up.a) : 0.0;
					probe_ambient = gi.rgb / PI;
					return mix(probe_ambient, sky, open_sky);
				}
			}

			if (froxel_data.gi_screen_tex < 0) return sky;

			// no probes here: the light at the surface behind stands in for it
			vec4 gi = texture(TEXTURE(froxel_data.gi_screen_tex), uv);
			open_sky = saturate(gi.a);
			probe_ambient = gi.rgb / PI;
			return mix(probe_ambient, sky, open_sky);
		}

		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);

			if (any(greaterThanEqual(id.xy, ivec2(froxel_data.froxel_size)))) return;

			if (ATMOSPHERE_ENABLED == 0 || froxel_is_hidden(id, texelFetch(tile_depth, id.xy, 0).r)) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

			uint seed = froxel_hash(uvec3(id.xy, uint(id.z) + uint(froxel_data.frame) * 128u));
			vec3 jitter = vec3(uvec3(seed, seed >> 10u, seed >> 20u) & 1023u) / 1023.0 - 0.5;
			vec2 uv;
			float slice_depth = froxel_slice_depth(float(id.z) + 0.5 + jitter.z);
			float depth = froxel_point(id, (vec2(id.xy) + 0.5 + jitter.xy) / froxel_data.froxel_size, slice_depth, uv);
			vec3 view_dir = get_view_dir(uv);
			vec3 world_pos = (froxel_data.inv_view * vec4(view_dir * depth, 1.0)).xyz;
			// a froxel behind a surface is lit at the surface, but its air is the air along the ray
			// at the slice (the higher of the two), or a leaf against the sky fills the column behind it with ground level fog
			vec3 air_pos = (froxel_data.inv_view * vec4(view_dir * slice_depth, 1.0)).xyz;
			if (air_pos.y < world_pos.y) air_pos = world_pos;
			// not from world_pos, which can land on the camera
			vec3 ray_dir = normalize(mat3(froxel_data.inv_view) * view_dir);
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 fog_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
			vec3 fog_point = get_atmosphere_camera_origin(air_pos);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			float fog_extinction = ground_fog_extinction(fog_point) * per_meter;
			// the clear air is here too, lit by the same shadowed sun and ambient, so a room or a shadow doesn't glow with
			// sky blue. Its extinction is not stored: the integration finds it per channel from the same medium
			float density_r = rayleigh_density(fog_point);
			float density_m = mie_density(fog_point);
			vec3 air_scattering = (RAYLEIGH_BETA * density_r + MIE_BETA * density_m) * per_meter;
			float mu = dot(ray_dir, sun_dir);
			float sun_visibility = get_fog_sun_visibility(world_pos, sun_dir);
			vec3 sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(fog_point, sun_dir) * get_ground_fog_sun_transmittance(fog_point, sun_dir) * sun_visibility;
			float open_sky;
			vec3 probe_ambient;
			vec3 ambient = get_ambient(world_pos, uv, fog_origin, froxel_hash(uvec3(seed, id.z, 7u)), open_sky, probe_ambient);
			vec3 scattering = get_ground_fog_in_scatter(fog_point, ray_dir, sun_dir, sun_visibility, ambient) * per_meter;
			// the air: the sun's single scattering, and the light of the sky scattering again, tabulated where the air is
			// open to the sky and from the probes where it is not
			scattering += sun * (RAYLEIGH_BETA * (density_r * rayleigh_phase(mu)) + MIE_BETA * (density_m * mie_phase(mu))) * per_meter;
			vec3 air_up = fog_point / length(fog_point);
			vec3 sky_multi = ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX == -1 ?
				ambient * air_scattering :
				sc_lookup(ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX, length(fog_point), dot(air_up, ray_dir), dot(air_up, sun_dir), mu) * ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * per_meter;
			scattering += mix(probe_ambient * air_scattering, sky_multi, open_sky);

			if (fog_extinction > 0.0) scattering += get_local_light_scattering(ray_dir, world_pos) * fog_extinction;

			// scattering per meter: the radiance alone overflows a half float
			imageStore(out_scatter, id, vec4(scattering, 0.0));
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
		{
			binding_index = BINDING_TILE_DEPTH,
			get_descriptor = function()
				return {froxels.depth:GetView(), froxels.depth_sampler}
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
		layout(set = 0, binding = ]] .. BINDING_TILE_DEPTH .. [[) uniform sampler2D tile_depth;
	]],
	shader = SLICE_GLSL .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);
			ivec3 size = ivec3(froxel_data.froxel_size, int(FROXEL_SLICES));

			if (any(greaterThanEqual(id.xy, size.xy))) return;

			if (froxel_is_hidden(id, texelFetch(tile_depth, id.xy, 0).r)) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

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
				atmosphere.GetBlockLayout(),
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				atmosphere.WriteBlock(
					self,
					block,
					render3d.GetCamera():GetPosition(),
					directional_shadows.GetPrimarySunDirection(render3d.GetLights())
				)
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
	shader = atmosphere.GetGLSLDefines("froxel_data", string.format("%.17g", atmosphere.GetSunIlluminance())) .. atmosphere.GetAerialPerspectiveGLSLCode() .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, ivec2(froxel_data.froxel_size)))) return;

			vec3 view_dir = get_view_dir((vec2(id) + 0.5) / froxel_data.froxel_size);
			// meters along the ray per meter of view depth
			float ray_scale = length(view_dir);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			vec3 scattered = vec3(0.0);
			vec3 transmittance = vec3(1.0);
			// the fog and the precipitation alone, for what the air's own transmittance already holds (the sky behind)
			float layer_transmittance = 1.0;

			for (int k = 0; k < int(FROXEL_SLICES); k++) {
				vec4 froxel = texelFetch(scatter, ivec3(id, k), 0);
				float step_length = (froxel_slice_depth(float(k + 1)) - froxel_slice_depth(float(k))) * ray_scale;
				// the medium in the middle of the slice, along the ray: the clear air per channel and the fog and the
				// precipitation, which do not depend on the channel
				vec3 mid = (froxel_data.inv_view * vec4(view_dir * froxel_slice_depth(float(k) + 0.5), 1.0)).xyz;
				vec3 point = get_atmosphere_camera_origin(mid);
				float layer_extinction = ground_fog_extinction(point) * per_meter;
				vec3 extinction = compute_view_tau(rayleigh_density(point), mie_density(point), ozone_density(point)) * per_meter + layer_extinction;

				if (ATMOSPHERE_ENABLED == 0) extinction = vec3(0.0);
				vec3 step_transmittance = exp(-extinction * step_length);
				// the light scattered within the slice, attenuated on its way out of it
				vec3 weight = mix(vec3(step_length), (1.0 - step_transmittance) / max(extinction, vec3(1e-12)), greaterThan(extinction, vec3(1e-9)));
				scattered += transmittance * froxel.rgb * weight;
				transmittance *= step_transmittance;
				layer_transmittance *= exp(-layer_extinction * step_length);
				imageStore(out_integrated, ivec3(id, k), vec4(scattered, 0.0));
				imageStore(out_integrated, ivec3(id, k + int(FROXEL_SLICES)), vec4(transmittance, layer_transmittance));
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
		shader = [[
			#define ATMOSPHERE_LOG_MARCH 1
		]] .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("fog_data") .. [[
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
		]] .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("fog_data") .. screen_reconstruct.GetViewDepthGLSL("fog_data") .. froxel_fog.GetGLSL("fog_data") .. post_source.GetPreExposureGLSL("fog_data") .. [[
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
					hit_distance = get_view_depth(in_uv, depth) * length(view_dir);
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

				vec3 color;

				if (hit_distance < 0.0 && ATMOSPHERE_ENABLED != 0) {
					// The sky. The sky pass drew what is behind the air, the sun, the moon and the stars already attenuated
					// by it, and the volume holds the air from the camera to FROXEL_FAR. What is left is the air past the
					// volume, marched here, but only where there is still air at its start, and the clouds in between.
					vec3 origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
					// the sky has no ground, rays below the horizon see the horizon's air
					vec3 sky_dir = get_sky_lookup_dir(ray_dir, origin, sun_dir);
					float ground = get_planet_distance(sky_dir);
					float edge = min(ray_sphere_intersect(origin, sky_dir, ATMOSPHERE_RADIUS).y, ground);
					float cloud_km = min(cloud_depth * scale, edge);
					vec3 full_transmittance;
					vec3 full_scattered = get_volumetric_fog(in_uv, -1.0, full_transmittance);
					float layer_transmittance = get_fog_layer_transmittance(in_uv, -1.0);
					vec3 front_transmittance = full_transmittance;
					vec3 front_scattered = full_scattered;
					// the light the air behind the clouds scatters, as much of it as reaches the camera
					vec3 behind_scattered = vec3(0.0);
					bool air_past_volume = edge > froxel_end && length(origin + sky_dir * froxel_end) - PLANET_RADIUS < ]] .. string.format("%.1f", AIR_END_ALTITUDE) .. [[;
					fog_cloud_shadows = false;

					if (cloud_km <= froxel_end) {
						front_scattered = get_volumetric_fog(in_uv, cloud_depth, front_transmittance);
						behind_scattered = full_scattered - front_scattered;

						if (air_past_volume) {
							vec3 tail_transmittance;
							behind_scattered += full_transmittance * integrate_scattering(origin, sky_dir, froxel_end, edge, sun_dir, 32, vec2(1.0), 1.0, tail_transmittance);
						}
					} else if (air_past_volume) {
						vec3 before_transmittance;
						vec3 before = integrate_scattering(origin, sky_dir, froxel_end, cloud_km, sun_dir, 24, vec2(1.0), 1.0, before_transmittance);
						front_scattered = full_scattered + full_transmittance * before;
						front_transmittance = full_transmittance * before_transmittance;
						vec3 after_transmittance;
						behind_scattered = front_transmittance * integrate_scattering(origin, sky_dir, cloud_km, edge, sun_dir, 24, vec2(1.0), 1.0, after_transmittance);
					}

					color = front_scattered + front_transmittance * cloud.rgb + cloud.a * (behind_scattered + layer_transmittance * scene.rgb);
				} else {
					if (hit_distance >= 0.0) {
						cloud_front = cloud.rgb;
						scene.rgb *= cloud.a;
					}

					vec3 fog_transmittance;
					vec3 fog_scattered = get_volumetric_fog(in_uv, hit_distance, fog_transmittance);
					color = scene.rgb * fog_transmittance + fog_scattered;

					if (fog_data.cloud_view_tex >= 0 && cloud.a < 1.0) {
						// the fog in front of the clouds covers them, the rest is behind them and shows
						// through as much as they let through
						vec3 front_transmittance;
						vec3 front_scattered = get_volumetric_fog(in_uv, cloud_depth, front_transmittance);
						color = front_scattered + front_transmittance * cloud_front + cloud.a * (fog_scattered - front_scattered) + fog_transmittance * scene.rgb;
					}
				}

				set_color(vec4(min(color * pre_exposure, vec3(65504.0)), scene.a));
			}
		]],
	},
	on_pre_draw = function(self, cmd, frame)
		froxel_fog.BindVolume(self, frame)
	end,
	CullMode = "none",
	DepthTest = false,
	DepthWrite = false,
}
return {depth_pass, scatter_pass, temporal_pass, integrate_pass, composite_pass}
