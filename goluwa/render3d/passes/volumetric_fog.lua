local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
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
--[[
	The low altitude fog (atmosphere.lua's scenery fog) in two parts:

	Up to froxel_fog.FAR meters of view depth it lives in froxel_fog.lua's
	froxel volume. volumetric_froxel_scatter
	lights one jittered point per froxel (sun with its shadow, sky or DDGI
	ambient, local lights with their shadows), volumetric_froxel_temporal
	blends that into last frame's volume and volumetric_froxel_integrate
	marches each column once front to back.

	Beyond that the composite integrates the rest of the ray analytically,
	with one shadow lookup at a representative point.
]]
-- history kept per 60hz frame
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
	local texture = render3d.gi_provider.GetScreenTexture()
	block[key] = texture and self:GetTextureIndex(texture) or -1
end

local function write_ocean_distance_texture(self, block, key)
	if render3d.pipelines.ocean and render3d.pipelines.ocean.framebuffers then
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
				if render3d.pipelines.ddgi_resolve then
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
				render3d.gbuffer_block,
				{"froxel_size", "vec2"},
				{"frame", "int"},
				{"gi_screen_tex", "int"},
				{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
				{"light_count", "int"},
				{"shadows", scene_lights.BuildShadowsBlockLayout()},
				atmosphere.GetBlockLayout(),
				unpack(light_occlusion.GetBlockLayout()),
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				render3d.WriteGBufferBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
				block.frame = system.GetFrameNumber()
				write_gi_screen_texture(self, block, "gi_screen_tex")
				light_occlusion.WriteOcclusionBlock(block, write_lights_block(self, block))
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
	]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION, 0) .. light_grid.GetGLSL(BINDING_LIGHT_GRID),
	shader = [[
		#define saturate(x) clamp(x, 0.0, 1.0)
	]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL() .. light_occlusion.GetSamplingGLSL("froxel_data") .. scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("froxel_data") .. atmosphere.GetGLSLDefines("froxel_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("froxel_data", "get_fog_sun_visibility") .. scene_lights.GetPointShadowGLSL("froxel_data") .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. [[
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
		vec3 get_ambient(vec3 P, vec2 uv, vec3 ray_origin, vec3 ray_dir, vec3 sun_dir, uint seed) {
			vec3 sky = get_scenery_fog_sky_ambient(ray_origin, ray_dir, sun_dir);

			if (ddgi_data.ddgi_cascade_count > 0 && ddgi_in_volume(P)) {
				// one random direction a frame; the history averages them
				float z = float(seed & 0xffffu) / 32768.0 - 1.0;
				float phi = float(seed >> 16u) * (6.28318530718 / 65536.0);
				vec3 N = vec3(sqrt(max(1.0 - z * z, 0.0)) * vec2(cos(phi), sin(phi)), z);
				float weight;
				vec4 gi = ddgi_sample_irradiance(P, N, vec3(0.0), false, weight);

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

			uint seed = froxel_hash(uvec3(id.xy, uint(id.z) + uint(froxel_data.frame) * 128u));
			vec3 jitter = vec3(uvec3(seed, seed >> 10u, seed >> 20u) & 1023u) / 1023.0 - 0.5;
			vec2 uv = (vec2(id.xy) + 0.5 + jitter.xy) / froxel_data.froxel_size;
			vec4 surface = froxel_data.inv_projection * vec4(uv * 2.0 - 1.0, textureLod(TEXTURE(froxel_data.depth_tex), uv, 0.0).r, 1.0);
			// No pixel sees a point behind the surface at its uv, but a froxel
			// reaching past a wall would bring the light on its other side to
			// the pixels in front of it. Such points are lit in front of the wall.
			float depth = min(froxel_slice_depth(float(id.z) + 0.5 + jitter.z), froxel_surface_limit(-surface.z / surface.w));
			vec3 view_dir = get_view_dir(uv);
			vec3 world_pos = (froxel_data.inv_view * vec4(view_dir * depth, 1.0)).xyz;
			// not from world_pos, which can land on the camera
			vec3 ray_dir = normalize(mat3(froxel_data.inv_view) * view_dir);
			vec3 sun_dir = get_current_primary_sun_direction();
			vec3 fog_origin = get_atmosphere_camera_origin(froxel_data.camera_position.xyz);
			vec3 fog_point = get_atmosphere_camera_origin(world_pos);
			// per meter
			float extinction = scenery_fog_density(fog_point) * SCENERY_FOG_EXTINCTION * CAMERA_METERS_TO_KM * CAMERA_TEST_MULTIPLIER;
			vec3 light = vec3(0.0);

			if (extinction > 0.0) {
				light = get_scenery_fog_sun(fog_point, ray_dir, sun_dir) * get_fog_sun_visibility(world_pos, sun_dir);
				light += get_ambient(world_pos, uv, fog_origin, ray_dir, sun_dir, froxel_hash(uvec3(seed, id.z, 7u)));
				light += get_local_light_scattering(ray_dir, world_pos);
			}

			// scattering per meter: the radiance alone overflows a half float
			imageStore(out_scatter, id, vec4(light * extinction, extinction));
		}
	]],
}
-- Blends this frame's samples into the reprojected history. The history is
-- clamped to the range of the new samples around the froxel: resampling it
-- every frame while the camera moves drags light between neighbouring
-- froxels, which a froxel next to a bright one (a lit doorway behind a
-- wall) would otherwise keep for as long as the history lasts.
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
				render3d.gbuffer_block,
				{"froxel_size", "vec2"},
				{"history", "float"},
			},
			write = function(self, block)
				render3d.WriteCameraBlock(self, block)
				render3d.WritePreviousCameraBlock(self, block)
				render3d.WriteGBufferBlock(self, block)
				block.froxel_size[0] = froxels.width
				block.froxel_size[1] = froxels.height
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
	shader = SLICE_GLSL .. froxel_fog.GetViewDirGLSL("froxel_data") .. [[
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

			// the point the froxel stands for, clamped to the surface like
			// its samples: a froxel behind a wall holds the light in front of
			// it, and the same world point last frame may have been in view
			// (through a doorway) with very different light
			vec2 uv = (vec2(id.xy) + 0.5) / froxel_data.froxel_size;
			vec4 surface = froxel_data.inv_projection * vec4(uv * 2.0 - 1.0, textureLod(TEXTURE(froxel_data.depth_tex), uv, 0.0).r, 1.0);
			float depth = min(froxel_slice_depth(float(id.z) + 0.5), froxel_surface_limit(-surface.z / surface.w));
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
-- fogs the lit opaque scene. the translucent surfaces drawn over it fog
-- themselves with the same volume
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
					render3d.gbuffer_block,
					{"source_tex", "int"},
					{"ocean_distance_tex", "int"},
					{"gi_screen_tex", "int"},
					{"lights", scene_lights.BuildLightsBlockLayout(), scene_lights.MAX_LIGHTS},
					{"light_count", "int"},
					{"shadows", scene_lights.BuildShadowsBlockLayout()},
					atmosphere.GetBlockLayout(),
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					block.source_tex = self:GetTextureIndex(post_source.GetOpaqueSceneTexture())
					write_ocean_distance_texture(self, block, "ocean_distance_tex")
					write_gi_screen_texture(self, block, "gi_screen_tex")
					write_lights_block(self, block)
					return block
				end,
			},
		},
		shader = scene_lights.GetLightGLSLCode() .. get_sun_helpers_glsl("fog_data") .. atmosphere.GetGLSLDefines("fog_data", "get_current_primary_sun_illuminance()") .. atmosphere.GetAerialPerspectiveGLSLCode() .. directional_shadows.GetMediumDirectionalShadowGLSL("fog_data", "get_fog_sun_visibility") .. SLICE_GLSL .. froxel_fog.GetViewDirGLSL("fog_data") .. froxel_fog.GetGLSL("fog_data", "get_fog_sun_visibility", "get_current_primary_sun_direction()") .. [[
			void main() {
				vec4 scene = texture(TEXTURE(fog_data.source_tex), in_uv);
				float depth = texture(TEXTURE(fog_data.depth_tex), in_uv).r;
				float ocean_distance = fog_data.ocean_distance_tex != -1 ? texture(TEXTURE(fog_data.ocean_distance_tex), in_uv).r : -1.0;
				float hit_distance = -1.0;

				if (ocean_distance > 0.0) {
					hit_distance = ocean_distance;
				} else if (depth < 1.0) {
					vec4 view_pos = fog_data.inv_projection * vec4(in_uv * 2.0 - 1.0, depth, 1.0);
					hit_distance = -view_pos.z / view_pos.w * length(get_view_dir(in_uv));
				}

				vec4 fog = get_volumetric_fog(in_uv, hit_distance);
				set_color(vec4(scene.rgb * fog.a + fog.rgb, scene.a));
			}
		]],
	},
	CullMode = "none",
	DepthTest = false,
	DepthWrite = false,
}
return {scatter_pass, temporal_pass, integrate_pass, composite_pass}
