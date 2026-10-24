local glsl_common = import("goluwa/render3d/glsl_common.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local scene_hit = import("goluwa/render3d/scene/hit.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local clouds = import("goluwa/render3d/clouds.lua")
local glass_light = import("goluwa/render3d/glass_light.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local P = ddgi.PROBES_PER_AXIS
local CASCADES = ddgi.CASCADES
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 1
local BINDING_RAY_HITS = 2
local BINDING_HIT = 30
local BINDING_MATERIALS = 5
local BINDING_STATE = 9
local BINDING_EMITTERS = 8
local BINDING_SCENE = 10
local BINDING_LIGHT_GRID = 11
local BINDING_SCREEN_GEOMETRY = 13
local BINDING_SCREEN_SPECULAR = 14
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local SCENE_DESCRIPTOR = scene_hit.GetDescriptorSets(BINDING_HIT, "compute", VISIBILITY_RAYS and BINDING_SCENE or nil)
local SCENE_GLSL = VISIBILITY_RAYS and
	[[
	#extension GL_EXT_ray_query : require
	#define DDGI_VISIBILITY_RAYS
	layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT ddgi_scene;
]] or
	""

local function data_uniform()
	return {
		name = "ddgi_data",
		binding_index = BINDING_UNIFORM,
		block = ddgi.GetBlockLayout(),
		write = function(self, block)
			return ddgi.WriteBlock(self, block)
		end,
	}
end

local function common_glsl()
	return glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("ddgi_data") .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL()
end

local function record_ray_info(name, state)
	local updating = 0

	for c = 0, state.cascade_count - 1 do
		if bit.band(state.update_mask, bit.lshift(1, c)) ~= 0 then
			updating = updating + 1
		end
	end

	local per_cascade = (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) * P ^ 3
	gpu_timing.SetInfo(name, "cascades", state.cascade_count)
	gpu_timing.SetInfo(name, "mask", state.update_mask)
	gpu_timing.SetInfo(name, "updating", updating)
	gpu_timing.SetInfo(name, "dispatched", per_cascade * state.cascade_count)
	gpu_timing.SetInfo(name, "rays", per_cascade * updating)
end

local function pass_trace()
	return {
		name = "ddgi_trace",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"ddgi_trace_dummy", "r"}}},
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 1, y = 1, z = 1},
		shader = "void main() {}",
		on_pre_draw = function(self, cmd, frame, desc)
			local state = ddgi.GetFrameState()
			local tlas = ddgi.RTSupported() and scene_rt.GetTLAS(cmd) or nil
			state.rt_ready = tlas ~= nil
			state.tlas = tlas

			if not tlas then return end

			local rt = ddgi.GetRTPipeline()
			local params = ddgi.WriteRTParams()
			local hits = ddgi.GetRayHitBuffer()
			rt:UpdateDescriptorSet("uniform_buffer", desc, 0, 0, params, params:GetSize())
			rt:UpdateDescriptorSet("storage_buffer", desc, 1, 0, hits, hits:GetSize())
			local emitters = ddgi.GetEmitterBuffer(cmd)
			scene_hit.Bind(rt, desc, 10)
			rt:UpdateDescriptorSet("storage_buffer", desc, 6, 0, emitters, emitters:GetSize())

			if ddgi.ALPHA_TEST then
				local materials = ddgi.WriteMaterialBuffer(rt)
				rt:UpdateDescriptorSet("storage_buffer", desc, 9, 0, materials, materials:GetSize())
			end

			rt:UpdateDescriptorSet("acceleration_structure_khr", desc, 2, 0, tlas)
			local probe_data = render3d.pipelines.ddgi_probe_data:GetFramebuffer(1):GetAttachment(1)
			rt:UpdateDescriptorSet(
				"combined_image_sampler",
				desc,
				3,
				0,
				probe_data:GetView(),
				render.CreateSampler(probe_data:GetSamplerConfig())
			)
			local guide = render3d.pipelines.ddgi_guide:GetFramebuffer(1):GetAttachment(1)
			rt:UpdateDescriptorSet(
				"combined_image_sampler",
				desc,
				4,
				0,
				guide:GetView(),
				render.CreateSampler(guide:GetSamplerConfig())
			)
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			local state = ddgi.GetFrameState()

			if not state.rt_ready then return end

			record_ray_info("ddgi_trace", state)
			local hits = ddgi.GetRayHitBuffer()
			cmd:PipelineBarrier{
				srcStage = "compute",
				dstStage = "ray_tracing_shader_khr",
				bufferBarriers = {
					{buffer = hits, srcAccessMask = "shader_read", dstAccessMask = "shader_write"},
				},
			}
			ddgi.GetRTPipeline():DispatchRays(
				cmd,
				ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES,
				P ^ 3,
				ddgi.GetFrameState().cascade_count,
				desc
			)
			cmd:PipelineBarrier{
				srcStage = "ray_tracing_shader_khr",
				dstStage = "compute",
				bufferBarriers = {
					{buffer = hits, srcAccessMask = "shader_write", dstAccessMask = "shader_read"},
				},
			}
		end,
	}
end

local function pass_shade()
	local shade_buffers = {
		{binding_index = BINDING_RAY_HITS},
		{binding_index = BINDING_MATERIALS},
		{binding_index = BINDING_EMITTERS},
		{binding_index = BINDING_LIGHT_GRID},
	}
	return {
		name = "ddgi_shade",
		ComputePass = true,
		ColorFormat = {
			{
				ddgi.HALF_PRECISION_RAYS and "r16g16b16a16_sfloat" or "r32g32b32a32_sfloat",
				{"ddgi_ray_radiance", "rgba"},
			},
		},
		FramebufferSize = {x = (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) * CASCADES, y = P ^ 3},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		ray_generation = VISIBILITY_RAYS and
			render.GetDevice().ray_tracing_supported and
			ddgi.IsShadeRayGeneration() and
			{declarations = ""} or
			nil,
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = "compute"}},
		storage_buffers = shade_buffers,
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			record_ray_info("ddgi_shade", ddgi.GetFrameState())
			self.pipeline:DispatchForSize(
				cmd,
				fb.height,
				(ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) * ddgi.GetFrameState().cascade_count,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		on_pre_draw = function(self, cmd, frame, desc)
			local hits = ddgi.GetRayHitBuffer()
			local materials = ddgi.WriteMaterialBuffer(self)
			local emitters = ddgi.GetEmitterBuffer(cmd)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_RAY_HITS, 0, hits, hits:GetSize())
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_MATERIALS, 0, materials, materials:GetSize())
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)

			if VISIBILITY_RAYS then
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, scene_rt.GetTLAS(cmd))
			end

			scene_hit.Bind(self, desc, BINDING_HIT)
		end,
		descriptor_sets = SCENE_DESCRIPTOR,
		custom_declarations = SCENE_GLSL .. scene_hit.GetGLSL(BINDING_HIT) .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, ]] .. (
				ddgi.HALF_PRECISION_RAYS and
				"rgba16f" or
				"rgba32f"
			) .. [[) uniform writeonly image2D out_ray;
			layout(set = 0, binding = ]] .. BINDING_RAY_HITS .. [[) readonly buffer DDGIRayHits {
				uvec4 ddgi_hits[];
			};
		]] .. light_grid.GetGLSL(BINDING_LIGHT_GRID) .. ddgi.GetMaterialDeclarationsGLSL(BINDING_MATERIALS) .. ddgi.GetEmitterDeclarationsGLSL(BINDING_EMITTERS),
		shader = "#define DDGI_UNSCALED\n" .. ddgi.GetHitDefinesGLSL() .. common_glsl() .. scene_lights.GetLightGLSLCode() .. ddgi.GetEmitterGLSL() .. ddgi.GetMaterialGLSL() .. ddgi.GetHitAlbedoGLSL() .. clouds.GetShadowGLSL("ddgi_data") .. (
				VISIBILITY_RAYS and
				glass_light.GetGLSL("ddgi_scene") or
				glass_light.GetStubGLSL()
			) .. [[

			void store_ray(ivec2 pos, vec4 ray) {
				imageStore(out_ray, pos, vec4(min(ray.rgb, vec3(DDGI_RAY_MAX)), ray.a));
			}

			vec3 ddgi_direct_light(vec3 P, vec3 N, bool sun_visible, float radius, vec4 u) {
				vec3 L = normalize(ddgi_data.ddgi_sun_direction.xyz);
				float NoL = max(dot(N, L), 0.0);
				vec3 direct = vec3(0.0);

				if (RT_HIT_SUN != 0 && sun_visible) {
					float fog_altitude = ]] .. string.format("%.17g", atmosphere.SEA_LEVEL_EYE_HEIGHT) .. [[ + P.y * 0.001;
					float fog = ddgi_ground_fog_sun_transmittance(fog_altitude, L.y, ddgi_data.ddgi_ground_fog.x, ddgi_data.ddgi_ground_fog.y);
					direct += ddgi_data.ddgi_sun_radiance.rgb * (NoL / 3.14159265359) * get_cloud_shadow(P) * fog;

					if (ddgi_data.glass_light != 0) direct *= get_glass_light(P + N * 0.02, L, ddgi_data.ddgi_max_distance, 0.0);
				}

				#if RT_HIT_LIGHTS == 0
				return direct;
				#endif

				float total = 0.0;
				vec3 picked_light[DDGI_LIGHT_SAMPLES];
				vec4 picked_ray[DDGI_LIGHT_SAMPLES];
				float picked_weight[DDGI_LIGHT_SAMPLES];

				for (int k = 0; k < DDGI_LIGHT_SAMPLES; k++) {
					picked_weight[k] = 0.0;
				}

				int light_cell = light_grid_cell(P);

				for (int w = 0; w < light_grid_words(ddgi_data.light_count); w++) {
				uint light_bits = light_grid_word(light_cell, w, ddgi_data.light_count);

				while (light_bits != 0u) {
					int i = w * 32 + findLSB(light_bits);
					light_bits &= light_bits - 1u;
					lights_t light = ddgi_data.lights[i];

					if (get_light_type(light) == 0) continue;

					vec3 light_to_surface;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, P, light_to_surface, attenuation)) continue;

					float light_NoL = max(dot(N, light_to_surface), 0.0);

					if (light_NoL <= 0.0) continue;

					vec3 to_light = light.position.xyz - P;
					float light_dist = length(to_light);
					attenuation *= get_light_falloff(light, light_dist) / max(get_light_falloff(light, max(light_dist, radius)), 0.0025);
					vec3 light_radiance = light.color.rgb * light.color.a * attenuation * (light_NoL / 3.14159265359);
					float weight = luminance(light_radiance);

					if (weight <= 0.0) continue;

					total += weight;
					float p = weight / total;

					for (int k = 0; k < DDGI_LIGHT_SAMPLES; k++) {
						if (u[k] < p) {
							picked_light[k] = light_radiance;
							picked_ray[k] = vec4(light_to_surface, dot(to_light, light_to_surface));
							picked_weight[k] = weight;
							u[k] /= p;
						} else {
							u[k] = (u[k] - p) / (1.0 - p);
						}
					}
				}
				}

				for (int k = 0; k < DDGI_LIGHT_SAMPLES; k++) {
					if (picked_weight[k] <= 0.0) continue;

					float shadow_distance = max(picked_ray[k].w - DDGI_SHADOW_OFFSET, 0.0);
					#if defined(DDGI_VISIBILITY_RAYS) && RT_HIT_SHADOWS
					rayQueryEXT query;
					rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, P, 0.0, picked_ray[k].xyz, shadow_distance);

					while (rayQueryProceedEXT(query)) {
						if (ddgi_materials[scene_instance_material(uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false)))].glass == 0) rayQueryConfirmIntersectionEXT(query);
					}

					bool visible = rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
					#else
					bool visible = true;
					#endif

					if (visible) {
						vec3 sample_light = picked_light[k];

						if (ddgi_data.glass_light != 0) sample_light *= get_glass_light(P, picked_ray[k].xyz, shadow_distance, 0.0);

						direct += sample_light * (total / (picked_weight[k] * float(DDGI_LIGHT_SAMPLES)));
					}
				}

				return direct;
			}

			void main() {
				ivec2 pos = get_screen_pos().yx;
				ivec2 size = imageSize(out_ray);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				uint ray = uint(pos.x % DDGI_RAY_STRIDE);
				int c = pos.x / DDGI_RAY_STRIDE;
				int probe = pos.y;

				if ((ddgi_data.ddgi_update_mask & (1 << c)) == 0 || probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				ivec3 world = ddgi_world_from_slot(slot, c);

				if (ddgi_probe_is_idle(slot, world, probe, c)) return;

				vec3 origin = ddgi_probe_origin(slot, c, world);
				uint hit_index = uint(probe + DDGI_P * DDGI_P * DDGI_P * c) * uint(DDGI_RAY_STRIDE) + ray;

				if (ray >= uint(DDGI_RAYS)) {
					uvec4 hit = ddgi_hits[hit_index];
					float weight = uintBitsToFloat(hit.x);
					vec4 result = vec4(0.0);

					if (ddgi_data.ddgi_rt_ready != 0 && weight > 0.0) {
						int emitter_index = int(hit.y & 0x03FFFFFFu);
						uint emitter_instance = ddgi_emitter_instance(emitter_index);
						uint emitter_triangle = ddgi_emitter_triangle(emitter_index) & ~DDGI_EMITTER_DOUBLE_SIDED;
						scene_triangle tri = scene_hit_tri(emitter_instance, emitter_triangle);
						vec4 u = ddgi_emitter_random(hit_index, uint(ddgi_data.ddgi_frame), hit.y >> 26u);
						vec3 point = ddgi_emitter_point(tri, u.yz);
						vec3 dir = normalize(point - origin);
						vec3 emission = ddgi_emission(tri, ddgi_hit_albedo(ddgi_materials[tri.material], point, emitter_instance, emitter_triangle));
						float emissive_luma = luminance(ddgi_materials[tri.material].emissive);
						vec3 estimate = emission / emissive_luma * weight;
						if (ddgi_data.glass_light != 0) estimate *= get_glass_light(origin, dir, length(point - origin), 0.0);

						result = vec4(estimate / (float(DDGI_EMITTER_SAMPLES) * 3.14159265359), ddgi_pack_direction(dir));
					}

					store_ray(pos, result);
					return;
				}

				ivec2 tile = ddgi_tile(slot, c);
				vec3 dir = ddgi_ray(ray, tile, ddgi_guide_valid(tile, world, c));

				if (ddgi_data.ddgi_rt_ready == 0) {
					store_ray(pos, vec4(ddgi_sky(dir), DDGI_MISS_DISTANCE));
					return;
				}

				uvec4 hit = ddgi_hits[hit_index];
				float t = uintBitsToFloat(hit.x);
				vec3 glass = vec3(1.0);

				if (ddgi_data.glass_light != 0) glass = get_glass_light(origin, dir, t < 0.0 ? ddgi_data.ddgi_max_distance : t, 0.0);

				if (t < 0.0) {
					store_ray(pos, vec4(ddgi_sky(dir) * glass, DDGI_MISS_DISTANCE * mix(0.5, 1.0, luminance(glass))));
					return;
				}

				scene_triangle tri = scene_hit_tri(hit.y, hit.z);
				ddgi_material material = ddgi_materials[tri.material];
				vec3 N = -tri.normal;

				if (dot(dir, N) > 0.0) {
					if (material.double_sided == 0) {
						store_ray(pos, vec4(0.0, 0.0, 0.0, -DDGI_BACKFACE_SCALE * t));
						return;
					}

					N = -N;
				}

				vec3 P = origin + dir * t;
				vec3 albedo = ddgi_hit_albedo(material, P, hit.y, hit.z) * ddgi_bounce_share(material);
				vec3 surface = P + N * 0.02;
				float light_radius = ddgi_data.ddgi_light_radius * ddgi_spacing(c);
				vec4 u = ddgi_emitter_random(hit_index, uint(ddgi_data.ddgi_frame), 0u);
				vec3 radiance = albedo * ddgi_direct_light(surface, N, hit.w != 0u, light_radius, u);

				float weight;
				#if RT_HIT_PROBES
				ddgi_contrast_reference = luminance(textureLod(TEXTURE(ddgi_data.ddgi_irradiance_tex), ddgi_atlas_uv(slot, c, N, DDGI_IRRADIANCE_TEXELS), 0.0).rgb);
				radiance += albedo * ddgi_sample_irradiance(P, N, N, -dir, false, DDGI_CONTRAST_VISIBILITY_RAYS, weight).rgb;
				#endif

				store_ray(pos, vec4(radiance * glass, t));
			}
		]],
	}
end

local function pass_update(name, texels, integrate)
	local color_formats = {{integrate.atlas_format[1], {name, "rgba"}}}
	local storage_images = {
		{binding_index = BINDING_OUTPUT, dst_stage = "compute"},
		{
			binding_index = BINDING_STATE,
			get_texture = function(self)
				if not self.owned_textures then
					local state = Texture.New{
						width = P * P,
						height = P * CASCADES,
						format = "r16g16b16a16_sfloat",
						image = {usage = {"storage", "sampled"}},
					}
					state:SetDebugName(name .. " probe state")
					self.owned_textures = {state}
				end

				return self.owned_textures[1]
			end,
			dst_stage = "compute",
		},
	}
	local declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, ]] .. integrate.atlas_format[2] .. [[) uniform image2D atlas;
		layout(set = 0, binding = ]] .. BINDING_STATE .. [[, rgba16f) uniform image2D state_atlas;
	]]
	return {
		name = name,
		ComputePass = true,
		ColorFormat = color_formats,
		FramebufferSize = {x = P * P * texels, y = P * texels * CASCADES},
		framebuffer_count = 1,
		LocalSize = {x = texels, y = texels, z = 1},
		storage_images = storage_images,
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				fb.width,
				P * texels * ddgi.GetFrameState().cascade_count,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		custom_declarations = declarations,
		shader = common_glsl() .. [[
			#define TEXELS ]] .. texels .. [[

			#define DDGI_CHANGE_MARGIN 1.15

			shared vec4 s_ray[DDGI_RAYS];
			shared vec3 s_dir[DDGI_RAYS];
			shared float s_q[DDGI_RAYS];
			shared float s_mean[DDGI_RAYS];
			shared float s_keep;

			void main() {
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				ivec2 local = ivec2(gl_LocalInvocationID.xy);
				int c = tile.y / DDGI_P;
				int probe = tile.x + DDGI_P * DDGI_P * (tile.y % DDGI_P);

				if ((ddgi_data.ddgi_update_mask & (1 << c)) == 0 || probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				ivec3 world = ddgi_world_from_slot(slot, c);

				if (ddgi_probe_is_idle(slot, world, probe, c)) return;

				float spacing = ddgi_spacing(c);
				bool guided = ddgi_guide_valid(tile, world, c);

				for (int r = local.y * TEXELS + local.x; r < DDGI_RAYS; r += TEXELS * TEXELS) {
					s_ray[r] = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(r), slot, c), 0);
					s_dir[r] = ddgi_ray(uint(r), tile, guided);
					s_q[r] = ddgi_ray_q(s_dir[r], tile, guided);
					s_mean[r] = s_ray[r].a < 0.0 ? 0.0 : sqrt(luminance(s_ray[r].rgb)) * s_q[r];
				}

				barrier();
				vec3 texel_dir = ddgi_texel_direction(local, TEXELS);
				vec4 sum = vec4(0.0);
				float weight_sum = 0.0;
				]] .. (
				integrate.declare or
				""
			) .. [[

				for (int r = 0; r < DDGI_RAYS; r++) {
					vec4 ray = s_ray[r];
					]] .. integrate.loop .. [[
				}

				]] .. (
				integrate.finish or
				""
			) .. [[

				ivec2 texel = tile * TEXELS + local;
				vec4 result = weight_sum > 0.0 ? sum / weight_sum : vec4(0.0);
				]] .. (
				integrate.result or
				""
			) .. [[

				if (local == ivec2(0)) {
					vec4 data = ddgi_probe_data(slot, c);
					bool current = !ddgi_cascade_reset(c) && ddgi_probe_is_current(data, world) && !ddgi_probe_disabled(data) && !ddgi_probe_moved(data);
					vec4 state = current ? imageLoad(state_atlas, tile) : vec4(0.0);
					float probe_mean = 0.0;
					float probe_weight = 0.0;

					for (int r = 0; r < DDGI_RAYS; r++) {
						probe_mean += s_mean[r];
						probe_weight += s_ray[r].a < 0.0 ? 0.0 : s_q[r];
					}

					probe_mean /= max(probe_weight, 1e-4);
					float change = abs(state.z);
					float direction = probe_mean > state.y ? 1.0 : -1.0;
					float side = probe_mean > state.y * DDGI_CHANGE_MARGIN ? 1.0 : (probe_mean < state.y / DDGI_CHANGE_MARGIN ? -1.0 : 0.0);
					float average = state.w;
					state.z = state.x > 0.0 ? mix(side, state.z, 0.8) : 0.0;
					state.y = state.x > 0.0 ? (direction > 0.0 ? state.y + 0.01 * max(average, 1e-3) : state.y * 0.99) : probe_mean;
					state.w = state.x > 0.0 ? mix(probe_mean, average, 0.97) : probe_mean;
					float keep = ddgi_data.ddgi_cascade_update[c].x;
					keep = mix(keep, pow(keep, ddgi_data.ddgi_change_power), clamp((change - 0.6) / 0.3, 0.0, 1.0));
					if (ddgi_data.ddgi_cascade_update[c].y > 0.0) keep = min(keep, 0.4);
					s_keep = min(keep, state.x / (state.x + 1.0));
					state.x = min(state.x + 1.0, 1024.0);
					imageStore(state_atlas, tile, state);
				}

				barrier();
				imageStore(atlas, texel, mix(result, imageLoad(atlas, texel), s_keep));
			}
		]],
	}
end

local IRRADIANCE_INTEGRATE = {
	atlas_format = {"r16g16b16a16_sfloat", "rgba16f"},
	declare = [[

		float ray_cap = 1e30;

		if (ddgi_data.ddgi_ray_clamp > 0.0) {
			float ray_sum = 0.0;
			float ray_count = 0.0;
			float top_luma = 0.0;
			float top_q = 0.0;

			for (int r = 0; r < DDGI_RAYS; r++) {
				if (s_ray[r].a < 0.0) continue;

				float l = luminance(s_ray[r].rgb);
				ray_sum += l * s_q[r];
				ray_count += s_q[r];

				if (l > top_luma) {
					top_luma = l;
					top_q = s_q[r];
				}
			}

			ray_cap = ddgi_data.ddgi_ray_clamp * max((ray_sum - top_luma * top_q) / max(ray_count - top_q, 1e-4), 1e-4);
		}
	]],
	loop = [[
		if (ray.a < 0.0) continue;

		float w = max(0.0, dot(texel_dir, s_dir[r])) * s_q[r];

		if (w <= 0.0) continue;

		vec3 radiance = ray.rgb;
		float radiance_luma = luminance(radiance);

		if (radiance_luma > ray_cap) radiance *= ray_cap / radiance_luma;

		sum += vec4(radiance * w, ray.a >= DDGI_MISS_DISTANCE * 0.5 ? w * (ray.a / DDGI_MISS_DISTANCE * 2.0 - 1.0) : 0.0);
		weight_sum += w;
	]],
	result = [[
		for (int k = 0; k < DDGI_EMITTER_SAMPLES; k++) {
			vec4 emitter = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(DDGI_RAYS + k), slot, c), 0);
			result.rgb += emitter.rgb * max(0.0, dot(texel_dir, ddgi_unpack_direction(emitter.a)));
		}
	]],
}
local DISTANCE_INTEGRATE = {
	atlas_format = {"r16g16_sfloat", "rg16f"},
	declare = [[
		float min_cos = exp2(-16.6 / ddgi_data.ddgi_distance_exponent);
	]],
	loop = [[
		float cos_angle = dot(texel_dir, s_dir[r]);

		if (cos_angle < min_cos) continue;

		float w = pow(cos_angle, ddgi_data.ddgi_distance_exponent) * s_q[r];

		float d = min(abs(ray.a), spacing * 2.6);
		sum += vec4(d, d * d, 0.0, 0.0) * w;
		weight_sum += w;
	]],
}

local function pass_probe_data()
	return {
		name = "ddgi_probe_data",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"ddgi_probe_data", "rgba"}}},
		FramebufferSize = {x = P * P, y = P * CASCADES},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				dst_stage = ddgi.RTSupported() and {"compute", "ray_tracing_shader_khr"} or "compute",
			},
		},
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				fb.width,
				P * ddgi.GetFrameState().cascade_count,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform image2D out_data;
		]],
		shader = common_glsl() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_data);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				int c = pos.y / DDGI_P;
				int probe = pos.x + DDGI_P * DDGI_P * (pos.y % DDGI_P);

				if ((ddgi_data.ddgi_update_mask & (1 << c)) == 0 || probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				ivec3 world = ddgi_world_from_slot(slot, c);
				vec4 previous = imageLoad(out_data, pos);

				if (ddgi_probe_idle(previous.w, !ddgi_cascade_reset(c) && ddgi_probe_is_current(previous, world), probe, c, uint(ddgi_data.ddgi_frame))) return;

				float spacing = ddgi_spacing(c);
				vec3 offset = !ddgi_cascade_reset(c) && ddgi_probe_is_current(previous, world) ? (previous.xyz - vec3(world)) * spacing : vec3(0.0);
				float backfaces = 0.0;
				float closest_back = 1e30;
				vec3 closest_back_dir = vec3(0.0);
				float short_back = 0.0;
				float min_distance = ddgi_data.ddgi_relocation_distance * spacing;
				ivec2 tile = ddgi_tile(slot, c);

				for (int r = 0; r < ddgi_data.ddgi_uniform_rays; r++) {
					float a = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(r), slot, c), 0).a;

					if (a < 0.0) {
						backfaces += 1.0;
						float d = -a / DDGI_BACKFACE_SCALE;

						if (d < min_distance * 2.0) short_back += 1.0;

						if (d < closest_back) {
							closest_back = d;
							closest_back_dir = ddgi_ray(uint(r), tile, false);
						}
					}
				}

				bool settled = !ddgi_cascade_reset(c) && ddgi_probe_is_current(previous, world) && !ddgi_probe_moved(previous);
				float backface_fraction = backfaces / float(ddgi_data.ddgi_uniform_rays);
				float smoothed = settled ? mix(backface_fraction, ddgi_probe_backfaces(previous), 0.8) : backface_fraction;
				bool disabled = smoothed > ddgi_data.ddgi_backface_threshold * (settled && ddgi_probe_disabled(previous) ? 0.6 : 1.0);
				vec3 previous_offset = offset;
				vec3 moved = offset;

				if (min_distance > 0.0 && disabled && short_back < backfaces * 0.8) {
					vec3 axis = abs(closest_back_dir);
					vec3 move_dir = sign(closest_back_dir) * vec3(axis.x >= axis.y && axis.x >= axis.z, axis.y > axis.x && axis.y >= axis.z, axis.z > axis.x && axis.z > axis.y);
					moved += move_dir * (closest_back + min_distance * 0.5);
				}

				if (min_distance <= 0.0) {
					offset = vec3(0.0);
				} else if (all(lessThan(abs(moved), vec3(ddgi_data.ddgi_max_offset * spacing)))) {
					offset = moved;
				}

				bool relocated = dot(offset - previous_offset, offset - previous_offset) > 1e-8 * spacing * spacing;
				imageStore(out_data, pos, vec4(vec3(world) + offset / spacing, 1.0 + smoothed + (relocated ? 2.0 : 0.0) + (disabled ? 4.0 : 0.0)));
			}
		]],
	}
end

local function pass_guide()
	return {
		name = "ddgi_guide",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"ddgi_guide", "rgba"}}},
		FramebufferSize = {x = P * P * 8, y = P * 8 * CASCADES},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				dst_stage = ddgi.RTSupported() and {"compute", "ray_tracing_shader_khr"} or "compute",
			},
		},
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				fb.width,
				P * 8 * ddgi.GetFrameState().cascade_count,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform image2D guide_atlas;
		]],
		shader = [[
			#define DDGI_GUIDE_FETCH(texel) imageLoad(guide_atlas, texel)
		]] .. common_glsl() .. [[
			shared vec4 s_ray[DDGI_RAYS];
			shared vec3 s_dir[DDGI_RAYS];
			shared float s_q[DDGI_RAYS];
			shared int s_cell[DDGI_RAYS];
			shared vec2 s_inner[DDGI_RAYS];
			shared float s_value[DDGI_GUIDE_CELLS];
			shared float s_cdf[DDGI_GUIDE_CELLS];
			shared float s_floor;
			shared float s_total;

			void main() {
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				ivec2 local = ivec2(gl_LocalInvocationID.xy);
				int c = tile.y / DDGI_P;
				int probe = tile.x + DDGI_P * DDGI_P * (tile.y % DDGI_P);

				if ((ddgi_data.ddgi_update_mask & (1 << c)) == 0 || probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				ivec3 world = ddgi_world_from_slot(slot, c);
				bool guided = ddgi_guide_valid(tile, world, c);
				bool has_history = guided && !ddgi_cascade_reset(c);
				int cell = local.y * DDGI_GUIDE_TEXELS + local.x;
				vec4 previous_texel = imageLoad(guide_atlas, tile * DDGI_GUIDE_TEXELS + local);
				float previous = previous_texel.r;

				for (int r = cell; r < DDGI_RAYS; r += DDGI_GUIDE_CELLS) {
					s_ray[r] = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(r), slot, c), 0);
					s_dir[r] = ddgi_ray(uint(r), tile, guided);
					s_q[r] = ddgi_ray_q(s_dir[r], tile, guided);
					vec2 scaled = (oct_encode(s_dir[r]) * 0.5 + 0.5) * float(DDGI_GUIDE_TEXELS);
					ivec2 ray_cell = clamp(ivec2(scaled), ivec2(0), ivec2(DDGI_GUIDE_TEXELS - 1));
					s_cell[r] = ray_cell.y * DDGI_GUIDE_TEXELS + ray_cell.x;
					s_inner[r] = clamp(scaled - vec2(ray_cell), 0.0, 1.0);
				}

				barrier();
				float sum = 0.0;
				float weight = 0.0;
				float all_sum = 0.0;
				float all_weight = 0.0;
				float peak = 0.0;
				vec2 spot_sum = vec2(0.0);
				float spot_weight = 0.0;

				for (int r = 0; r < DDGI_RAYS; r++) {
					float luma = luminance(s_ray[r].rgb);
					all_sum += luma * s_q[r];
					all_weight += s_q[r];

					if (s_cell[r] == cell) {
						sum += luma * s_q[r];
						weight += s_q[r];
						peak = max(peak, luma);
						spot_sum += s_inner[r] * luma * luma;
						spot_weight += luma * luma;
					}
				}

				float value = weight > 0.0 ? sum / weight : (has_history ? previous : all_sum / all_weight);

				if (weight > 0.0 && has_history) value = mix(value, previous, DDGI_GUIDE_HISTORY);

				vec3 aim = has_history ? ddgi_guide_aim_stored(previous_texel.a) : vec3(0.5, 0.5, 0.0);

				if (weight > 0.0) {
					float ratio = peak / max(value, 1e-6);

					if (ratio > 3.0 && spot_weight > 0.0) {
						vec2 spot = spot_sum / spot_weight;
						aim.xy = aim.z > 0.0 ? mix(spot, aim.xy, 0.7) : spot;
					}

					aim.z = has_history ? mix(clamp((ratio - 3.0) / 9.0, 0.0, 1.0), aim.z, 0.9) : clamp((ratio - 3.0) / 9.0, 0.0, 1.0);
				}

				uvec3 aim_bits = uvec3(aim * 255.0 + 0.5);
				float stored_aim = float(aim_bits.x | (aim_bits.y << 8u) | (aim_bits.z << 16u));
				s_value[cell] = value;
				barrier();

				if (cell == 0) {
					float total = 0.0;

					for (int i = 0; i < DDGI_GUIDE_CELLS; i++) total += s_value[i];

					s_floor = total / float(DDGI_GUIDE_CELLS) * 0.25 + 1e-6;
					s_total = total + s_floor * float(DDGI_GUIDE_CELLS);
					float running = 0.0;

					for (int i = 0; i < DDGI_GUIDE_CELLS; i++) {
						running += s_value[i] + s_floor;
						s_cdf[i] = running / s_total;
					}

					s_cdf[DDGI_GUIDE_CELLS - 1] = 1.0;
				}

				barrier();
				imageStore(
					guide_atlas,
					tile * DDGI_GUIDE_TEXELS + local,
					vec4(value, (value + s_floor) / s_total, cell == DDGI_GUIDE_STAMP_CELL ? ddgi_guide_stamp(world, c) : s_cdf[cell], stored_aim)
				);
			}
		]],
	}
end

local function pass_probe_debug()
	return {
		name = "ddgi_probe_debug",
		lazy_framebuffers = true,
		is_enabled = function()
			return ddgi.GetDebugProbes() ~= 0
		end,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ddgi_probe_debug", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = {"compute", "fragment"}}},
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			if ddgi.GetDebugProbes() == 0 then return end

			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, fb.width, fb.height, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = common_glsl() .. post_source.GetPreExposureGLSL("ddgi_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("ddgi_data") .. [[
			vec2 in_uv;
		]] .. screen_reconstruct.GetWorldRayGLSL("ddgi_data") .. [[

			float ddgi_capsule(vec3 ro, vec3 rd, vec3 pa, vec3 pb, float r) {
				vec3 ba = pb - pa;
				vec3 oa = ro - pa;
				float baba = dot(ba, ba);
				float bard = dot(ba, rd);
				float baoa = dot(ba, oa);
				float a = baba - bard * bard;
				float b = baba * dot(rd, oa) - baoa * bard;
				float c = baba * dot(oa, oa) - baoa * baoa - r * r * baba;
				float h = b * b - a * c;

				if (h < 0.0 || a <= 0.0) return -1.0;

				float t = (-b - sqrt(h)) / a;
				float y = baoa + t * bard;
				return y > 0.0 && y < baba ? t : -1.0;
			}

			float ddgi_sphere(vec3 ro, vec3 rd, vec3 center, float r) {
				vec3 oc = ro - center;
				float b = dot(oc, rd);
				float h = b * b - dot(oc, oc) + r * r;
				return h < 0.0 ? -1.0 : -b - sqrt(h);
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				in_uv = get_screen_uv(pos, size);
				float depth = gbuffer_depth(in_uv);
				vec3 O = ddgi_data.camera_position.xyz;
				vec3 D = get_world_ray();
				int c = min(ddgi_data.ddgi_debug_cascade, ddgi_data.ddgi_cascade_count - 1);
				float spacing = ddgi_spacing(c);
				float best = depth <= 0.0 ? 1e9 : length(get_world_pos(in_uv, depth) - O);
				float radius = spacing * 0.12;
				float exposure = get_pre_exposure() * ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[;
				vec3 inv = 1.0 / (D + vec3(equal(D, vec3(0.0))) * 1e-7);
				vec3 box_min = vec3(ddgi_volume_base(c) - 1) * spacing;
				vec3 box_max = vec3(ddgi_volume_base(c) + ddgi_volume_size(c)) * spacing;
				vec3 ta = (box_min - O) * inv;
				vec3 tb = (box_max - O) * inv;
				vec3 t_near = min(ta, tb);
				vec3 t_far = max(ta, tb);
				float t = max(max(t_near.x, max(t_near.y, t_near.z)), 0.0);
				float t_exit = min(min(t_far.x, min(t_far.y, t_far.z)), best);
				vec4 result = vec4(0.0);

				if (t < t_exit) {
					vec3 o = O / spacing;
					vec3 d = D / spacing;
					ivec3 cell = ivec3(floor(o + d * (t + 1e-4)));
					ivec3 step_dir = ivec3(greaterThanEqual(D, vec3(0.0))) * 2 - 1;
					vec3 t_delta = abs(inv) * spacing;
					vec3 t_next = (vec3(cell) + max(vec3(step_dir), vec3(0.0)) - o) * spacing * inv;
					ivec3 volume_min = ddgi_volume_base(c);
					ivec3 volume_max = volume_min + ddgi_volume_size(c) - 1;
					vec3 hit_color = vec3(0.0);

					ivec3 n = ddgi_volume_size(c);

					for (int i = 0; i < (n.x + n.y + n.z) * 2 && t < min(t_exit, best); i++) {
						for (int corner = 0; corner < 8; corner++) {
							ivec3 world = cell + ivec3(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1);

							if (any(lessThan(world, volume_min)) || any(greaterThan(world, volume_max))) continue;

							ivec3 slot = ddgi_slot(world, c);
							vec4 data = ddgi_probe_data(slot, c);

							if (!ddgi_probe_is_current(data, world)) continue;

							vec3 center = data.xyz * spacing;
							vec3 grid = vec3(world) * spacing;
							bool disabled = ddgi_probe_disabled(data);
							float hit = ddgi_sphere(O, D, center, radius);

							if (hit > 0.0 && hit < best) {
								best = hit;
								vec3 n = normalize(O + D * hit - center);

								if (ddgi_data.ddgi_debug_probes == 2) {
									float mean = texture(TEXTURE(ddgi_data.ddgi_distance_tex), ddgi_atlas_uv(slot, c, n, DDGI_DISTANCE_TEXELS)).r;
									hit_color = vec3(mean / (spacing * 2.6));
								} else {
									vec3 shown = texture(TEXTURE(ddgi_data.ddgi_irradiance_tex), ddgi_atlas_uv(slot, c, n, DDGI_IRRADIANCE_TEXELS)).rgb / 3.14159265359 * exposure;
									hit_color = shown / (1.0 + shown);
								}

								if (disabled) hit_color = vec3(0.8, 0.0, 0.0);
							}

							if (distance(center, grid) > radius) {
								vec3 marker = vec3(0.7, 0.42, 0.0);
								hit = ddgi_capsule(O, D, grid, center, radius * 0.15);

								if (hit > 0.0 && hit < best) {
									best = hit;
									hit_color = marker;
								}

								hit = ddgi_sphere(O, D, grid, radius * 0.3);

								if (hit > 0.0 && hit < best) {
									best = hit;
									hit_color = marker;
								}
							}
						}

						if (t_next.x < t_next.y && t_next.x < t_next.z) {
							t = t_next.x;
							t_next.x += t_delta.x;
							cell.x += step_dir.x;
						} else if (t_next.y < t_next.z) {
							t = t_next.y;
							t_next.y += t_delta.y;
							cell.y += step_dir.y;
						} else {
							t = t_next.z;
							t_next.z += t_delta.z;
							cell.z += step_dir.z;
						}
					}

					if (best < 1e9 && (depth <= 0.0 || best < length(get_world_pos(in_uv, depth) - O) - 1e-4)) {
						result = vec4(hit_color * (0.8 * ddgi_data.ddgi_debug_scale / ]] .. string.format("%.1f", post_source.PRE_EXPOSURE_HEADROOM) .. [[), 1.0);
					}
				}

				imageStore(out_color, pos, result);
			}
		]],
	}
end

local function pass_scene_debug()
	local rays = VISIBILITY_RAYS and ddgi.RTSupported()
	local alpha_test = rays and ddgi.ALPHA_TEST
	local uvs = alpha_test or ddgi.AreHitTexturesOn()
	local storage_buffers = {
		{binding_index = BINDING_MATERIALS},
	}
	local trace_glsl

	if rays then
		trace_glsl = ddgi.SCENE_FLAGS_GLSL .. (
				alpha_test and
				ddgi.GetAlphaTestGLSL() or
				""
			) .. [[
			bool debug_trace(vec3 O, vec3 D, out ddgi_debug_hit hit) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, ddgi_scene, DDGI_SCENE_FLAGS, 0xFF, O, 0.0, D, ddgi_data.ddgi_max_distance);

				while (rayQueryProceedEXT(query)) {
		]] .. (
				alpha_test and
				[[
					uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));

					if (ddgi_materials[scene_instance_material(candidate)].refractive == 0 && ddgi_alpha_passes(candidate, uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, false)), rayQueryGetIntersectionBarycentricsEXT(query, false))) rayQueryConfirmIntersectionEXT(query);
		]] or
				""
			) .. [[
				}

				if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) return false;

				hit.distance = rayQueryGetIntersectionTEXT(query, true);
				hit.position = O + D * hit.distance;
				hit.instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				hit.primitive = uint(rayQueryGetIntersectionPrimitiveIndexEXT(query, true));
				return true;
			}
		]]
	else
		trace_glsl = [[
			bool debug_trace(vec3 O, vec3 D, out ddgi_debug_hit hit) {
				return false;
			}
		]]
	end

	return {
		name = "ddgi_scene_debug",
		lazy_framebuffers = true,
		is_enabled = function()
			return ddgi.GetDebugSceneMode() ~= 0
		end,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ddgi_scene_debug", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = {"compute", "fragment"}}},
		present_texture = function()
			if ddgi.GetDebugSceneMode() == 0 then return nil end

			return render3d.pipelines.ddgi_scene_debug:GetFramebuffer(1):GetAttachment(1)
		end,
		storage_buffers = storage_buffers,
		descriptor_sets = SCENE_DESCRIPTOR,
		uniform_buffers = {data_uniform()},
		on_pre_draw = function(self, cmd, frame, desc)
			if ddgi.GetDebugSceneMode() == 0 then return end

			local materials = ddgi.WriteMaterialBuffer(self)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_MATERIALS, 0, materials, materials:GetSize())
			scene_hit.Bind(self, desc, BINDING_HIT)

			if rays then
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, scene_rt.GetTLAS(cmd))
			end
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			if ddgi.GetDebugSceneMode() == 0 then return end

			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, fb.width, fb.height, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = (
				rays and
				SCENE_GLSL or
				""
			) .. scene_hit.GetGLSL(BINDING_HIT) .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		]] .. ddgi.GetMaterialDeclarationsGLSL(BINDING_MATERIALS),
		shader = common_glsl() .. [[
			struct ddgi_debug_hit {
				vec3 position;
				float distance;
				uint instance;
				uint primitive;
			};
		]] .. ddgi.GetMaterialGLSL() .. ddgi.GetHitAlbedoGLSL() .. trace_glsl .. screen_reconstruct.GetWorldPosFromUVGLSL("ddgi_data") .. [[
			vec2 in_uv;
		]] .. screen_reconstruct.GetWorldRayGLSL("ddgi_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				in_uv = get_screen_uv(pos, size);
				vec3 O = ddgi_data.camera_position.xyz;
				vec3 D = get_world_ray();
				vec3 color = vec3(0.01, 0.015, 0.03);
				ddgi_debug_hit hit;

				if (ddgi_data.ddgi_rt_ready != 0 && debug_trace(O, D, hit)) {
					scene_triangle tri = scene_hit_tri(hit.instance, hit.primitive);
					ddgi_material material = ddgi_materials[tri.material];
					vec3 N = -tri.normal;
					bool back = dot(D, N) > 0.0;

					if (back) N = -N;

					float facing = 0.3 + 0.7 * max(dot(N, -D), 0.0);

					if (back && material.double_sided == 0) {
						color = vec3(0.8, 0.0, 0.0) * facing;
					} else if (ddgi_data.ddgi_debug_scene == 2) {
						color = (N * 0.5 + 0.5) * facing;
					} else if (ddgi_data.ddgi_debug_scene == 3) {
						color = vec3(1.0 / (1.0 + hit.distance / (ddgi_spacing(0) * 4.0)));
					} else {
						color = ddgi_hit_albedo(material, hit.position, hit.instance, hit.primitive) * facing;
					}
				}

				color = clamp(color * ddgi_data.ddgi_debug_scale, 0.0, 1.0);

				if (ddgi_data.ddgi_debug_manual_gamma == 1) {
					color = mix(color * 12.92, 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, color));
				}

				imageStore(out_color, pos, vec4(color, 1.0));
			}
		]],
	}
end

local function pass_resolve()
	return {
		name = "ddgi_resolve",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"ddgi_screen", "rgba"}},
			{"r16g16b16a16_sfloat", {"ddgi_screen_geometry", "rgba"}},
			{"r16g16b16a16_sfloat", {"ddgi_screen_specular", "rgba"}},
		},
		framebuffer_count = 1,
		scale = function()
			return ddgi.GetResolveScale()
		end,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {
			{binding_index = BINDING_OUTPUT, dst_stage = {"compute", "fragment"}},
			{
				binding_index = BINDING_SCREEN_GEOMETRY,
				attachment = 2,
				dst_stage = {"compute", "fragment"},
			},
			{
				binding_index = BINDING_SCREEN_SPECULAR,
				attachment = 3,
				dst_stage = {"compute", "fragment"},
			},
		},
		descriptor_sets = VISIBILITY_RAYS and SCENE_DESCRIPTOR or nil,
		uniform_buffers = {data_uniform()},
		on_pre_draw = VISIBILITY_RAYS and
			function(self, cmd, frame, desc)
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, ddgi.GetFrameState().tlas)
			end or
			nil,
		custom_declarations = SCENE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_GEOMETRY .. [[, rgba16f) uniform writeonly image2D out_geometry;
 layout(set = 0, binding = ]] .. BINDING_SCREEN_SPECULAR .. [[, rgba16f) uniform writeonly image2D out_specular;
 ]],
		shader = common_glsl() .. screen_reconstruct.GetWorldPosFromUVGLSL("ddgi_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 depth_size = textureSize(TEXTURE(ddgi_data.depth_tex), 0);
				mat4 inv_projection = ddgi_data.inv_projection;
				vec3 position_sum = vec3(0.0);
				vec3 normal_sum = vec3(0.0);
				vec3 bent_sum = vec3(0.0);
				float depth_sum = 0.0;
				float roughness_sum = 0.0;
				float count = 0.0;

				for (int tap = 0; tap < 4; tap++) {
					vec2 offset = vec2(tap & 1, tap >> 1) * 0.5 - 0.25;
					vec2 tap_uv = (vec2(pos) + 0.5 + offset) / vec2(size);
					ivec2 pixel = min(ivec2(tap_uv * vec2(depth_size)), depth_size - 1);
					float depth = gbuffer_depth(pixel);

					if (depth <= 0.0) continue;

					vec2 uv = (vec2(pixel) + 0.5) / vec2(depth_size);
					vec3 N = normalize(gbuffer_normal(pixel));
					normal_sum += N;
					bent_sum += N;

					if (ddgi_data.ddgi_bent_normal_tex >= 0) {
						vec3 bent = texture(TEXTURE(ddgi_data.ddgi_bent_normal_tex), uv).xyz;
						float bent_length = length(bent);

						if (bent_length > 0.1) bent_sum += bent / bent_length - N;
					}

					depth_sum += -(inv_projection[2][2] * depth + inv_projection[3][2]) / (inv_projection[2][3] * depth + inv_projection[3][3]);
					position_sum += get_world_pos(uv, depth);
					roughness_sum += sqrt(gbuffer_roughness(pixel));
					count += 1.0;
				}

				if (count == 0.0) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 1.0));
					imageStore(out_geometry, pos, vec4(0.0, 0.0, 0.0, 1e30));
					imageStore(out_specular, pos, vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec3 P = position_sum / count;
				vec3 N = normalize(normal_sum / count + 1e-6);
				vec3 L = normalize(bent_sum / count + 1e-6);
				vec3 V = normalize(ddgi_data.camera_position - P);
				float roughness = roughness_sum / count;
				imageStore(out_geometry, pos, vec4(N, depth_sum / count));
				float weight;
				vec4 gi = ddgi_sample_irradiance(P, N, L, V, ddgi_data.ddgi_smooth_blend != 0, DDGI_VISIBILITY_MIN_WEIGHT, weight);

				if (weight <= 0.0 && !ddgi_in_volume(P)) {
					gi = vec4(sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, N) * ddgi_data.ddgi_strength, 1.0);
				}

				imageStore(out_color, pos, gi);

				vec4 specular = gi;

				if (roughness > 0.25) {
					vec3 R = get_specular_dominant_direction(reflect(-V, N), N, roughness);
					specular = ddgi_sample_irradiance(P, N, R, V, ddgi_data.ddgi_smooth_blend != 0, DDGI_VISIBILITY_MIN_WEIGHT, weight);

					if (weight <= 0.0 && !ddgi_in_volume(P)) {
						specular = vec4(sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, R) * ddgi_data.ddgi_strength, 1.0);
					}
				}

				imageStore(out_specular, pos, specular);
			}
		]],
	}
end

local passes = {
	pass_shade(),
	pass_update("ddgi_irradiance", ddgi.IRRADIANCE_TEXELS, IRRADIANCE_INTEGRATE),
	pass_update("ddgi_distance", ddgi.DISTANCE_TEXELS, DISTANCE_INTEGRATE),
	pass_probe_data(),
	pass_guide(),
	pass_resolve(),
	pass_probe_debug(),
	pass_scene_debug(),
}

if ddgi.RTSupported() then table.insert(passes, 1, pass_trace()) end

return passes
