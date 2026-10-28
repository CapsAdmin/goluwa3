local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
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
local gi = import("goluwa/render3d/gi.lua")
local froxel_fog = import("goluwa/render3d/froxel_fog.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local medium_lighting = import("goluwa/render3d/medium_lighting.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
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
local BINDING_GI = 10
local BINDING_EMITTERS = 13
local BINDING_GI_EMITTER = 14
local GI_SCENE_BINDINGS = {scene = BINDING_SCENE, hit = 30, materials = 11, light_grid = 12}
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local froxels = froxel_fog.froxels
local FROXEL_SLICES = froxel_fog.SLICES
local SLICE_GLSL = froxel_fog.SLICE_GLSL
local HIDDEN_GLSL = [[
	bool froxel_is_hidden(ivec3 id, float tile_depth_max) {
		return froxel_slice_depth(float(id.z) - 2.0) > tile_depth_max * 1.1;
	}
]]

local function write_gi_screen_texture(self, block, key)
	local texture = gi.GetScreenTexture()
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

		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, ivec2(froxel_data.froxel_size)))) return;

			ivec2 size = textureSize(TEXTURE(froxel_data.depth_tex), 0);
			vec2 tile_size = vec2(size) / froxel_data.froxel_size;
			ivec2 margin = ivec2(ceil(tile_size));
			ivec2 first = ivec2(floor(vec2(id) * tile_size)) - margin;
			ivec2 last = ivec2(ceil(vec2(id + 1) * tile_size)) + margin;
			float farthest = 1.0;

			for (int y = first.y; y < last.y; y++) {
				for (int x = first.x; x < last.x; x++) {
					farthest = min(farthest, gbuffer_depth(clamp(ivec2(x, y), ivec2(0), size - 1)));
				}
			}

			float view_depth = 1e30;

			if (farthest > 0.0) {
				mat4 inv_projection = froxel_data.inv_projection;
				view_depth = -(inv_projection[2][2] * farthest + inv_projection[3][2]) / (inv_projection[2][3] * farthest + inv_projection[3][3]);
			}

			imageStore(out_depth, id, vec4(view_depth));
		}
	]],
}
local gi_pass = {
	name = "volumetric_froxel_gi",
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
				return froxels.gi
			end,
		},
		{
			binding_index = BINDING_GI_EMITTER,
			dst_stage = "compute",
			get_texture = function()
				return froxels.gi_emitter
			end,
		},
	},
	sampled_images = {
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
			block = gi.GetProbeBlockLayout(),
			write = gi.WriteProbeBlock,
		},
		{
			name = "froxel_data",
			binding_index = BINDING_FROXEL,
			block = {
				render3d.camera_block,
				gbuffer_layout.block,
				post_source.pre_exposure_block,
				{"froxel_size", "vec2"},
				{"frame", "int"},
				{"gi_screen_tex", "int"},
				{"ocean_distance_tex", "int"},
				scene_reflection.block,
				atmosphere.GetBlockLayout(),
				{"primary_sun_illuminance", "float"},
				{"env_tex", "int"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				gbuffer_layout.WriteBlock(self, block)
				post_source.WritePreExposureBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				block.frame = system.GetFrameNumber()
				write_gi_screen_texture(self, block, "gi_screen_tex")
				write_ocean_distance_texture(self, block, "ocean_distance_tex")
				scene_reflection.WriteBlock(self, block)
				local lights = render3d.GetLights()
				atmosphere.WriteBlock(
					self,
					block,
					render3d.GetCamera():GetPosition(),
					directional_shadows.GetPrimarySunDirection(lights)
				)
				block.primary_sun_illuminance = directional_shadows.GetPrimarySunIlluminance(lights)
				block.env_tex = self:GetTextureIndex(render3d.GetEnvironmentTexture())
				return block
			end,
		},
	},
	descriptor_sets = VISIBILITY_RAYS and
		scene_reflection.GetDescriptorSets(GI_SCENE_BINDINGS, "compute") or
		nil,
	storage_buffers = VISIBILITY_RAYS and {{binding_index = BINDING_EMITTERS}} or nil,
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()

		if VISIBILITY_RAYS then
			scene_reflection.Bind(self, cmd, desc, GI_SCENE_BINDINGS)
			local emitters = scene_emitters.BuildActive(cmd)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
		end
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(
			cmd,
			froxels.gi:GetWidth(),
			froxels.gi:GetHeight(),
			FROXEL_SLICES,
			desc,
			self.dynamic_offsets
		)
	end,
	custom_declarations = (
			VISIBILITY_RAYS and
			scene_reflection.GetDeclarationGLSL(GI_SCENE_BINDINGS) .. scene_emitters.GetDeclarationGLSL(BINDING_EMITTERS)
			or
			""
		) .. [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_gi;
		layout(set = 0, binding = ]] .. BINDING_GI_EMITTER .. [[, rgba16f) uniform writeonly image3D out_gi_emitter;
		layout(set = 0, binding = ]] .. BINDING_TILE_DEPTH .. [[) uniform sampler2D tile_depth;
	]],
	shader = glsl_common.GetHashGLSL() .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. (
			VISIBILITY_RAYS and
			"#define SCENE_HIT_SKY_RAYS 1\n#define SCENE_HIT_EMISSION (ddgi_data.ddgi_emitter_count == 0)\n" .. post_source.GetPreExposureGLSL("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "froxel_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("froxel_data") .. scene_emitters.GetGLSL() .. scene_emitters.GetLightGLSL()
			or
			gi.GetCommonGLSL()
		) .. gi.GetMediumGLSL() .. SLICE_GLSL .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		uint froxel_hash(uvec3 v) {
			uvec3 h = pcg3d(v);
			return h.x ^ h.y ^ h.z;
		}

		void main() {
			ivec3 quad = ivec3(gl_GlobalInvocationID);
			ivec2 size = ivec2(froxel_data.froxel_size);

			if (any(greaterThanEqual(quad.xy * 2, size))) return;

			imageStore(out_gi_emitter, quad, vec4(0.0));

			uint start = froxel_hash(uvec3(quad.xy, uint(quad.z) + uint(froxel_data.frame) * 128u));
			ivec3 id = ivec3(-1);

			for (uint i = 0u; i < 4u; i++) {
				uint k = (start + i) & 3u;
				ivec3 candidate = ivec3(quad.xy * 2 + ivec2(k & 1u, k >> 1u), quad.z);

				if (all(lessThan(candidate.xy, size)) && !froxel_is_hidden(candidate, texelFetch(tile_depth, candidate.xy, 0).r)) {
					id = candidate;
					break;
				}
			}

			if (id.x < 0) {
				imageStore(out_gi, quad, vec4(-1.0));
				return;
			}

			uint seed = froxel_hash(uvec3(id.xy, uint(id.z) + uint(froxel_data.frame) * 128u));
			vec3 jitter = vec3(uvec3(seed, seed >> 10u, seed >> 20u) & 1023u) / 1023.0 - 0.5;
			vec2 uv = (vec2(id.xy) + 0.5 + jitter.xy) / froxel_data.froxel_size;
			bool covered;
			float depth = froxel_point(id, uv, froxel_slice_depth(float(id.z) + 0.5 + jitter.z), covered);
			vec3 P = (froxel_data.inv_view * vec4(get_view_dir(uv) * depth, 1.0)).xyz;
			if (gi_available()) {
				if (!gi_in_volume(P)) {
					imageStore(out_gi, quad, vec4(-1.0));
					return;
				}

				uint n = froxel_hash(uvec3(seed, id.z, 7u));
				float z = float(n & 0xffffu) / 32768.0 - 1.0;
				float phi = float(n >> 16u) * (6.28318530718 / 65536.0);
				vec3 dir = vec3(sqrt(max(1.0 - z * z, 0.0)) * vec2(cos(phi), sin(phi)), z);

				#ifdef SCENE_REFLECTION
				if (ddgi_data.gi_mode == GI_MODE_SURFELS) {
					if (dir.y < 0.0) dir = -dir;

					vec3 radiance = vec3(0.0);
					float open_sky = 0.0;

					for (int i = 0; i < 2; i++) {
						vec3 d = i == 0 ? dir : -dir;
						float t;
						uint instance;
						uint primitive;
						vec2 barycentrics;
						vec3 ray;

						if (trace_scene_interval(P, d, 0.0, SCENE_REFLECTION_MAX_DISTANCE, t, instance, primitive, barycentrics)) {
							ray = shade_scene_reflection_hit(P, d, 1.0, t, instance, primitive, barycentrics);
						} else {
							t = SCENE_REFLECTION_MAX_DISTANCE;
							ray = ddgi_sky(d);

							if (i == 0) open_sky = 1.0;
						}

						if (froxel_data.glass_light != 0) ray *= get_glass_light(P, d, t, 0.0);

						radiance += 0.5 * ray;
					}

					int emitter_count = ddgi_data.ddgi_emitter_count;
					vec3 glow = vec3(0.0);

					if (emitter_count > 0) {
						vec3 to_light;
						float dist;
						vec3 light = emitter_sample_light(froxel_hash(uvec3(quad)), uint(froxel_data.frame), emitter_count, P, vec3(0.0), 0.1 + depth * 0.01, to_light, dist);

						if (dot(light, vec3(1.0)) > 0.0 && (dist <= 0.02 || scene_reflection_visible(P, to_light, dist - 0.02))) {
							if (froxel_data.glass_light != 0) light *= get_glass_light(P, to_light, dist, 0.0);

							glow = min(light / (4.0 * PI), vec3(60000.0));
						}
					}

					radiance = dot(radiance, vec3(1.0)) >= 0.0 ? min(radiance, vec3(60000.0)) : vec3(0.0);
					imageStore(out_gi, quad, vec4(radiance / PI, open_sky));
					imageStore(out_gi_emitter, quad, vec4(glow / PI, 0.0));
					return;
				}
				#endif

				float weight;
				vec4 gi = gi_sample_medium(P, dir, weight);

				if (weight > 0.0) {
					imageStore(out_gi, quad, vec4(gi.rgb / PI, saturate(gi.a)));
					return;
				}
			}

			if (froxel_data.gi_screen_tex < 0) {
				imageStore(out_gi, quad, vec4(-1.0));
				return;
			}

			vec4 gi = texture(TEXTURE(froxel_data.gi_screen_tex), uv);
			imageStore(out_gi, quad, vec4(gi.rgb / PI, saturate(gi.a)));
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
		{
			binding_index = BINDING_GI,
			get_descriptor = function()
				return {froxels.gi:GetView(), froxels.gi_sampler}
			end,
		},
		{
			binding_index = BINDING_GI_EMITTER,
			get_descriptor = function()
				return {froxels.gi_emitter:GetView(), froxels.gi_emitter_sampler}
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
				{"frame", "int"},
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
				write_ocean_distance_texture(self, block, "ocean_distance_tex")
				light_occlusion.WriteOcclusionBlock(block, medium_lighting.WriteLightsBlock(self, block))
				return block
			end,
		},
	},
	storage_buffers = {{binding_index = BINDING_LIGHT_GRID}},
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()
		light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
	end,
	on_draw = function(self, cmd, fb, frame, desc)
		self:UploadConstants()
		self.pipeline:DispatchForSize(cmd, froxels.width, froxels.height, FROXEL_SLICES, desc, self.dynamic_offsets)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_scatter;
		layout(set = 0, binding = ]] .. BINDING_TILE_DEPTH .. [[) uniform sampler2D tile_depth;
		layout(set = 0, binding = ]] .. BINDING_GI .. [[) uniform sampler3D froxel_gi;
		layout(set = 0, binding = ]] .. BINDING_GI_EMITTER .. [[) uniform sampler3D froxel_gi_emitter;
	]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID),
	shader = glsl_common.GetHashGLSL() .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. light_occlusion.GetSamplingGLSL("froxel_data") .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. medium_lighting.GetLocalLightsGLSL("froxel_data", LOCAL_LIGHT_LIMIT) .. SLICE_GLSL .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		uint froxel_hash(uvec3 v) {
			uvec3 h = pcg3d(v);
			return h.x ^ h.y ^ h.z;
		}

		shared vec3 shared_sky_ambient;

		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);

			if (gl_LocalInvocationIndex == 0u) shared_sky_ambient = get_ground_fog_sky_ambient(get_atmosphere_camera_origin(froxel_data.camera_position.xyz));

			barrier();

			if (any(greaterThanEqual(id.xy, ivec2(froxel_data.froxel_size)))) return;

			if (ATMOSPHERE_ENABLED == 0 || froxel_is_hidden(id, texelFetch(tile_depth, id.xy, 0).r)) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

			uint seed = froxel_hash(uvec3(id.xy, uint(id.z) + uint(froxel_data.frame) * 128u));
			vec3 jitter = vec3(uvec3(seed, seed >> 10u, seed >> 20u) & 1023u) / 1023.0 - 0.5;
			float slice_depth = froxel_slice_depth(float(id.z) + 0.5 + jitter.z);
			vec2 uv = (vec2(id.xy) + 0.5 + jitter.xy) / froxel_data.froxel_size;
			bool covered;
			float depth = froxel_point(id, uv, slice_depth, covered);
			vec3 view_dir = get_view_dir(uv);
			vec3 world_pos = (froxel_data.inv_view * vec4(view_dir * depth, 1.0)).xyz;
			vec3 air_pos = (froxel_data.inv_view * vec4(view_dir * slice_depth, 1.0)).xyz;
			if (air_pos.y < world_pos.y) air_pos = world_pos;
			vec3 ray_dir = normalize(mat3(froxel_data.inv_view) * view_dir);
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 fog_point = get_atmosphere_camera_origin(air_pos);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			float fog_extinction = ground_fog_extinction(fog_point) * per_meter;
			float density_r = rayleigh_density(fog_point);
			float density_m = mie_density(fog_point);
			vec3 air_scattering = (RAYLEIGH_BETA * density_r + MIE_BETA * density_m) * per_meter;
			float mu = dot(ray_dir, sun_dir);
			float sun_visibility = get_fog_sun_visibility(world_pos, sun_dir);
			vec3 sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(fog_point, sun_dir) * get_ground_fog_sun_transmittance(fog_point, sun_dir) * sun_visibility;
			vec4 gi = texelFetch(froxel_gi, ivec3(id.xy >> 1, id.z), 0);
			float open_sky = gi.a < 0.0 ? 1.0 : gi.a;
			vec3 probe_ambient = gi.a < 0.0 ? shared_sky_ambient : gi.rgb;
			vec3 glow = texelFetch(froxel_gi_emitter, ivec3(id.xy >> 1, id.z), 0).rgb;
			vec3 ambient = mix(probe_ambient, shared_sky_ambient, open_sky) + glow;
			vec3 scattering = get_ground_fog_in_scatter(fog_point, ray_dir, sun_dir, sun_visibility, ambient) * per_meter;
			scattering += sun * (RAYLEIGH_BETA * (density_r * phase_rayleigh(mu)) + MIE_BETA * (density_m * mie_phase(mu))) * per_meter;
			vec3 air_up = fog_point / length(fog_point);
			vec3 sky_multi = ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX == -1 ?
				ambient * air_scattering :
				sc_lookup(ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX, length(fog_point), dot(air_up, ray_dir), dot(air_up, sun_dir), mu) * ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * per_meter;
			scattering += mix(probe_ambient * air_scattering, sky_multi, open_sky * mix(0.15, 1.0, get_terrain_shadow(world_pos))) + glow * air_scattering;

			if (fog_extinction > 0.0) scattering += get_local_light_scattering(ray_dir, world_pos, GROUND_FOG_MIE_G) * fog_extinction;

			imageStore(out_scatter, id, vec4(scattering, covered ? 0.0 : 1.0));
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
				{"sun_direction", "vec4"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				render3d.WritePreviousCameraBlock(self, block)
				local sun = directional_shadows.GetPrimarySunDirection(render3d.GetLights())
				block.sun_direction[0] = sun.x
				block.sun_direction[1] = sun.y
				block.sun_direction[2] = sun.z
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
		const int SUN_BLUR_SAMPLES = 10;

		void main() {
			ivec3 id = ivec3(gl_GlobalInvocationID);
			ivec3 size = ivec3(froxel_data.froxel_size, int(FROXEL_SLICES));

			if (any(greaterThanEqual(id.xy, size.xy))) return;

			if (froxel_is_hidden(id, texelFetch(tile_depth, id.xy, 0).r)) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

			vec4 current = texelFetch(raw_scatter, id, 0);

			if (current.a == 0.0) {
				imageStore(out_scatter, id, vec4(0.0));
				return;
			}

			if (froxel_data.history <= 0.0) {
				imageStore(out_scatter, id, current);
				return;
			}

			vec4 low = current;
			vec4 high = current;

			for (int i = 0; i < 27; i++) {
				vec4 v = texelFetch(raw_scatter, clamp(id + ivec3(i % 3, (i / 3) % 3, i / 9) - 1, ivec3(0), size - 1), 0);

				if (v.a > 0.0) {
					low = min(low, v);
					high = max(high, v);
				}
			}

			vec2 uv = (vec2(id.xy) + 0.5) / froxel_data.froxel_size;
			bool covered;
			float depth = froxel_point(id, uv, froxel_slice_depth(float(id.z) + 0.5), covered);
			vec3 center = (froxel_data.inv_view * vec4(get_view_dir(uv) * depth, 1.0)).xyz;

			vec3 sun_step = 1.5 * froxel_data.sun_direction.xyz * depth * length(get_view_dir(uv + vec2(0.0, 1.0 / froxel_data.froxel_size.y)) - get_view_dir(uv));
			float line_fade = 1.0 - smoothstep(40.0, 200.0, depth);
			vec4 blurred = current;
			float blurred_weight = 1.0;

			if (line_fade > 0.0) {
				mat4 view_projection = froxel_data.projection * froxel_data.view;

				for (int i = 1; i <= SUN_BLUR_SAMPLES; i++) {
					for (int side = -1; side <= 1; side += 2) {
						vec4 line_clip = view_projection * vec4(center + sun_step * float(i * side), 1.0);
						vec3 line_coord = vec3(line_clip.xy / line_clip.w * 0.5 + 0.5, froxel_slice_coord(line_clip.w) / FROXEL_SLICES);

						if (line_clip.w > 0.0 && all(greaterThanEqual(line_coord, vec3(0.0))) && all(lessThanEqual(line_coord, vec3(1.0)))) {
							vec4 v = textureLod(raw_scatter, line_coord, 0.0);
							float weight = line_fade * v.a * exp(-0.5 * float(i * i) / float(SUN_BLUR_SAMPLES * SUN_BLUR_SAMPLES) * 4.0);
							blurred += v * weight;
							blurred_weight += weight;
						}
					}
				}
			}

			current = blurred / blurred_weight;
			vec4 around = current * 3.0;
			float around_weight = 3.0;

			for (int i = 0; i < 6; i++) {
				ivec3 offset = ivec3(i == 0 ? -1 : (i == 1 ? 1 : 0), i == 2 ? -1 : (i == 3 ? 1 : 0), i == 4 ? -1 : (i == 5 ? 1 : 0));
				ivec3 neighbor = clamp(id + offset, ivec3(0), size - 1);
				vec4 v = texelFetch(raw_scatter, neighbor, 0);
				around += v * v.a;
				around_weight += v.a;
			}

			current = around / around_weight;
			vec4 clip = froxel_data.prev_projection * froxel_data.prev_view * vec4(center, 1.0);
			vec3 previous = vec3(clip.xy / clip.w * 0.5 + 0.5, froxel_slice_coord(clip.w) / FROXEL_SLICES);
			vec4 result = current;

			if (clip.w > 0.0 && all(greaterThanEqual(previous, vec3(0.0))) && all(lessThanEqual(previous, vec3(1.0)))) {
				vec4 history = textureLod(history_scatter, previous, 0.0);
				result.rgb = mix(current.rgb, clamp(history.rgb / max(history.a, 1e-3), low.rgb, high.rgb), froxel_data.history * history.a);
			}

			result.a = 1.0;

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
			float ray_scale = length(view_dir);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			vec3 scattered = vec3(0.0);
			vec3 transmittance = vec3(1.0);
			float layer_transmittance = 1.0;

			for (int k = 0; k < int(FROXEL_SLICES); k++) {
				vec4 froxel = texelFetch(scatter, ivec3(id, k), 0);
				float step_length = (froxel_slice_depth(float(k + 1)) - froxel_slice_depth(float(k))) * ray_scale;
				vec3 mid = (froxel_data.inv_view * vec4(view_dir * froxel_slice_depth(float(k) + 0.5), 1.0)).xyz;
				vec3 point = get_atmosphere_camera_origin(mid);
				float layer_extinction = ground_fog_extinction(point) * per_meter;
				vec3 extinction = compute_view_tau(rayleigh_density(point), mie_density(point), ozone_density(point)) * per_meter + layer_extinction;

				if (ATMOSPHERE_ENABLED == 0) extinction = vec3(0.0);
				vec3 step_transmittance = exp(-extinction * step_length);
				vec3 weight = mix(vec3(step_length), (1.0 - step_transmittance) / max(extinction, vec3(1e-12)), greaterThan(extinction, vec3(1e-9)));
				scattered += transmittance * froxel.rgb * weight;
				transmittance *= step_transmittance;
				layer_transmittance *= exp(-layer_extinction * step_length);
				imageStore(out_integrated, ivec3(id, k), vec4(scattered, froxel.a));
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
					medium_lighting.WriteLightsBlock(self, block)
					return block
				end,
			},
		},
		shader = [[
			#define ATMOSPHERE_LOG_MARCH 1
		]] .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("fog_data") .. [[

			float get_cloud_shadow_km(vec3 point);
			bool fog_cloud_shadows = true;
			float fog_jitter = 0.5;
			#define ATMOSPHERE_CLOUD_SHADOW(point) (fog_cloud_shadows ? get_cloud_shadow_km(point) : 1.0)
			#define ATMOSPHERE_SCATTER_JITTER fog_jitter
		]] .. atmosphere.GetGLSLDefines("fog_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. clouds.GetShadowGLSL("fog_data.shadows") .. [[
			float get_cloud_shadow_km(vec3 point) {
				return get_cloud_shadow(vec3(point.x, point.y - PLANET_RADIUS - SEA_LEVEL_EYE_HEIGHT, point.z) / (CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER));
			}

			float get_planet_distance(vec3 dir) {
				float t = ray_sphere_intersect(get_atmosphere_camera_origin(fog_data.camera_position.xyz), dir, PLANET_RADIUS).x;
				return t > 0.0 ? t : 1e30;
			}
		]] .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("fog_data") .. screen_reconstruct.GetViewDepthGLSL("fog_data") .. froxel_fog.GetGLSL("fog_data") .. post_source.GetPreExposureGLSL("fog_data") .. [[
			void main() {
				float pre_exposure = get_pre_exposure();
				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				scene.rgb /= pre_exposure;
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				float air_distance = fog_data.ocean_distance_tex != -1 ? texture(TEXTURE(fog_data.ocean_distance_tex), in_uv).b : -1.0;
				vec3 view_dir = get_view_dir(in_uv);
				float hit_distance = -1.0;

				if (depth > 0.0) {
					hit_distance = get_view_depth(in_uv, depth) * length(view_dir);
				}

				if (air_distance >= 0.0) {
					hit_distance = hit_distance >= 0.0 ? min(air_distance, hit_distance) : air_distance;
				}

				float scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				float froxel_end = FROXEL_FAR * length(view_dir) * scale;
				vec3 sun_dir = get_current_primary_sun_direction();
				vec3 ray_dir = normalize(mat3(fog_data.inv_view) * view_dir);
				fog_jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(fog_data.frame), vec2(0.06711056, 0.00583715))));
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
					vec3 origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
					vec3 sky_dir = get_sky_lookup_dir(ray_dir, origin, sun_dir);
					float ground = get_planet_distance(sky_dir);
					float edge = min(ray_sphere_intersect(origin, sky_dir, ATMOSPHERE_RADIUS).y, ground);
					float cloud_km = min(cloud_depth * scale, edge);
					vec3 full_transmittance;
					vec3 full_scattered = get_volumetric_fog(in_uv, -1.0, full_transmittance);
					float layer_transmittance = get_fog_layer_transmittance(in_uv, -1.0);
					vec3 front_transmittance = full_transmittance;
					vec3 front_scattered = full_scattered;
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
return {
	depth_pass,
	gi_pass,
	scatter_pass,
	temporal_pass,
	integrate_pass,
	composite_pass,
}
