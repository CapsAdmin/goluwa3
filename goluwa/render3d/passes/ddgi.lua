local render3d = import("goluwa/render3d/render3d.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local P = ddgi.PROBES_PER_AXIS
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 1
local BINDING_RAY_HITS = 2
local BINDING_BVH_NODES = 3
local BINDING_BVH_TRIANGLES = 4
local BINDING_MATERIALS = 5
local BINDING_OCCLUSION_MAP = 6

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

			if not tlas then return end

			local rt = ddgi.GetRTPipeline()
			local params = ddgi.WriteRTParams()
			local hits = ddgi.GetRayHitBuffer()
			rt:UpdateDescriptorSet("uniform_buffer", desc, 0, 0, params, params:GetSize())
			rt:UpdateDescriptorSet("storage_buffer", desc, 1, 0, hits, hits:GetSize())
			rt:UpdateDescriptorSet("acceleration_structure_khr", desc, 2, 0, tlas)
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			if not ddgi.GetFrameState().rt_ready then return end

			local hits = ddgi.GetRayHitBuffer()
			cmd:PipelineBarrier{
				srcStage = "compute",
				dstStage = "ray_tracing_shader_khr",
				bufferBarriers = {{buffer = hits, srcAccessMask = "shader_read", dstAccessMask = "shader_write"}},
			}
			ddgi.GetRTPipeline():DispatchRays(cmd, ddgi.RAYS_PER_PROBE, ddgi.GetProbeCount(), 1, desc)
			cmd:PipelineBarrier{
				srcStage = "ray_tracing_shader_khr",
				dstStage = "compute",
				bufferBarriers = {{buffer = hits, srcAccessMask = "shader_write", dstAccessMask = "shader_read"}},
			}
		end,
	}
end

-- Radiance leaving each ray's hit towards its probe: direct light, emission
-- and last frame's probe irradiance at the hit (the infinite bounce). One
-- texel per ray, x = ray, y = probe slot; a = hit distance, negative for a
-- back face hit (the probe is probably inside geometry) and
-- DDGI_MISS_DISTANCE for a miss.
local function pass_shade()
	return {
		name = "ddgi_shade",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"ddgi_ray_radiance", "rgba"}}},
		FramebufferSize = {x = ddgi.RAYS_PER_PROBE, y = ddgi.GetProbeCount()},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = "compute"}},
		storage_buffers = {
			{binding_index = BINDING_RAY_HITS},
			{binding_index = BINDING_BVH_NODES},
			{binding_index = BINDING_BVH_TRIANGLES},
			{binding_index = BINDING_MATERIALS},
		},
		sampled_images = {
			{
				binding_index = BINDING_OCCLUSION_MAP,
				get_texture = function()
					return light_occlusion.GetOcclusionTexture()
				end,
			},
		},
		uniform_buffers = {data_uniform()},
		on_pre_draw = function(self, cmd, frame, desc)
			local hits = ddgi.GetRayHitBuffer()
			local materials = ddgi.WriteMaterialBuffer(self)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_RAY_HITS, 0, hits, hits:GetSize())
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_MATERIALS, 0, materials, materials:GetSize())

			if scene_bvh.triangle_buffer then
				scene_bvh.BindBuffers(self, desc, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
			else
				-- no soup yet; the shader never reads it while rt_ready is 0
				self:UpdateDescriptorSet("storage_buffer", desc, BINDING_BVH_NODES, 0, hits, hits:GetSize())
				self:UpdateDescriptorSet("storage_buffer", desc, BINDING_BVH_TRIANGLES, 0, hits, hits:GetSize())
			end
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform writeonly image2D out_ray;
			layout(set = 0, binding = ]] .. BINDING_RAY_HITS .. [[) readonly buffer DDGIRayHits {
				uvec2 ddgi_hits[];
			};
			struct ddgi_material {
				vec3 albedo;
				int albedo_tex;
				int double_sided;
			};
			layout(scalar, set = 0, binding = ]] .. BINDING_MATERIALS .. [[) readonly buffer DDGIMaterials {
				ddgi_material ddgi_materials[];
			};
		]] .. scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES) .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION_MAP),
		shader = common_glsl() .. directional_shadows.GetSurfaceDirectionalShadowGLSL("ddgi_data", "calculateShadow") .. scene_lights.GetLightGLSLCode() .. directional_shadows.GetLocalDirectionalShadowGLSL("ddgi_data") .. scene_lights.GetPointShadowGLSL("ddgi_data") .. light_occlusion.GetSamplingGLSL("ddgi_data") .. [[

			vec3 ddgi_direct_light(vec3 P, vec3 N, bool sun_visible) {
				vec3 L = normalize(ddgi_data.ddgi_sun_direction.xyz);
				float NoL = max(dot(N, L), 0.0);
				vec3 direct = vec3(0.0);

				if (sun_visible) {
					direct += ddgi_data.ddgi_sun_radiance.rgb * (NoL / 3.14159265359);
				}

				for (int i = 0; i < ddgi_data.light_count; i++) {
					lights_t light = ddgi_data.lights[i];
					int light_type = get_light_type(light);

					if (light_type == 0) continue;

					vec3 light_to_surface;
					float attenuation;

					if (!get_light_vector_and_attenuation(light, P, light_to_surface, attenuation)) continue;

					float light_NoL = max(dot(N, light_to_surface), 0.0);

					if (light_NoL <= 0.0) continue;

					float shadow = 1.0;

					if (light_type == 2) {
						if (
							i == ddgi_data.shadows.local_directional_shadow_light_index &&
							ddgi_data.shadows.local_directional_shadow_map_index >= 0
						) {
							shadow = calculateLocalDirectionalShadow(P, N, light_to_surface);
						}
					} else {
						int point_shadow_slot = getPointShadowSlot(i);

						if (point_shadow_slot >= 0) {
							shadow = calculatePointShadow(point_shadow_slot, P, N, light_to_surface);
						}

						shadow *= light_oct_shadow_factor(ddgi_data.bvh_oct_slot[i], light.position.xyz, light.params.x, P);
					}

					direct += light.color.rgb * light.color.a * attenuation * shadow * (light_NoL / 3.14159265359);
				}

				return direct;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_ray);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				uint ray = uint(pos.x);
				int probe = pos.y;
				ivec3 world = ddgi_world_from_slot(ddgi_slot_from_index(probe));
				vec3 origin = ddgi_probe_position(world);
				vec3 dir = ddgi_ray(ray);

				if (ddgi_data.ddgi_rt_ready == 0) {
					imageStore(out_ray, pos, vec4(ddgi_sky(dir), DDGI_MISS_DISTANCE));
					return;
				}

				uvec2 hit = ddgi_hits[uint(probe) * uint(DDGI_RAYS) + ray];
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
						imageStore(out_ray, pos, vec4(0.0, 0.0, 0.0, -0.2 * t));
						return;
					}

					N = -N;
				}

				vec3 P = origin + dir * t;
				vec3 albedo = material.albedo;

				// no uvs at the hit, so textured surfaces use the texture's
				// average colour from its smallest mip
				if (material.albedo_tex >= 0) {
					albedo *= textureLod(TEXTURE(material.albedo_tex), vec2(0.5), 16.0).rgb;
				}

				vec3 surface = P + N * 0.02;
				vec3 radiance = albedo * ddgi_direct_light(surface, N, (hit.y & DDGI_SUN_VISIBLE_BIT) != 0u) + min(tri.emissive * albedo * EMISSIVE_REFERENCE_LUMINANCE, vec3(EMISSIVE_MAX_LUMINANCE));

				if (ddgi_data.ddgi_reset == 0) {
					float weight;
					vec4 indirect = ddgi_sample_irradiance(P, N, -dir, weight);
					radiance += albedo * indirect.rgb;
				}

				imageStore(out_ray, pos, vec4(radiance, t));
			}
		]],
	}
end

-- Blends this frame's rays into a probe's octahedral tile. One workgroup per
-- probe with one invocation per tile texel; the probe's rays are staged in
-- shared memory once instead of every texel refetching them.
local function pass_update(name, texels, integrate)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = {{"r16g16b16a16_sfloat", {name, "rgba"}}},
		FramebufferSize = {x = P * P * texels, y = P * texels},
		framebuffer_count = 1,
		LocalSize = {x = texels, y = texels, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = "compute"}},
		uniform_buffers = {data_uniform()},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform image2D atlas;
		]],
		shader = common_glsl() .. [[
			#define TEXELS ]] .. texels .. [[

			shared vec4 s_ray[DDGI_RAYS];
			shared vec3 s_dir[DDGI_RAYS];

			void main() {
				ivec2 tile = ivec2(gl_WorkGroupID.xy);
				ivec2 local = ivec2(gl_LocalInvocationID.xy);
				ivec3 slot = ivec3(tile.x % DDGI_P, tile.x / DDGI_P, tile.y);
				int probe = ddgi_probe_index(slot);

				for (int r = local.y * TEXELS + local.x; r < DDGI_RAYS; r += TEXELS * TEXELS) {
					s_ray[r] = texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ivec2(r, probe), 0);
					s_dir[r] = ddgi_ray(uint(r));
				}

				barrier();
				vec3 texel_dir = ddgi_texel_direction(local, TEXELS);
				vec4 sum = vec4(0.0);
				float weight_sum = 0.0;

				for (int r = 0; r < DDGI_RAYS; r++) {
					vec4 ray = s_ray[r];
					]] .. integrate .. [[
				}

				ivec2 texel = tile * TEXELS + local;
				ivec3 world = ddgi_world_from_slot(slot);
				// on a reset frame the probe data itself is garbage
				bool current = ddgi_data.ddgi_reset == 0 && ddgi_probe_is_current(ddgi_probe_data(slot), world);
				vec4 previous = imageLoad(atlas, texel);

				if (weight_sum <= 0.0) {
					imageStore(atlas, texel, current ? previous : vec4(0.0));
					return;
				}

				vec4 result = sum / weight_sum;
				float hysteresis = current ? ddgi_data.ddgi_hysteresis : 0.0;
				]] .. (
				name == "ddgi_irradiance" and
				[[
				// relative, since irradiance is in physical units
				vec3 delta = abs(result.rgb - previous.rgb) / max(previous.rgb, vec3(1e-3));

				if (max(delta.r, max(delta.g, delta.b)) > ddgi_data.ddgi_irradiance_threshold) {
					hysteresis *= 0.75;
				}
				]] or
				""
			) .. [[
				imageStore(atlas, texel, mix(result, previous, hysteresis));
			}
		]],
	}
end

-- Cosine weighted radiance; a = the cosine weighted fraction of rays that
-- saw the sky. Back face hits carry no light and are left out.
local IRRADIANCE_INTEGRATE = [[
	if (ray.a < 0.0) continue;

	float w = max(0.0, dot(texel_dir, s_dir[r]));

	if (w <= 0.0) continue;

	sum += vec4(ray.rgb, ray.a >= DDGI_MISS_DISTANCE * 0.5 ? 1.0 : 0.0) * w;
	weight_sum += w;
]]
-- Mean and mean squared of the hit distance in a sharp lobe. Back face hits
-- are kept (with their shortened distance) so the probe reads as occluded.
local DISTANCE_INTEGRATE = [[
	float w = pow(max(0.0, dot(texel_dir, s_dir[r])), ddgi_data.ddgi_distance_exponent);

	if (w <= 0.0) continue;

	float d = min(abs(ray.a), ddgi_data.ddgi_spacing * 1.5);
	sum += vec4(d, d * d, 0.0, 0.0) * w;
	weight_sum += w;
]]

-- Records which world probe each slot now holds and how many of its rays hit
-- back faces. Runs after the atlas updates, which read last frame's copy to
-- tell a probe that scrolled into a slot (history must be dropped) from one
-- that stayed.
local function pass_probe_data()
	return {
		name = "ddgi_probe_data",
		ComputePass = true,
		ColorFormat = {{"r32g32b32a32_sfloat", {"ddgi_probe_data", "rgba"}}},
		FramebufferSize = {x = P * P, y = P},
		framebuffer_count = 1,
		LocalSize = {x = 8, y = 8, z = 1},
		storage_images = {{binding_index = BINDING_OUTPUT, dst_stage = "compute"}},
		uniform_buffers = {data_uniform()},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform writeonly image2D out_data;
		]],
		shader = common_glsl() .. [[
			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_data);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec3 slot = ivec3(pos.x % DDGI_P, pos.x / DDGI_P, pos.y);
				int probe = ddgi_probe_index(slot);
				float backfaces = 0.0;

				for (int r = 0; r < DDGI_RAYS; r++) {
					if (texelFetch(TEXTURE(ddgi_data.ddgi_ray_tex), ivec2(r, probe), 0).a < 0.0) backfaces += 1.0;
				}

				imageStore(out_data, pos, vec4(vec3(ddgi_world_from_slot(slot)), 1.0 + backfaces / float(DDGI_RAYS)));
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
		uniform_buffers = {data_uniform()},
		custom_declarations = [[
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
				vec4 gi = ddgi_sample_irradiance(P, N, V, weight);

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
}
