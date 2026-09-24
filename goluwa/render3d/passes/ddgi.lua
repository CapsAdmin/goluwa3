local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local light_grid = import("goluwa/render3d/light_grid.lua")
local P = ddgi.PROBES_PER_AXIS
local CASCADES = ddgi.CASCADES
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 1
local BINDING_RAY_HITS = 2
local BINDING_BVH_NODES = 3
local BINDING_BVH_TRIANGLES = 4
local BINDING_MATERIALS = 5
local BINDING_TREND = 7
local BINDING_EMITTERS = 8
local BINDING_STATE = 9
local BINDING_SCENE = 10
local BINDING_LIGHT_GRID = 11
-- Probes are checked with ray queries against the scene (ddgi.VISIBILITY_RAYS),
-- in the resolve and when shading ray hits, which would otherwise feed light
-- leaked at a hit back into the probes.
local VISIBILITY_RAYS = render.GetDevice().ray_query_supported
local SCENE_DESCRIPTOR = {
	{
		type = "acceleration_structure_khr",
		binding_index = BINDING_SCENE,
		stageFlags = "compute",
	},
}
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
	return [[
		#define saturate(x) clamp(x, 0.0, 1.0)
	]] .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. ddgi.GetCommonGLSL()
end

-- Traces every probe ray against the scene TLAS. This is a ray tracing
-- dispatch, not a compute one; the 1x1 framebuffer only satisfies ComputePass.
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
			scene_bvh.EnsureBuilt()
			local tlas = ddgi.RTSupported() and scene_bvh.EnsureRTBuilt(cmd) or nil
			state.rt_ready = tlas ~= nil
			state.tlas = tlas or VISIBILITY_RAYS and scene_bvh.GetPlaceholderTLAS(cmd) or nil

			if not tlas then return end

			local rt = ddgi.GetRTPipeline()
			local params = ddgi.WriteRTParams()
			local hits = ddgi.GetRayHitBuffer()
			rt:UpdateDescriptorSet("uniform_buffer", desc, 0, 0, params, params:GetSize())
			rt:UpdateDescriptorSet("storage_buffer", desc, 1, 0, hits, hits:GetSize())
			local emitters = ddgi.GetEmitterBuffer()
			rt:UpdateDescriptorSet(
				"storage_buffer",
				desc,
				5,
				0,
				scene_bvh.triangle_buffer,
				scene_bvh.triangle_buffer:GetSize()
			)
			rt:UpdateDescriptorSet("storage_buffer", desc, 6, 0, emitters, emitters:GetSize())
			rt:UpdateDescriptorSet(
				"storage_buffer",
				desc,
				7,
				0,
				scene_bvh.node_buffer,
				scene_bvh.node_buffer:GetSize()
			)
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
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			if not ddgi.GetFrameState().rt_ready then return end

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

-- Radiance leaving each ray's hit towards its probe: direct light and last
-- frame's probe irradiance at the hit (the infinite bounce). Emission comes
-- in through the emitter samples instead, which follow the uniform rays. One
-- texel per ray, x = ray + ray stride * cascade, y = probe slot (see
-- ddgi_ray_texel); a = hit distance, negative for a
-- back face hit (the probe is probably inside geometry) and
-- DDGI_MISS_DISTANCE for a miss.
local function pass_shade()
	return {
		name = "ddgi_shade",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"ddgi_ray_radiance", "rgba"}}},
		FramebufferSize = {x = (ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) * CASCADES, y = P ^ 3},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = "compute"}},
		storage_buffers = {
			{binding_index = BINDING_RAY_HITS},
			{binding_index = BINDING_BVH_NODES},
			{binding_index = BINDING_BVH_TRIANGLES},
			{binding_index = BINDING_MATERIALS},
			{binding_index = BINDING_EMITTERS},
			{binding_index = BINDING_LIGHT_GRID},
		},
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				(ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES) * ddgi.GetFrameState().cascade_count,
				fb.height,
				1,
				desc,
				self.dynamic_offsets
			)
		end,
		on_pre_draw = function(self, cmd, frame, desc)
			local hits = ddgi.GetRayHitBuffer()
			local materials = ddgi.WriteMaterialBuffer(self)
			local emitters = ddgi.GetEmitterBuffer()
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_RAY_HITS, 0, hits, hits:GetSize())
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_MATERIALS, 0, materials, materials:GetSize())
			light_grid.Bind(self, cmd, desc, BINDING_LIGHT_GRID)

			if VISIBILITY_RAYS then
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, ddgi.GetFrameState().tlas)
			end

			if scene_bvh.triangle_buffer then
				scene_bvh.BindBuffers(self, desc, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
			else
				-- no soup yet; the shader never reads it while rt_ready is 0
				self:UpdateDescriptorSet("storage_buffer", desc, BINDING_BVH_NODES, 0, hits, hits:GetSize())
				self:UpdateDescriptorSet("storage_buffer", desc, BINDING_BVH_TRIANGLES, 0, hits, hits:GetSize())
			end
		end,
		descriptor_sets = VISIBILITY_RAYS and SCENE_DESCRIPTOR or nil,
		custom_declarations = SCENE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform writeonly image2D out_ray;
			layout(set = 0, binding = ]] .. BINDING_RAY_HITS .. [[) readonly buffer DDGIRayHits {
				uvec2 ddgi_hits[];
			};
		]] .. light_grid.GetGLSL(BINDING_LIGHT_GRID) .. ddgi.GetMaterialDeclarationsGLSL(BINDING_MATERIALS) .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES) .. ddgi.GetEmitterDeclarationsGLSL(BINDING_EMITTERS),
		shader = common_glsl() .. scene_lights.GetLightGLSLCode() .. ddgi.GetEmitterGLSL() .. ddgi.GetMaterialGLSL() .. [[
			// The sun's visibility comes from the trace pass. The local lights in
			// P's light grid cell are sampled (see ddgi.LIGHT_SAMPLES): each
			// sample streams over them keeping a light with its share of the
			// weight summed so far, reusing one random number by rescaling it,
			// and the kept light's shadow ray is traced here. Without ray
			// queries the local lights would go unshadowed through walls, so
			// they're left out.
			vec3 ddgi_direct_light(vec3 P, vec3 N, bool sun_visible, float radius, vec4 u) {
				vec3 L = normalize(ddgi_data.ddgi_sun_direction.xyz);
				float NoL = max(dot(N, L), 0.0);
				vec3 direct = vec3(0.0);

				if (sun_visible) {
					direct += ddgi_data.ddgi_sun_radiance.rgb * (NoL / 3.14159265359);
				}

				#ifdef DDGI_VISIBILITY_RAYS
				float total = 0.0;
				vec3 picked_light[DDGI_LIGHT_SAMPLES];
				// xyz = direction to the light, w = distance along it
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

					// flatten the falloff inside the light radius
					vec3 to_light = light.position.xyz - P;
					float source_radius = get_light_source_radius(light);
					float light_dist_sq = dot(to_light, to_light) + source_radius * source_radius;
					attenuation *= light_dist_sq / max(light_dist_sq, radius * radius);
					vec3 light_radiance = light.color.rgb * light.color.a * attenuation * (light_NoL / 3.14159265359);
					float weight = dot(light_radiance, vec3(0.2126, 0.7152, 0.0722));

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

					rayQueryEXT query;
					// stops short of the light so a bulb mesh around it doesn't shadow it
					rayQueryInitializeEXT(query, ddgi_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, 0xFF, P, 0.0, picked_ray[k].xyz, max(picked_ray[k].w - DDGI_SHADOW_OFFSET, 0.0));

					while (rayQueryProceedEXT(query)) {}

					if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) {
						direct += picked_light[k] * (total / (picked_weight[k] * float(DDGI_LIGHT_SAMPLES)));
					}
				}
				#endif

				return direct;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_ray);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				uint ray = uint(pos.x % DDGI_RAY_STRIDE);
				int c = pos.x / DDGI_RAY_STRIDE;
				int probe = pos.y;

				if (probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				vec3 origin = ddgi_probe_origin(slot, c, ddgi_world_from_slot(slot, c));
				uint hit_index = uint(probe + DDGI_P * DDGI_P * DDGI_P * c) * uint(DDGI_RAY_STRIDE) + ray;

				// An emitter sample that got through (see the ray generation
				// shader): its estimate of the irradiance, the kept point's
				// radiance over the weight it was kept by (luminance, since the
				// power it was drawn by divides out) times the candidates' mean
				// weight. Over pi and the sample count like the uniform rays'
				// estimate, with the direction packed into a; the update pass
				// applies each texel's cosine.
				if (ray >= uint(DDGI_RAYS)) {
					uvec2 hit = ddgi_hits[hit_index];
					float weight_sum = uintBitsToFloat(hit.x);
					vec4 result = vec4(0.0);

					if (ddgi_data.ddgi_rt_ready != 0 && weight_sum > 0.0) {
						scene_bvh_triangle tri = scene_bvh_triangles[ddgi_emitters[hit.y & 0x0FFFFFFFu].triangle & ~DDGI_EMITTER_DOUBLE_SIDED];
						vec4 u = ddgi_emitter_random(hit_index, uint(ddgi_data.ddgi_frame), hit.y >> 28u);
						vec3 dir = normalize(ddgi_emitter_point(tri, u.yz) - origin);
						vec3 emission = ddgi_emission(tri, ddgi_albedo(ddgi_materials[tri.material]));
						float luminance = dot(tri.emissive, vec3(0.2126, 0.7152, 0.0722));
						vec3 estimate = emission / luminance * ddgi_data.ddgi_emitter_weight * weight_sum / float(DDGI_EMITTER_CANDIDATES);
						result = vec4(estimate / (float(DDGI_EMITTER_SAMPLES) * 3.14159265359), ddgi_pack_direction(dir));
					}

					imageStore(out_ray, pos, result);
					return;
				}

				vec3 dir = ddgi_ray(ray);

				if (ddgi_data.ddgi_rt_ready == 0) {
					imageStore(out_ray, pos, vec4(ddgi_sky(dir), DDGI_MISS_DISTANCE));
					return;
				}

				uvec2 hit = ddgi_hits[hit_index];
				float t = uintBitsToFloat(hit.x);

				if (t < 0.0) {
					imageStore(out_ray, pos, vec4(ddgi_sky(dir), DDGI_MISS_DISTANCE));
					return;
				}

				scene_bvh_triangle tri = scene_bvh_triangles[hit.y & ~DDGI_SUN_VISIBLE_BIT];
				ddgi_material material = ddgi_materials[tri.material];
				// the rasterizer culls counter clockwise ("front") faces, so the
				// visible side winds clockwise and cross(e1, e2) points inward
				vec3 N = -tri.normal;

				if (dot(dir, N) > 0.0) {
					if (material.double_sided == 0) {
						imageStore(out_ray, pos, vec4(0.0, 0.0, 0.0, -DDGI_BACKFACE_SCALE * t));
						return;
					}

					N = -N;
				}

				vec3 P = origin + dir * t;
				vec3 albedo = ddgi_albedo(material);
				vec3 surface = P + N * 0.02;
				float light_radius = ddgi_data.ddgi_light_radius * ddgi_spacing(c);
				vec4 u = ddgi_emitter_random(hit_index, uint(ddgi_data.ddgi_frame), 0u);
				vec3 radiance = albedo * ddgi_direct_light(surface, N, (hit.y & DDGI_SUN_VISIBLE_BIT) != 0u, light_radius, u);

				float weight;
				radiance += albedo * ddgi_sample_irradiance(P, N, -dir, false, weight).rgb;

				imageStore(out_ray, pos, vec4(radiance, t));
			}
		]],
	}
end

-- Blends this frame's rays into a probe's octahedral tile. One workgroup per
-- probe with one invocation per tile texel; the probe's rays are staged in
-- shared memory once instead of every texel refetching them.
local function pass_update(name, texels, integrate)
	-- x = frames the texel has been accumulated for, yz = left to the
	-- integrate (the irradiance's mean luminance and noise)
	local color_formats = {
		{"r16g16b16a16_sfloat", {name, "rgba"}},
		{"r16g16b16a16_sfloat", {name .. "_state", "rgba"}},
	}
	local storage_images = {
		{binding_index = BINDING_OUTPUT, dst_stage = "compute"},
		{
			binding_index = BINDING_STATE,
			get_texture = function(self, fb)
				return fb:GetAttachment(2)
			end,
			dst_stage = "compute",
		},
	}
	local declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform image2D atlas;
		layout(set = 0, binding = ]] .. BINDING_STATE .. [[, rgba16f) uniform image2D state_atlas;
	]]

	-- a short term average next to the atlas, to tell a real change in
	-- lighting from a noisy frame
	if integrate.trend then
		color_formats[3] = {"r16g16b16a16_sfloat", {name .. "_trend", "rgba"}}
		storage_images[3] = {
			binding_index = BINDING_TREND,
			get_texture = function(self, fb)
				return fb:GetAttachment(3)
			end,
			dst_stage = "compute",
		}
		declarations = declarations .. [[
			layout(set = 0, binding = ]] .. BINDING_TREND .. [[, rgba16f) uniform image2D trend_atlas;
		]]
	end

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

			shared vec4 s_ray[DDGI_RAYS];
			shared vec3 s_dir[DDGI_RAYS];

			void main() {
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				ivec2 local = ivec2(gl_LocalInvocationID.xy);
				int c = tile.y / DDGI_P;
				int probe = tile.x + DDGI_P * DDGI_P * (tile.y % DDGI_P);

				// a whole workgroup is one probe, so this leaves no one at the barrier
				if (probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				float spacing = ddgi_spacing(c);

				for (int r = local.y * TEXELS + local.x; r < DDGI_RAYS; r += TEXELS * TEXELS) {
					s_ray[r] = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(r), slot, c), 0);
					s_dir[r] = ddgi_ray(uint(r));
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
				ivec3 world = ddgi_world_from_slot(slot, c);
				// On a reset frame the probe data itself is garbage. A disabled
				// probe's history is never shaded with and may hold light from
				// hitting the inside of geometry, so it starts over as well, before
				// relocation can carry it out into the open.
				vec4 data = ddgi_probe_data(slot, c);
				bool current = !ddgi_cascade_reset(c) && ddgi_probe_is_current(data, world) && data.w - 1.0 <= ddgi_data.ddgi_backface_threshold;
				vec4 previous = imageLoad(atlas, texel);

				vec4 state = current ? imageLoad(state_atlas, texel) : vec4(0.0);

				if (weight_sum <= 0.0) {
					imageStore(atlas, texel, current ? previous : vec4(0.0));
					imageStore(state_atlas, texel, state);
					return;
				}

				vec4 result = sum / weight_sum;
				]] .. (
				integrate.result or
				""
			) .. [[
				float hysteresis = ddgi_data.ddgi_hysteresis;
				]] .. (
				integrate.adapt or
				""
			) .. [[
				// a texel with n frames behind it weighs the new one 1 / (n + 1)
				hysteresis = min(hysteresis, state.x / (state.x + 1.0));
				state.x = min(state.x + 1.0, 1024.0);
				imageStore(state_atlas, texel, state);
				imageStore(atlas, texel, mix(result, previous, hysteresis));
			}
		]],
	}
end

-- Cosine weighted radiance; a = the cosine weighted fraction of rays that
-- saw the sky. Back face hits carry no light and are left out.
--
-- A texel's frame estimate comes from a few dozen rays, so one ray landing on
-- a small hot spot (right next to a lamp, say) can carry more light than all
-- the others together and flash the whole probe. The brightest ray is clamped
-- to the second brightest: a lone outlier then counts like a typical ray,
-- while light that many rays see keeps its top two close and passes through.
local IRRADIANCE_INTEGRATE = {
	declare = [[
		vec3 brightest = vec3(0.0);
		float brightest_luma = 0.0;
		float second_luma = 0.0;
	]],
	loop = [[
		if (ray.a < 0.0) continue;

		float w = max(0.0, dot(texel_dir, s_dir[r]));

		if (w <= 0.0) continue;

		vec3 contribution = ray.rgb * w;
		float luma = dot(contribution, vec3(0.2126, 0.7152, 0.0722));

		if (luma > brightest_luma) {
			second_luma = brightest_luma;
			brightest_luma = luma;
			brightest = contribution;
		} else if (luma > second_luma) {
			second_luma = luma;
		}

		sum += vec4(contribution, ray.a >= DDGI_MISS_DISTANCE * 0.5 ? w : 0.0);
		weight_sum += w;
	]],
	finish = [[
		if (brightest_luma > 0.0) {
			sum.rgb -= brightest * (1.0 - second_luma / brightest_luma);
		}
	]],
	-- the emitter samples are already weighted estimates of their own
	result = [[
		for (int k = 0; k < DDGI_EMITTER_SAMPLES; k++) {
			vec4 emitter = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(DDGI_RAYS + k), slot, c), 0);
			result.rgb += emitter.rgb * max(0.0, dot(texel_dir, ddgi_unpack_direction(emitter.a)));
		}
	]],
	-- A real change in lighting shows up in every frame, noise does not. A
	-- probe that sees a lit room through a doorway gets 0, 1 or 2 rays through
	-- it per frame, and at night its history is close to 0, so any one frame
	-- (or a short average holding one) can be many times the history. Only
	-- when ddgi.ADAPT_FRAMES frames in a row all differ from the history by
	-- more than the threshold (a ratio, since irradiance is in physical
	-- units), in the same direction, does the history jump to the trend, a
	-- short term average of about 4 frames. The run length is kept, signed
	-- by direction, in the trend's alpha.
	--
	-- Otherwise the hysteresis goes from the minimum for a texel whose frames
	-- agree with its average to the maximum for one whose frames deviate from
	-- it by NOISE_RANGE or more, both averaged over about as many frames as the
	-- minimum hysteresis keeps.
	trend = true,
	adapt = [[
		float luma = dot(result.rgb, vec3(0.2126, 0.7152, 0.0722));
		float deviation = state.x > 0.0 ? min(abs(luma - state.y) / max(state.y, 1e-4), 4.0) : 1.0;
		state.y = state.x > 0.0 ? mix(luma, state.y, ddgi_data.ddgi_min_hysteresis) : luma;
		state.z = state.x > 0.0 ? mix(deviation, state.z, ddgi_data.ddgi_min_hysteresis) : deviation;
		hysteresis = mix(ddgi_data.ddgi_min_hysteresis, ddgi_data.ddgi_hysteresis, clamp(state.z / ddgi_data.ddgi_noise_range, 0.0, 1.0));

		vec4 trend = current ? imageLoad(trend_atlas, texel) : vec4(result.rgb, 0.0);
		trend.rgb = mix(result.rgb, trend.rgb, 0.75);
		vec3 ratio = max(result.rgb, vec3(1e-3)) / max(previous.rgb, vec3(1e-3));
		bool up = max(ratio.r, max(ratio.g, ratio.b)) > ddgi_data.ddgi_irradiance_threshold;
		bool down = min(ratio.r, min(ratio.g, ratio.b)) < 1.0 / ddgi_data.ddgi_irradiance_threshold;
		trend.a = up == down ? 0.0 : up ? max(trend.a, 0.0) + 1.0 : min(trend.a, 0.0) - 1.0;
		imageStore(trend_atlas, texel, trend);

		if (abs(trend.a) >= ddgi_data.ddgi_adapt_frames) {
			result.rgb = trend.rgb;
			hysteresis = min(hysteresis, 0.5);
		}
	]],
}
-- Mean and mean squared of the hit distance in a sharp lobe. Back face hits
-- are kept (with their shortened distance) so the probe reads as occluded.
local DISTANCE_INTEGRATE = {
	loop = [[
		float w = pow(max(0.0, dot(texel_dir, s_dir[r])), ddgi_data.ddgi_distance_exponent);

		if (w <= 0.0) continue;

		// long enough to reach across a cell to a probe relocated away from it
		float d = min(abs(ray.a), spacing * 2.6);
		sum += vec4(d, d * d, 0.0, 0.0) * w;
		weight_sum += w;
	]],
}

-- Records which world probe each slot now holds, how many of its rays hit
-- back faces, and moves it (Majercik et al. 2021, probe relocation): out
-- through the closest back face when it is inside geometry, away from
-- surfaces that are too close, and back towards its grid point when there is
-- room. The push away is averaged over every ray that hit too close. When
-- those pushes mostly cancel the probe is squeezed between surfaces (a gap
-- between furniture and a wall): there is nowhere better to go, and a probe
-- that only sees two surfaces a hand's width away is no use for shading, so
-- it stays put and is disabled like a probe inside geometry. The rays were traced from the old offset, so their distances are
-- relative to it. Runs after the atlas updates, which read last frame's copy
-- to tell a probe that scrolled into a slot (history must be dropped) from
-- one that stayed.
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
				dst_stage = {"compute", "ray_tracing_shader_khr"},
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

				if (probe >= ddgi_probe_count(c)) return;

				ivec3 slot = ddgi_slot_from_index(probe, c);
				ivec3 world = ddgi_world_from_slot(slot, c);
				vec4 previous = imageLoad(out_data, pos);
				float spacing = ddgi_spacing(c);
				vec3 offset = !ddgi_cascade_reset(c) && ddgi_probe_is_current(previous, world) ? (previous.xyz - vec3(world)) * spacing : vec3(0.0);
				float backfaces = 0.0;
				float closest_back = 1e30;
				float closest_front = 1e30;
				vec3 closest_back_dir = vec3(0.0);
				float min_distance = ddgi_data.ddgi_relocation_distance * spacing;
				vec3 push = vec3(0.0);
				float close_rays = 0.0;

				for (int r = 0; r < DDGI_RAYS; r++) {
					float a = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ddgi_ray_texel(uint(r), slot, c), 0).a;

					if (a < 0.0) {
						backfaces += 1.0;
						float d = -a / DDGI_BACKFACE_SCALE;

						if (d < closest_back) {
							closest_back = d;
							closest_back_dir = ddgi_ray(uint(r));
						}
					} else {
						closest_front = min(closest_front, a);

						if (a < min_distance) {
							push -= ddgi_ray(uint(r)) * (min_distance - a);
							close_rays += 1.0;
						}
					}
				}

				float backface_fraction = backfaces / float(DDGI_RAYS);
				vec3 moved = offset;
				bool cramped = false;

				if (min_distance <= 0.0) {
					moved = vec3(0.0);
				} else if (backface_fraction > ddgi_data.ddgi_backface_threshold) {
					moved += closest_back_dir * (closest_back + min_distance * 0.5);
				} else if (close_rays > 0.0) {
					push /= close_rays;
					cramped = length(push) < (min_distance - closest_front) * 0.25;

					// the set of rays that land too close changes with every
					// frame's rotation; ignore the wobble that leaves behind
					if (!cramped && length(push) > spacing * 0.01) moved += push;
				} else if (closest_front > min_distance * 2.0 && dot(offset, offset) > 0.0) {
					float back = min(closest_front - min_distance * 2.0, length(offset));
					moved -= normalize(offset) * back;
				}

				if (all(lessThan(abs(moved), vec3(ddgi_data.ddgi_max_offset * spacing)))) offset = moved;

				imageStore(out_data, pos, vec4(vec3(world) + offset / spacing, cramped ? 2.0 : 1.0 + backface_fraction));
			}
		]],
	}
end

-- Debug view of the probes (ddgi_debug_probes): each probe is a sphere
-- shaded with its irradiance (1) or mean hit distance (2) in the direction of
-- the sphere's normal, drawn where its rays start. A relocated probe gets a
-- line back to its grid point, and a disabled one (inside geometry) is tinted
-- red. Draws one cascade at a time (ddgi_debug_cascade, clamped to the ones
-- in use). The lighting pass blends this over the image by its alpha.
local function pass_probe_debug()
	return {
		name = "ddgi_probe_debug",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ddgi_probe_debug", "rgba"}}},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = {"compute", "fragment"}}},
		uniform_buffers = {data_uniform()},
		on_draw = function(self, cmd, fb, frame, desc)
			if ddgi.DEBUG_PROBES == 0 then return end

			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, fb.width, fb.height, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = common_glsl() .. screen_reconstruct.GetWorldPosFromUVGLSL("ddgi_data") .. [[
			vec2 in_uv;
		]] .. screen_reconstruct.GetWorldRayGLSL("ddgi_data") .. [[

			// Quilez's ray/capsule intersection, -1 on a miss
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
				float depth = texture(TEXTURE(ddgi_data.depth_tex), in_uv).r;
				vec3 O = ddgi_data.camera_position.xyz;
				vec3 D = get_world_ray();
				int c = min(ddgi_data.ddgi_debug_cascade, ddgi_data.ddgi_cascade_count - 1);
				float spacing = ddgi_spacing(c);
				float best = depth >= 1.0 ? 1e9 : length(get_world_pos(in_uv, depth) - O);
				float radius = spacing * 0.12;
				// clip the ray to the volume, grown by a cell for the offsets
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
					// walk the cells the ray crosses; a probe (offset under half a
					// cell, plus its radius) stays inside the cells around its
					// grid point, so testing each crossed cell's corners finds it
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
							bool disabled = data.w - 1.0 > ddgi_data.ddgi_backface_threshold;
							float hit = ddgi_sphere(O, D, center, radius);

							if (hit > 0.0 && hit < best) {
								best = hit;
								vec3 n = normalize(O + D * hit - center);

								if (ddgi_data.ddgi_debug_probes == 2) {
									float mean = texture(TEXTURE(ddgi_data.ddgi_distance_tex), ddgi_atlas_uv(slot, c, n, DDGI_DISTANCE_TEXELS)).r;
									hit_color = vec3(mean / (spacing * 2.6)) * ddgi_data.ddgi_debug_scale;
								} else {
									hit_color = texture(TEXTURE(ddgi_data.ddgi_irradiance_tex), ddgi_atlas_uv(slot, c, n, DDGI_IRRADIANCE_TEXELS)).rgb;
								}

								if (disabled) hit_color = mix(hit_color, vec3(ddgi_data.ddgi_debug_scale, 0.0, 0.0), 0.7);
							}

							if (distance(center, grid) > radius) {
								// as bright as the probe itself, so the markers
								// hold up under any exposure
								vec3 up = texture(TEXTURE(ddgi_data.ddgi_irradiance_tex), ddgi_atlas_uv(slot, c, vec3(0.0, 1.0, 0.0), DDGI_IRRADIANCE_TEXELS)).rgb;
								vec3 marker = vec3(1.0, 0.6, 0.0) * max(dot(up, vec3(0.2126, 0.7152, 0.0722)), 1e-3) * 2.0 * ddgi_data.ddgi_debug_scale;
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

					if (best < 1e9 && (depth >= 1.0 || best < length(get_world_pos(in_uv, depth) - O) - 1e-4)) {
						result = vec4(hit_color, 1.0);
					}
				}

				imageStore(out_color, pos, result);
			}
		]],
	}
end

local function pass_resolve()
	return {
		name = "ddgi_resolve",
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {"ddgi_screen", "rgba"}}},
		framebuffer_count = 1,
		scale = function()
			return ddgi.RESOLVE_SCALE
		end,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = {"compute", "fragment"}}},
		descriptor_sets = VISIBILITY_RAYS and SCENE_DESCRIPTOR or nil,
		uniform_buffers = {data_uniform()},
		on_pre_draw = VISIBILITY_RAYS and
			function(self, cmd, frame, desc)
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, ddgi.GetFrameState().tlas)
			end or
			nil,
		custom_declarations = SCENE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		]],
		shader = common_glsl() .. screen_reconstruct.GetWorldPosFromUVGLSL("ddgi_data") .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				float depth = texture(TEXTURE(ddgi_data.depth_tex), uv).r;

				if (depth >= 1.0) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec3 N = normalize(texture(TEXTURE(ddgi_data.normal_tex), uv).xyz * 2.0 - 1.0);
				vec3 P = get_world_pos(uv, depth);
				vec3 V = normalize(ddgi_data.camera_position - P);
				float weight;
				vec4 gi = ddgi_sample_irradiance(P, N, V, ddgi_data.ddgi_smooth_blend != 0, weight);

				// outside the volume the sky is all there is to go on; inside it,
				// no usable probe means the point is enclosed and gets nothing
				if (weight <= 0.0 && !ddgi_in_volume(P)) {
					gi = vec4(sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, N), 1.0);
				}

				imageStore(out_color, pos, gi);
			}
		]],
	}
end

return {
	pass_trace(),
	pass_shade(),
	pass_update("ddgi_irradiance", ddgi.IRRADIANCE_TEXELS, IRRADIANCE_INTEGRATE),
	pass_update("ddgi_distance", ddgi.DISTANCE_TEXELS, DISTANCE_INTEGRATE),
	pass_probe_data(),
	pass_resolve(),
	pass_probe_debug(),
}
