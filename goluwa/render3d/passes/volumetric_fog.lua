local ray_materials = import("goluwa/render3d/scene/ray_materials.lua")
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
local scene_hits = import("goluwa/render3d/scene_hits.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local fluid_volumes = import("goluwa/render3d/fluid_volumes.lua")
local fluid_volume_passes = import("goluwa/render3d/fluid_volume_passes.lua")
local FROXEL_HISTORY = 0.9
local LOCAL_LIGHT_LIMIT = 8
local BINDING_OUTPUT = 0
local BINDING_RADIANCE_CACHE = 1
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
local BINDING_OPTICAL = 15
local GI_SCENE_BINDINGS = {scene = BINDING_SCENE, hit = 30, materials = 11, light_grid = 12}
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local froxels = froxel_fog.froxels
local FROXEL_SLICES = froxel_fog.SLICES
local HIDDEN_GLSL = [[
	bool froxel_is_hidden(ivec3 id, float tile_depth_max) {
		return froxel_slice_depth(float(id.z) - 2.0) > tile_depth_max * 1.1;
	}
]]

local function write_gi_screen_texture(self, block, key)
	local texture = gi.GetScreenTexture()
	block[key] = texture and self:GetTextureIndex(texture) or -1
end

local function write_water_distance_texture(self, block, key)
	if
		render3d.IsWaterEnabled() and
		render3d.IsPassEnabled("water") and
		render3d.pipelines.water.framebuffers
	then
		block[key] = self:GetTextureIndex(render3d.pipelines.water:GetFramebuffer(system.GetFrameNumber() % 2 + 1):GetAttachment(2))
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
			name = "radiance_cache_data",
			binding_index = BINDING_RADIANCE_CACHE,
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
				{"water_distance_tex", "int"},
				scene_hits.block,
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
				write_water_distance_texture(self, block, "water_distance_tex")
				scene_hits.WriteBlock(self, block)
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
		scene_hits.GetDescriptorSets(GI_SCENE_BINDINGS, "compute") or
		nil,
	storage_buffers = VISIBILITY_RAYS and {{binding_index = BINDING_EMITTERS}} or nil,
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()

		if VISIBILITY_RAYS then
			scene_hits.Bind(self, cmd, desc, GI_SCENE_BINDINGS)
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
			scene_hits.GetDeclarationGLSL(GI_SCENE_BINDINGS) .. scene_emitters.GetDeclarationGLSL(BINDING_EMITTERS)
			or
			""
		) .. [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_gi;
		layout(set = 0, binding = ]] .. BINDING_GI_EMITTER .. [[, rgba16f) uniform writeonly image3D out_gi_emitter;
		layout(set = 0, binding = ]] .. BINDING_TILE_DEPTH .. [[) uniform sampler2D tile_depth;
	]],
	shader = glsl_common.GetHashGLSL() .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. (
			VISIBILITY_RAYS and
			"#define SCENE_HIT_SKY_RAYS 1\n#define SCENE_HIT_EMISSION (radiance_cache_data.radiance_cache_emitter_count == 0)\n" .. string.format("#define SCENE_HIT_MASK 0x%02X\n", scene_instances.MASK_SURFACES) .. post_source.GetPreExposureGLSL("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "froxel_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_hits.GetGLSL("froxel_data") .. scene_emitters.GetGLSL() .. scene_emitters.GetLightGLSL()
			or
			gi.GetCommonGLSL()
		) .. gi.GetMediumGLSL() .. froxel_fog.GetSliceGLSL("froxel_data") .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
		uint froxel_hash(uvec3 v) {
			uvec3 h = pcg3d(v);
			return h.x ^ h.y ^ h.z;
		}

		const int SCREEN_SUN_STEPS = 24;
		const float SCREEN_SUN_NEAR = 100.0;
		const float SCREEN_SUN_FAR = 150000.0;

		float screen_sun_visibility(vec3 P, vec3 sun_dir, float jitter) {
			vec3 origin = (froxel_data.view * vec4(P, 1.0)).xyz;
			vec3 dir = mat3(froxel_data.view) * sun_dir;

			if (dir.z > -0.05 || origin.z > -0.1) return 1.0;

			float start_depth = -origin.z;

			for (int i = 0; i < SCREEN_SUN_STEPS; i++) {
				vec3 p = origin + dir * (SCREEN_SUN_NEAR * pow(SCREEN_SUN_FAR / SCREEN_SUN_NEAR, (float(i) + jitter) / float(SCREEN_SUN_STEPS)));
				vec4 clip = froxel_data.projection * vec4(p, 1.0);
				vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

				if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

				float depth = textureLod(TEXTURE(froxel_data.depth_tex), uv, 0.0).r;

				if (depth <= 0.0) continue;

				float scene_depth = get_view_depth(uv, depth);
				float ray_depth = -p.z;

				if (scene_depth > start_depth && scene_depth < ray_depth && ray_depth - scene_depth < scene_depth) return 0.0;
			}

			return 1.0;
		}

		void main() {
			ivec3 quad = ivec3(gl_GlobalInvocationID);
			ivec2 size = ivec2(froxel_data.froxel_size);

			if (any(greaterThanEqual(quad.xy * 2, size))) return;

			imageStore(out_gi_emitter, quad, vec4(-1.0, -1.0, 0.0, -1.0));

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
			float other_visibility = -1.0;

			vec3 glow_body = froxel_data.atmosphere_sun_direction.y > -0.2 ? froxel_data.atmosphere_sun_direction : froxel_data.atmosphere_moon_direction;
			float other_elevation = max(glow_body.y, 0.1);
			vec2 other_horizontal = normalize(glow_body.xz + vec2(1e-6));
			uint on = froxel_hash(uvec3(seed, id.z, 11u));
			vec3 cone = vec3(float(on & 0x3ffu), float((on >> 10u) & 0x3ffu), float((on >> 20u) & 0x3ffu)) / 511.5 - 1.0;
			vec3 glow_dir = normalize(vec3(other_horizontal.x * sqrt(1.0 - other_elevation * other_elevation), other_elevation, other_horizontal.y * sqrt(1.0 - other_elevation * other_elevation)) + cone * 0.1);
			float sun_visibility = screen_sun_visibility(P, glow_body, jitter.z + 0.5);
			float glow_screen_visibility = screen_sun_visibility(P, glow_dir, jitter.x + 0.5);
			imageStore(out_gi_emitter, quad, vec4(sun_visibility, glow_screen_visibility, 0.0, -1.0));

			#ifdef SCENE_HITS
			{
				other_visibility = scene_hit_visible(P, glow_dir, SCENE_HIT_MAX_DISTANCE) ? 1.0 : 0.0;
				sun_visibility *= scene_hit_visible(P, normalize(glow_body + cone.zxy * 0.005), SCENE_HIT_MAX_DISTANCE) ? 1.0 : 0.0;
				imageStore(out_gi_emitter, quad, vec4(sun_visibility, glow_screen_visibility, 0.0, other_visibility));
			}
			#endif

			if (gi_available()) {
				if (!gi_in_volume(P)) {
					imageStore(out_gi, quad, vec4(-1.0));
					return;
				}

				uint n = froxel_hash(uvec3(seed, id.z, 7u));
				float z = float(n & 0xffffu) / 32768.0 - 1.0;
				float phi = float(n >> 16u) * (6.28318530718 / 65536.0);
				vec3 dir = vec3(sqrt(max(1.0 - z * z, 0.0)) * vec2(cos(phi), sin(phi)), z);

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
		unpack(fluid_volume_passes.GetSampledImages()),
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
				{"water_distance_tex", "int"},
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
				write_water_distance_texture(self, block, "water_distance_tex")
				light_occlusion.WriteOcclusionBlock(block, medium_lighting.WriteLightsBlock(self, block))
				return block
			end,
		},
	},
	storage_buffers = {
		{binding_index = BINDING_LIGHT_GRID},
		{binding_index = BINDING_OPTICAL},
		{binding_index = fluid_volume_passes.BINDING_RECORDS},
	},
	on_pre_draw = function(self, cmd, frame, desc)
		froxel_fog.EnsureResources()
		light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)
		ray_materials.BindOpticalVolumes(self, desc, BINDING_OPTICAL)
		fluid_volume_passes.BindRecords(self, desc)
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
	]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID) .. ray_materials.GetOpticalDeclarationsGLSL(BINDING_OPTICAL) .. fluid_volume_passes.GetDeclarationGLSL(),
	shader = glsl_common.GetHashGLSL() .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. light_occlusion.GetSamplingGLSL("froxel_data") .. scene_lights.GetLightGLSLCode() .. medium_lighting.GetSunHelpersGLSL("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. ray_materials.GetOpticalTintGLSL() .. medium_lighting.GetLocalLightsGLSL(
			"froxel_data",
			LOCAL_LIGHT_LIMIT,
			{
				attenuation = "(optical_layer >= 0 ? optical_volume_tint(optical_layer, world_pos, L, max(dist, 0.0), true, true, false) : vec3(1.0))",
			}
		) .. medium_lighting.GetLocalLightsGLSL(
			"froxel_data",
			LOCAL_LIGHT_LIMIT,
			{
				visibility = false,
				name = "get_volume_light_scattering",
				attenuation = "optical_range_tint(optical_ranges.z, optical_ranges.w, world_pos, L, max(dist, 0.0), false, false, false)",
			}
		) .. fluid_volumes.GetGLSL() .. froxel_fog.GetSliceGLSL("froxel_data") .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
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
			vec3 segment_origin = froxel_data.camera_position.xyz;
			bool unused_covered;
			float segment_end = min(froxel_slice_depth(float(id.z + 1)), froxel_point(id, uv, 1e30, unused_covered)) * length(view_dir);
			float segment_start = min(froxel_slice_depth(float(id.z)) * length(view_dir), segment_end);
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 fog_point = get_atmosphere_camera_origin(air_pos);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			float fog_extinction = ground_fog_extinction(fog_point) * per_meter;
			float density_r = rayleigh_density(fog_point);
			float density_m = mie_density(fog_point);
			vec3 air_scattering = (RAYLEIGH_BETA * density_r + MIE_BETA * density_m) * per_meter;
			float mu = dot(ray_dir, sun_dir);
			vec3 raymarched_shadow = fluid_sun_transmittance(world_pos, sun_dir, -1, FLUID_MODE_FROXELS);
			vec3 froxel_fluid_shadow = fluid_sun_transmittance(world_pos, sun_dir, -1, FLUID_MODE_RAYMARCH);
			vec4 gi_emitter = texelFetch(froxel_gi_emitter, ivec3(id.xy >> 1, id.z), 0);
			float sun_ray_weight = gi_emitter.r < 0.0 ? 0.0 : 1.0;
			float sun_visibility = get_fog_sun_visibility(world_pos, sun_dir) * mix(1.0, gi_emitter.r, sun_ray_weight) * dot(raymarched_shadow, vec3(1.0 / 3.0));
			vec3 fluid_sun = ATMOSPHERE_SUN_ILLUMINANCE * SUN_COLOR * sample_transmittance_lut(fog_point, sun_dir) * get_ground_fog_sun_transmittance(fog_point, sun_dir) * sun_visibility;
			sun_visibility *= dot(froxel_fluid_shadow, vec3(1.0 / 3.0));
			vec4 gi = texelFetch(froxel_gi, ivec3(id.xy >> 1, id.z), 0);
			float open_sky = gi.a < 0.0 ? 1.0 : gi.a;
			vec3 probe_ambient = gi.a < 0.0 ? shared_sky_ambient : gi.rgb;
			vec3 ambient = mix(probe_ambient, shared_sky_ambient, open_sky);
			vec3 scattering = get_ground_fog_lit_scatter(fog_point, ambient) * per_meter;
			vec3 air_up = fog_point / length(fog_point);
			float glow_visibility = (gi_emitter.a >= 0.0 ? gi_emitter.a : 1.0) * mix(0.15, 1.0, get_terrain_shadow(world_pos)) * (gi_emitter.g < 0.0 ? 1.0 : gi_emitter.g);
			bool primary_is_sun = dot(sun_dir, ATMOSPHERE_SKY_SUN_DIRECTION) > 0.9999;
			vec3 sky_multi = vec3(0.0);

			for (int body = 0; body < 2; body++) {
				bool is_sun = body == 0;
				vec3 body_dir = is_sun ? ATMOSPHERE_SKY_SUN_DIRECTION : ATMOSPHERE_MOON_DIRECTION;
				float body_illuminance = is_sun ? ATMOSPHERE_SUN_DISC_ILLUMINANCE : ATMOSPHERE_SUN_DISC_ILLUMINANCE * ATMOSPHERE_MOON_SKY_SCALE;
				float body_visibility = is_sun == primary_is_sun ? sun_visibility : glow_visibility;
				float body_mu = dot(ray_dir, body_dir);
				vec3 body_light = body_illuminance * SUN_COLOR * per_meter;
				scattering += body_light * sample_transmittance_lut(fog_point, body_dir) * get_ground_fog_sun_transmittance(fog_point, body_dir) * body_visibility * (RAYLEIGH_BETA * (density_r * phase_rayleigh(body_mu)) + MIE_BETA * (density_m * mie_phase(body_mu)));
				scattering += get_ground_fog_lit_scatter(fog_point, get_ground_fog_sun(fog_point, ray_dir, body_dir, body_illuminance) * clamp(body_visibility, 0.0, 1.0)) * per_meter;

				if (ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX != -1) {
					sky_multi += sc_lookup(ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX, length(fog_point), dot(air_up, ray_dir), dot(air_up, body_dir), body_mu) * body_light;
				}
			}

			if (ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX == -1) sky_multi = ambient * air_scattering;

			scattering += mix(probe_ambient * air_scattering, sky_multi, open_sky * glow_visibility);

			if (fog_extinction > 0.0) scattering += get_local_light_scattering(ray_dir, world_pos, GROUND_FOG_MIE_G) * fog_extinction * GROUND_FOG_TINT * GROUND_FOG_ALBEDO;

			for (int i = 0; i < fluid_counts.x; i++) {
				fluid_record v = fluid_records[i];

				if (v.mode != FLUID_MODE_FROXELS) continue;

				vec4 f;
				vec4 l;
				float coverage = fluid_segment_sample(v, segment_origin, ray_dir, segment_start, segment_end, f, l);
				float smoke = f.x * coverage;
				float flame = f.w * coverage;

				if (smoke + flame <= 0.0) continue;

				scattering += smoke * v.scattering * (fluid_sun * fluid_sun_phase(v, l, mu) + ambient * fluid_ambient_transmittance(v, l) + get_volume_light_scattering(ray_dir, world_pos, v.g));
				scattering += min((smoke * v.absorption + flame * v.flame_absorption) * fluid_emission(f.y), vec3(60000.0));
			}

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
				{"water_distance_tex", "int"},
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
				write_water_distance_texture(self, block, "water_distance_tex")
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
	shader = froxel_fog.GetSliceGLSL("froxel_data") .. HIDDEN_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. froxel_fog.GetPointGLSL("froxel_data") .. [[
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
		unpack(fluid_volume_passes.GetSampledImages()),
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
	storage_buffers = {
		{binding_index = BINDING_OPTICAL},
		{binding_index = fluid_volume_passes.BINDING_RECORDS},
	},
	on_pre_draw = function(self, cmd, frame, desc)
		ray_materials.BindOpticalVolumes(self, desc, BINDING_OPTICAL)
		fluid_volume_passes.BindRecords(self, desc)
	end,
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image3D out_integrated;
		layout(set = 0, binding = ]] .. BINDING_SCATTER .. [[) uniform sampler3D scatter;
	]] .. ray_materials.GetOpticalDeclarationsGLSL(BINDING_OPTICAL) .. fluid_volume_passes.GetDeclarationGLSL(),
	shader = atmosphere.GetGLSLDefines("froxel_data", string.format("%.17g", atmosphere.GetSunIlluminance())) .. atmosphere.GetAerialPerspectiveGLSLCode() .. fluid_volumes.GetGLSL() .. froxel_fog.GetSliceGLSL("froxel_data") .. froxel_fog.GetViewDirGLSL("froxel_data") .. [[
		void main() {
			ivec2 id = ivec2(gl_GlobalInvocationID.xy);

			if (any(greaterThanEqual(id, ivec2(froxel_data.froxel_size)))) return;

			vec3 view_dir = get_view_dir((vec2(id) + 0.5) / froxel_data.froxel_size);
			float ray_scale = length(view_dir);
			float per_meter = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			vec3 scattered = vec3(0.0);
			vec3 transmittance = vec3(1.0);
			float layer_transmittance = 1.0;
			vec3 ray_origin = froxel_data.camera_position.xyz;
			vec3 ray_dir = normalize(mat3(froxel_data.inv_view) * view_dir);

			for (int k = 0; k < int(FROXEL_SLICES); k++) {
				vec4 froxel = texelFetch(scatter, ivec3(id, k), 0);
				float step_length = (froxel_slice_depth(float(k + 1)) - froxel_slice_depth(float(k))) * ray_scale;
				vec3 mid = (froxel_data.inv_view * vec4(view_dir * froxel_slice_depth(float(k) + 0.5), 1.0)).xyz;
				vec3 point = get_atmosphere_camera_origin(mid);
				float layer_extinction = ground_fog_extinction(point) * per_meter;
				float t0 = froxel_slice_depth(float(k)) * ray_scale;
				float t1 = froxel_slice_depth(float(k + 1)) * ray_scale;
				vec3 volume_extinction = fluid_froxel_segment_extinction(ray_origin, ray_dir, t0, t1);
				vec3 extinction = compute_view_tau(rayleigh_density(point), mie_density(point), ozone_density(point)) * per_meter + layer_extinction * GROUND_FOG_TINT + volume_extinction;

				if (ATMOSPHERE_ENABLED == 0) extinction = vec3(0.0);
				vec3 step_transmittance = exp(-extinction * step_length);
				vec3 weight = mix(vec3(step_length), (1.0 - step_transmittance) / max(extinction, vec3(1e-12)), greaterThan(extinction, vec3(1e-9)));
				scattered += transmittance * froxel.rgb * weight;
				transmittance *= step_transmittance;
				layer_transmittance *= exp(-(layer_extinction + dot(volume_extinction, vec3(1.0 / 3.0))) * step_length);
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
					{"water_distance_tex", "int"},
					{"gi_screen_tex", "int"},
					{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					atmosphere.GetBlockLayout(),
					post_source.pre_exposure_block,
					{"cloud_view_tex", "int"},
					{"cloud_view_depth_tex", "int"},
					{"frame", "int"},
					{"fluid_scatter_tex", "int"},
					{"fluid_transmittance_tex", "int"},
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

					if fluid_volumes.HasRaymarched() then
						local scatter, transmittance = fluid_volume_passes.GetViewTextures()
						block.fluid_scatter_tex = self:GetTextureIndex(scatter)
						block.fluid_transmittance_tex = self:GetTextureIndex(transmittance)
					else
						block.fluid_scatter_tex = -1
						block.fluid_transmittance_tex = -1
					end

					write_water_distance_texture(self, block, "water_distance_tex")
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
				return get_cloud_shadow(vec3(point.x, point.y - PLANET_RADIUS - SEA_LEVEL_HEIGHT, point.z) / (CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER));
			}

			float get_planet_distance(vec3 dir) {
				float t = ray_sphere_intersect(get_atmosphere_camera_origin(fog_data.camera_position.xyz), dir, PLANET_RADIUS).x;
				return t > 0.0 ? t : 1e30;
			}
		]] .. froxel_fog.GetSliceGLSL("fog_data") .. froxel_fog.GetViewDirGLSL("fog_data") .. screen_reconstruct.GetViewDepthGLSL("fog_data") .. froxel_fog.GetGLSL("fog_data") .. post_source.GetPreExposureGLSL("fog_data") .. [[
			vec3 integrate_air(vec3 origin, vec3 dir, float t_near, float t_far, vec3 primary_dir, int steps, out vec3 view_transmittance) {
				vec3 scattered = integrate_scattering(origin, dir, t_near, t_far, primary_dir, steps, vec2(1.0), 1.0, view_transmittance);

				bool primary_is_sun = dot(primary_dir, ATMOSPHERE_SKY_SUN_DIRECTION) > 0.9999;
				vec3 other_dir = primary_is_sun ? ATMOSPHERE_MOON_DIRECTION : ATMOSPHERE_SKY_SUN_DIRECTION;
				vec3 unused;
				scattered += integrate_scattering(origin, dir, t_near, t_far, other_dir, steps, vec2(1.0), 1.0, unused) * ((primary_is_sun ? ATMOSPHERE_SUN_DISC_ILLUMINANCE * ATMOSPHERE_MOON_SKY_SCALE : ATMOSPHERE_SUN_DISC_ILLUMINANCE) / ATMOSPHERE_SUN_ILLUMINANCE);

				return scattered;
			}

			vec3 far_air_source(vec3 p, vec3 up, vec3 ray_dir, vec3 light_dir, float density_r, float density_m, float elevation_jitter) {
				float mu = dot(ray_dir, light_dir);
				vec3 single = (RAYLEIGH_BETA * (density_r * phase_rayleigh(mu)) + MIE_BETA * (density_m * mie_phase(mu))) * sample_transmittance_lut(p, light_dir) * ATMOSPHERE_CLOUD_SHADOW(p);
				vec3 multi = ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX != -1 ? sc_lookup_jittered(ATMOSPHERE_SCATTERING_SOURCE_TEXTURE_INDEX, length(p), dot(up, ray_dir), dot(up, light_dir), mu, elevation_jitter) : vec3(0.0);
				return (single + multi) * SUN_COLOR;
			}

			// past the handover distance (meters along the ray) the air in front of geometry is marched per pixel instead of read from the froxels, whose log slices cannot resolve air far from a high camera; it marches back to front from the hit so the steps crowd where the air is dense, and integrates the multiple scattering source, since the difference of two path lookups breaks for rays that end on the ground
			const int FAR_AIR_STEPS = 24;

			vec3 apply_far_air(vec3 color, vec3 ray_dir, vec3 sun_dir, float from_m, float to_m) {
				float scale = CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
				vec3 origin = get_atmosphere_camera_origin(fog_data.camera_position.xyz);
				float fog_near;
				float fog_length;

				if (get_ground_fog_segment_with_ground_clip(origin, ray_dir, to_m * scale, false, fog_near, fog_length)) {
					float fog_far = fog_near + fog_length;
					fog_near = max(fog_near, from_m * scale);

					if (fog_far > fog_near) color = apply_ground_fog_segment(color, origin, ray_dir, fog_near, fog_far - fog_near, sun_dir, get_fog_sun_horizon_visibility(sun_dir), vec3(0.0), 1.0);
				}

				vec2 shell = ray_sphere_intersect(origin, ray_dir, ATMOSPHERE_RADIUS);
				float t_near = max(from_m * scale, shell.x);
				float t_far = min(to_m * scale, shell.y);

				if (t_far <= t_near) return color;

				bool primary_is_sun = dot(sun_dir, ATMOSPHERE_SKY_SUN_DIRECTION) > 0.9999;
				vec3 other_dir = primary_is_sun ? ATMOSPHERE_MOON_DIRECTION : ATMOSPHERE_SKY_SUN_DIRECTION;
				float other_illuminance = primary_is_sun ? ATMOSPHERE_SUN_DISC_ILLUMINANCE * ATMOSPHERE_MOON_SKY_SCALE : ATMOSPHERE_SUN_DISC_ILLUMINANCE;
				float segment = t_far - t_near;
				float elevation_jitter = fract(fog_jitter * 7.31 + 0.37) - 0.5;

				for (int i = 0; i < FAR_AIR_STEPS; i++) {
					float d0 = get_march_distance(float(i) / float(FAR_AIR_STEPS), segment);
					float d1 = get_march_distance(float(i + 1) / float(FAR_AIR_STEPS), segment);
					float step_size = d1 - d0;
					vec3 p = origin + ray_dir * (t_far - d0 - fog_jitter * step_size);
					vec3 up = normalize(p);
					float density_r = rayleigh_density(p);
					float density_m = mie_density(p);
					vec3 extinction = compute_view_tau(density_r, density_m, ozone_density(p));
					vec3 step_transmittance = exp(-extinction * step_size);
					vec3 source = far_air_source(p, up, ray_dir, sun_dir, density_r, density_m, elevation_jitter) * ATMOSPHERE_SUN_ILLUMINANCE + far_air_source(p, up, ray_dir, other_dir, density_r, density_m, elevation_jitter) * other_illuminance;
					vec3 weight = mix(vec3(step_size), (1.0 - step_transmittance) / max(extinction, vec3(1e-9)), greaterThan(extinction, vec3(1e-9)));
					color = color * step_transmittance + source * weight;
				}

				return color;
			}

			void main() {
				float pre_exposure = get_pre_exposure();
				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				scene.rgb /= pre_exposure;
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				float air_distance = fog_data.water_distance_tex != -1 ? texture(TEXTURE(fog_data.water_distance_tex), in_uv).b : -1.0;
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
					bool air_past_volume = edge > froxel_end;
					fog_cloud_shadows = false;

					if (cloud_km <= froxel_end) {
						front_scattered = get_volumetric_fog(in_uv, cloud_depth, front_transmittance);
						behind_scattered = full_scattered - front_scattered;

						if (air_past_volume) {
							vec3 tail_transmittance;
							behind_scattered += full_transmittance * integrate_air(origin, sky_dir, froxel_end, edge, sun_dir, 32, tail_transmittance);
						}
					} else if (air_past_volume) {
						vec3 before_transmittance;
						vec3 before = integrate_air(origin, sky_dir, froxel_end, cloud_km, sun_dir, 24, before_transmittance);
						front_scattered = full_scattered + full_transmittance * before;
						front_transmittance = full_transmittance * before_transmittance;
						vec3 after_transmittance;
						behind_scattered = front_transmittance * integrate_air(origin, sky_dir, cloud_km, edge, sun_dir, 24, after_transmittance);
					}

					color = front_scattered + front_transmittance * cloud.rgb + cloud.a * (behind_scattered + layer_transmittance * scene.rgb);
				} else {
					float froxel_distance = hit_distance;

					if (hit_distance >= 0.0) {
						float camera_altitude = length(get_atmosphere_camera_origin(fog_data.camera_position.xyz)) - PLANET_RADIUS;
						float handover = FROXEL_FAR * length(view_dir) * (1.0 - smoothstep(4.0, 16.0, camera_altitude));

						if (ATMOSPHERE_ENABLED != 0 && hit_distance > handover) {
							if (cloud.a < 1.0 && cloud_depth > handover) {
								scene.rgb = apply_far_air(scene.rgb, ray_dir, sun_dir, cloud_depth, hit_distance) * cloud.a + cloud.rgb;
								scene.rgb = apply_far_air(scene.rgb, ray_dir, sun_dir, handover, cloud_depth);
								cloud = vec4(0.0, 0.0, 0.0, 1.0);
							} else {
								scene.rgb = apply_far_air(scene.rgb, ray_dir, sun_dir, handover, hit_distance);
							}

							froxel_distance = handover;
						}

						cloud_front = cloud.rgb;
						scene.rgb *= cloud.a;
					}

					vec3 fog_transmittance;
					vec3 fog_scattered = get_volumetric_fog(in_uv, froxel_distance, fog_transmittance);
					color = scene.rgb * fog_transmittance + fog_scattered;

					if (fog_data.cloud_view_tex >= 0 && cloud.a < 1.0) {
						vec3 front_transmittance;
						vec3 front_scattered = get_volumetric_fog(in_uv, froxel_distance >= 0.0 ? min(cloud_depth, froxel_distance) : cloud_depth, front_transmittance);
						color = front_scattered + front_transmittance * cloud_front + cloud.a * (fog_scattered - front_scattered) + fog_transmittance * scene.rgb;
					}
				}

				if (fog_data.fluid_scatter_tex >= 0) {
					vec4 fluid = textureLod(TEXTURE(fog_data.fluid_scatter_tex), in_uv, 0.0);

					if (fluid.a >= 0.0) {
						vec3 fluid_transmittance = textureLod(TEXTURE(fog_data.fluid_transmittance_tex), in_uv, 0.0).rgb;
						vec3 front_transmittance;
						vec3 front_scattered = get_volumetric_fog(in_uv, fluid.a, front_transmittance);
						color = front_scattered + front_transmittance * fluid.rgb / pre_exposure + fluid_transmittance * (color - front_scattered);
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
	fluid_volume_passes.view,
	composite_pass,
}
