local render3d = import("goluwa/render3d/render3d.lua")
local radiance_cascades = import("goluwa/render3d/radiance_cascades.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local MAX_CLIPMAPS = voxel_gi.GetMaxClipmapCount()
local COMPUTE_LOCAL_SIZE = {x = 8, y = 8, z = 1}
local BINDING_OUTPUT = 0
local BINDING_UNIFORM = 1
local BINDING_CASCADE_SOURCE = 2
local BINDING_VOLUME_0 = 3
local BINDING_NORMAL_VOLUME_0 = BINDING_VOLUME_0 + MAX_CLIPMAPS
local BINDING_BVH_NODES = BINDING_NORMAL_VOLUME_0 + MAX_CLIPMAPS
local BINDING_BVH_TRIANGLES = BINDING_BVH_NODES + 1
local BINDING_RESOLVE_DEPTH = BINDING_BVH_TRIANGLES + 1
local BINDING_OCCLUSION_MAP = BINDING_BVH_TRIANGLES + 1
local BINDING_FEEDBACK = BINDING_BVH_TRIANGLES + 2
local USE_BVH = radiance_cascades.BACKEND == "bvh"

local function probe_tex_size(cascade)
	local p = radiance_cascades.GetProbesPerAxis(cascade)
	return {x = p * p, y = p * radiance_cascades.DIRECTION_COUNT}
end

local function get_cascade_texture(cascade)
	return function()
		local pipeline = render3d.pipelines["radiance_cascade_" .. cascade]

		if not pipeline then return nil end

		return pipeline:GetFramebuffer(1):GetAttachment(1)
	end
end

-- persistent per-probe irradiance feedback buffer: the cascades' own second
-- bounce. Rebuilt with the pass list whenever the probe grid changes; stale
-- texels just re-converge.
local feedback_tex = nil
local FEEDBACK_PROBES = radiance_cascades.GetProbesPerAxis(0)

local function get_feedback_texture()
	if not feedback_tex then
		local cmd = render.GetCommandPool():AllocateCommandBuffer()
		cmd:Begin()
		local tex = Texture.New{
			width = FEEDBACK_PROBES * FEEDBACK_PROBES,
			height = FEEDBACK_PROBES,
			format = "r16g16b16a16_sfloat",
			mip_map_levels = 1,
			image = {usage = {"storage", "sampled", "transfer_dst"}},
			view = {view_type = "2d"},
		}
		tex:SetDebugName("rc bounce feedback")
		render.TransitionResourceTo(
			tex,
			"transfer_dst_optimal",
			{
				cmd = cmd,
				srcStage = "top_of_pipe",
				srcAccess = "none",
				dstStage = "transfer",
				dstAccess = "transfer_write",
			}
		)
		cmd:ClearColorImage{image = tex:GetImage(), color = {0, 0, 0, 0}}
		render.TransitionResourceFrom(
			tex,
			"shader_read_only_optimal",
			{
				cmd = cmd,
				srcStage = "transfer",
				srcAccess = "transfer_write",
				dstStage = "fragment_shader",
				dstAccess = "shader_read",
			}
		)
		cmd:End()
		render.SubmitAndWait(cmd)
		cmd:Remove()
		feedback_tex = tex
	end

	return feedback_tex
end

local function build_volume_bindings()
	local sampled_images = {}
	local declarations = {}

	for i = 0, MAX_CLIPMAPS - 1 do
		sampled_images[#sampled_images + 1] = {
			binding_index = BINDING_VOLUME_0 + i,
			get_descriptor = function()
				return voxel_gi.GetVolumeDescriptor(i + 1, false)
			end,
		}
		sampled_images[#sampled_images + 1] = {
			binding_index = BINDING_NORMAL_VOLUME_0 + i,
			get_descriptor = function()
				return voxel_gi.GetVolumeDescriptor(i + 1, true)
			end,
		}
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_VOLUME_0 + i
			) .. ") uniform sampler2DArray rc_volume_" .. i .. ";"
		declarations[#declarations + 1] = "layout(set = 0, binding = " .. (
				BINDING_NORMAL_VOLUME_0 + i
			) .. ") uniform sampler2DArray rc_normal_" .. i .. ";"
	end

	return sampled_images, table.concat(declarations, "\n")
end

local function build_cascade_pass(cascade, is_top)
	local upper_probes = radiance_cascades.GetProbesPerAxis(cascade + 1)
	local upper_spacing = 2 * radiance_cascades.VOLUME_EXTENT / upper_probes
	local sampled_images, volume_declarations = build_volume_bindings()
	sampled_images[#sampled_images + 1] = {
		binding_index = BINDING_CASCADE_SOURCE,
		get_texture = get_cascade_texture(cascade + 1),
	}
	sampled_images[#sampled_images + 1] = {
		binding_index = BINDING_OCCLUSION_MAP,
		get_texture = function()
			return light_occlusion.GetOcclusionTexture()
		end,
	}
	return {
		name = "radiance_cascade_" .. cascade,
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		FramebufferSize = probe_tex_size(cascade),
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = BINDING_FEEDBACK,
				get_texture = get_feedback_texture,
				dst_stage = "compute",
			},
		},
		sampled_images = sampled_images,
		storage_buffers = USE_BVH and
			{
				{binding_index = BINDING_BVH_NODES},
				{binding_index = BINDING_BVH_TRIANGLES},
			} or
			nil,
		uniform_buffers = {
			{
				name = "rc_data",
				binding_index = BINDING_UNIFORM,
				block = radiance_cascades.GetBlockLayout(),
				write = function(self, block)
					return radiance_cascades.WriteBlock(self, block, cascade)
				end,
			},
		},
		on_pre_draw = function(self, cmd, frame_index, descriptor_index)
			if is_top then voxel_gi.EnsureResolvedClipmaps(cmd) end

			if USE_BVH then
				scene_bvh.EnsureBuilt()
				scene_bvh.BindBuffers(self, descriptor_index, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
			end
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_cascade;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D upper_cascade_tex;
			layout(set = 0, binding = ]] .. BINDING_FEEDBACK .. [[, rgba16f) uniform readonly image2D rc_feedback_tex;
		]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION_MAP) .. "\n" .. volume_declarations .. (
				USE_BVH and
				scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES) or
				""
			),
		shader = [[
			const int RC_CASCADE = ]] .. cascade .. [[;
			#define RC_IS_TOP ]] .. (
				is_top and
				1 or
				0
			) .. [[

			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. radiance_cascades.GetCommonGLSL(radiance_cascades.GetProbesPerAxis(cascade)) .. [[

			// the feedback grid is the cascade-0 probe lattice; it does not follow the
			// per-cascade RC_PROBES_PER_AXIS/RC_SPACING, so it is derived here.
			float rc_feedback_spacing() {
				return 2.0 * RC_VOLUME_EXTENT / float(rc_data.rc_feedback_probes);
			}

			vec3 rc_feedback_grid_origin() {
				float s = rc_feedback_spacing();
				return floor((rc_data.camera_position.xyz - vec3(RC_VOLUME_EXTENT)) / s) * s;
			}

			// trilinear sample the previous frame's per-probe irradiance at a lit
			// surface; weighted by per-probe validity so a fresh/teleported grid
			// contributes nothing until it re-converges, and by how much of the
			// surface each probe can see. note that neighbouring probes have no
			// visibility between them, so this still diffuses light through thin
			// geometry over a few frames -- hence rc_bounce defaulting to 0.
			vec3 rc_feedback_at(vec3 pos, vec3 N) {
				float s = rc_feedback_spacing();
				int n = rc_data.rc_feedback_probes;
				vec3 origin = rc_feedback_grid_origin();
				vec3 local = (pos + N * (s * rc_data.rc_normal_bias) - origin) / s - 0.5;
				ivec3 base = ivec3(floor(local));
				vec3 frac = local - vec3(base);
				vec3 acc = vec3(0.0);
				float wsum = 0.0;
				for (int z = 0; z < 2; z++)
				for (int y = 0; y < 2; y++)
				for (int x = 0; x < 2; x++) {
					ivec3 p = clamp(base + ivec3(x, y, z), ivec3(0), ivec3(n - 1));
					vec3 to_probe = origin + (vec3(p) + 0.5) * s - pos;
					float probe_dist = length(to_probe);
					float facing = probe_dist > 1e-4 ?
						(dot(to_probe / probe_dist, N) + 1.0) * 0.5 :
						1.0;
					float w = (x == 0 ? 1.0 - frac.x : frac.x) *
						(y == 0 ? 1.0 - frac.y : frac.y) *
						(z == 0 ? 1.0 - frac.z : frac.z) *
						facing * facing;
					vec4 val = imageLoad(rc_feedback_tex, ivec2(p.x + n * p.y, p.z));
					acc += val.rgb * w * val.a;
					wsum += w * val.a;
				}
				return wsum > 1e-4 ? acc / wsum : vec3(0.0);
			}

			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetShadowGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetLightGLSL("rc_data") .. [[
			]] .. voxel_gi.GetGLSLCode("rc_data.gi") .. [[
			]] .. (
				USE_BVH and
				scene_bvh.GetTraversalGLSL() or
				""
			) .. [[
			]] .. radiance_cascades.GetTraceGLSL("rc_data") .. [[

			#if RC_IS_TOP
			const float RC_MERGE_OVERLAP = 0.0;
			#else
			const int RC_UPPER_PROBES = ]] .. upper_probes .. [[;
			const float RC_UPPER_SPACING = ]] .. upper_spacing .. [[;
			const float RC_MERGE_OVERLAP = RC_UPPER_SPACING;
			vec3 rc_upper_grid_origin() {
				return floor((rc_data.camera_position.xyz - vec3(RC_VOLUME_EXTENT)) / RC_UPPER_SPACING) * RC_UPPER_SPACING;
			}
			#endif

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_cascade);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				// decode probe coords and direction from texel position
				int py = pos.x / RC_PROBES_PER_AXIS;
				int px = pos.x - py * RC_PROBES_PER_AXIS;
				int dir_idx = pos.y % RC_DIRECTION_COUNT;
				int pz = pos.y / RC_DIRECTION_COUNT;
				ivec3 probe_xyz = ivec3(px, py, pz);
				int probe_index = rc_probe_index(probe_xyz);

				vec3 world_pos = rc_probe_world_pos(probe_xyz);
				vec3 direction = rc_oct_decode(
					(vec2(float(dir_idx % 4), float(dir_idx / 4)) + 0.5) / 4.0
				);

				if (rc_data.rc_enabled == 0) {
					imageStore(out_cascade, pos, vec4(rc_sky(direction), 1.0));
					return;
				}

				float interval_start = RC_CASCADE == 0 ? 0.0 : rc_interval_end(RC_CASCADE - 1);
				float interval_end = rc_interval_end(RC_CASCADE);
				rc_hit hit;
				vec4 result;
				// The upper cascade's ray for this direction starts at ITS probe, up to
				// one upper spacing away from where this ray ends, and nothing ever
				// traces that connecting gap. Overlap the two by tracing that far past
				// the nominal end: anything in the gap terminates this ray instead of
				// letting the coarse probe -- which may be outside the room -- hand its
				// radiance over.
				bool traced = rc_trace_interval(
					world_pos,
					direction,
					interval_start,
					interval_end + RC_MERGE_OVERLAP,
					hit
				);

				if (!traced) {
#if RC_IS_TOP
					result = vec4(rc_sky(direction), 1.0);
#else
					// trilinear merge from the coarser upper cascade grid. the upper
					// interval starts where this one ended, so sample the grid at the
					// ray's end point, not at this probe: that keeps the merged ray
					// continuous instead of teleporting it back to the probe centre,
					// which is what lets a coarse probe outside a wall feed an interior
					// probe
					vec3 grid_pos = world_pos + direction * interval_end;
					vec3 local_upper = (grid_pos - rc_upper_grid_origin()) / RC_UPPER_SPACING - 0.5;
					ivec3 base_upper = ivec3(floor(local_upper));
					vec3 frac_upper = local_upper - vec3(base_upper);
					vec3 acc = vec3(0.0);
					for (int z = 0; z < 2; z++)
					for (int y = 0; y < 2; y++)
					for (int x = 0; x < 2; x++) {
						ivec3 p = clamp(base_upper + ivec3(x, y, z), ivec3(0), ivec3(RC_UPPER_PROBES - 1));
						float w = (x == 0 ? 1.0 - frac_upper.x : frac_upper.x) *
								  (y == 0 ? 1.0 - frac_upper.y : frac_upper.y) *
								  (z == 0 ? 1.0 - frac_upper.z : frac_upper.z);
						ivec2 tc = ivec2(p.x + RC_UPPER_PROBES * p.y, p.z * RC_DIRECTION_COUNT + dir_idx);
						acc += texelFetch(upper_cascade_tex, tc, 0).rgb * w;
					}
					result = vec4(acc, 1.0);
#endif
				} else {
					result = vec4(rc_shade_hit(hit), 0.0);
					if (rc_data.rc_bounce > 0.0) {
						// damped feedback: the surface reflects the surrounding
						// irradiance the cascades accumulated last frame. this is the
						// cascades' own second bounce, so it inherits their visibility
						// instead of the voxel gi's
						result.rgb += hit.voxel.rgb *
							rc_feedback_at(hit.position, hit.normal) *
							rc_data.rc_bounce;
					}
				}

				imageStore(out_cascade, pos, min(result, vec4(65504.0)));
			}
		]],
	}
end

local function build_bounce_pass()
	local p0 = radiance_cascades.GetProbesPerAxis(0)
	return {
		name = "radiance_cascades_bounce",
		ComputePass = true,
		ColorFormat = {{"r8_unorm", {"dummy", "r"}}},
		FramebufferSize = {x = p0 * p0, y = p0},
		framebuffer_count = 1,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = "compute",
			},
			{
				binding_index = BINDING_FEEDBACK,
				get_texture = get_feedback_texture,
				dst_stage = "compute",
			},
		},
		sampled_images = {
			{
				binding_index = BINDING_CASCADE_SOURCE,
				get_texture = get_cascade_texture(0),
			},
		},
		uniform_buffers = {
			{
				name = "rc_data",
				binding_index = BINDING_UNIFORM,
				block = radiance_cascades.GetBlockLayout(),
				write = function(self, block)
					return radiance_cascades.WriteBlock(self, block, 0)
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, r8) uniform writeonly image2D out_dummy;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D cascade0_tex;
			layout(set = 0, binding = ]] .. BINDING_FEEDBACK .. [[, rgba16f) uniform writeonly image2D rc_feedback_tex;
		]],
		shader = [[
			const int RC_FB_DIR = ]] .. radiance_cascades.DIRECTION_COUNT .. [[;

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_dummy);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				// each texel is one cascade-0 probe; its RC_FB_DIR directions occupy
				// the cascade0_tex rows [pz*RC_FB_DIR, pz*RC_FB_DIR + RC_FB_DIR)
				int pz = pos.y;
				vec3 sum = vec3(0.0);
				for (int d = 0; d < RC_FB_DIR; d++) {
					sum += texelFetch(cascade0_tex, ivec2(pos.x, pz * RC_FB_DIR + d), 0).rgb;
				}

				vec3 irradiance = sum / float(RC_FB_DIR);

				// cleared buffer reads a=0 on the first frame (invalid); from then on
				// a=1 marks the probe's feedback as converged enough to contribute
				imageStore(rc_feedback_tex, pos, vec4(irradiance, 1.0));
				imageStore(out_dummy, pos, vec4(0.0));
			}
		]],
	}
end

local function build_resolve_pass()
	local sampled_images, volume_declarations = build_volume_bindings()
	sampled_images[#sampled_images + 1] = {
		binding_index = BINDING_CASCADE_SOURCE,
		get_texture = get_cascade_texture(0),
	}
	sampled_images[#sampled_images + 1] = {
		binding_index = BINDING_OCCLUSION_MAP,
		get_texture = function()
			return light_occlusion.GetOcclusionTexture()
		end,
	}
	return {
		name = "radiance_cascades_resolve",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
		},
		framebuffer_count = 1,
		scale = function()
			return radiance_cascades.RESOLVE_SCALE
		end,
		LocalSize = COMPUTE_LOCAL_SIZE,
		storage_images = {
			{
				binding_index = BINDING_OUTPUT,
				attachment = 1,
				dst_stage = {"compute", "fragment"},
			},
		},
		sampled_images = sampled_images,
		storage_buffers = USE_BVH and
			{
				{binding_index = BINDING_BVH_NODES},
				{binding_index = BINDING_BVH_TRIANGLES},
			} or
			nil,
		uniform_buffers = {
			{
				name = "rc_data",
				binding_index = BINDING_UNIFORM,
				block = radiance_cascades.GetBlockLayout(),
				write = function(self, block)
					return radiance_cascades.WriteBlock(self, block, 0)
				end,
			},
		},
		on_pre_draw = function(self, cmd, frame_index, descriptor_index)
			if USE_BVH then
				scene_bvh.EnsureBuilt()
				scene_bvh.BindBuffers(self, descriptor_index, BINDING_BVH_NODES, BINDING_BVH_TRIANGLES)
			end
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D cascade_tex;
		]] .. light_occlusion.GetDeclarationGLSL(BINDING_OCCLUSION_MAP) .. "\n" .. volume_declarations .. (
				USE_BVH and
				scene_bvh.GetDeclarationsGLSL(BINDING_BVH_NODES, BINDING_BVH_TRIANGLES) or
				""
			),
		shader = [[
			const int RC_RESOLVE_DIRECTIONS = ]] .. radiance_cascades.DIRECTIONS_PER_AXIS .. [[;
			#define RC_IS_BVH ]] .. (
				USE_BVH and
				1 or
				0
			) .. [[

			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. ibl.GetEnvironmentGLSLCode() .. [[
			]] .. radiance_cascades.GetCommonGLSL() .. [[
			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetShadowGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetLightGLSL("rc_data") .. [[
			]] .. voxel_gi.GetGLSLCode("rc_data.gi") .. [[
			]] .. (
				USE_BVH and
				scene_bvh.GetTraversalGLSL() or
				""
			) .. [[
			]] .. radiance_cascades.GetTraceGLSL("rc_data") .. [[

			bool rc_occluded(vec3 from, vec3 N, vec3 probe_pos) {
				// push the ray start off the surface along its normal; stable across
				// frames unlike a radius-based self-hit skip, which flickers
				vec3 origin = from + N * rc_data.rc_vismerge_bias;
				vec3 delta = probe_pos - origin;
				float dist = length(delta);
				if (dist < 1e-3) return false;
				vec3 dir = delta / dist;
				float check_dist = rc_data.rc_vismerge_range * dist;
				float eps = rc_data.rc_vismerge_bias * 0.5;
#if RC_IS_BVH
				scene_bvh_hit traced;
				if (!scene_bvh_trace(origin, dir, 0.0, check_dist, traced)) return false;
				return traced.distance > eps;
#else
				rc_hit hit;
				if (!rc_trace_voxels(origin, dir, 0.0, check_dist, hit)) return false;
				return length(hit.position - origin) > eps;
#endif
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec2 uv = get_screen_uv(pos, size);
				float depth = rc_probe_depth(uv);

				if (depth == 1.0 || rc_data.rc_enabled == 0) {
					vec3 N = vec3(0.0, 1.0, 0.0);
					vec3 sky = sample_environment_irradiance(rc_data.rc_env_irradiance_tex, N) *
						rc_data.rc_sky_intensity;
					imageStore(out_color, pos, vec4(sky, 1.0));
					return;
				}

				vec3 N = rc_probe_normal(uv);
				vec3 world_pos = rc_reconstruct_world_pos(uv, depth);
				vec3 sky = sample_environment_irradiance(rc_data.rc_env_irradiance_tex, N) *
					rc_data.rc_sky_intensity;

				// gather at a point pushed off the surface along the normal, so the
				// trilinear cell is the one in front of the wall rather than the one
				// the wall itself occupies
				vec3 sample_pos = world_pos + N * (RC_SPACING * rc_data.rc_normal_bias);

				// trilinear in the cascade-0 probe grid. probe k sits at the cell
				// centre (k + 0.5) * spacing, so the cube surrounding the sample
				// starts at floor(local - 0.5)
				vec3 local = (sample_pos - rc_grid_origin()) / RC_SPACING - 0.5;
				ivec3 base = ivec3(floor(local));
				vec3 frac = local - vec3(base);

				ivec3 probe_p[8];
				float probe_w[8];

				for (int z = 0; z < 2; z++)
				for (int y = 0; y < 2; y++)
				for (int x = 0; x < 2; x++) {
					int i = z * 4 + y * 2 + x;
					probe_p[i] = clamp(base + ivec3(x, y, z), ivec3(0), ivec3(RC_PROBES_PER_AXIS - 1));
					vec3 to_probe = rc_probe_world_pos(probe_p[i]) - world_pos;
					float probe_dist = length(to_probe);
					// a probe behind the shading surface only ever sees its back side,
					// so it carries no light for this pixel. the smooth wrap keeps the
					// weight continuous instead of popping at the horizon
					float facing = probe_dist > 1e-4 ?
						(dot(to_probe / probe_dist, N) + 1.0) * 0.5 :
						1.0;
					probe_w[i] = (x == 0 ? 1.0 - frac.x : frac.x) *
						(y == 0 ? 1.0 - frac.y : frac.y) *
						(z == 0 ? 1.0 - frac.z : frac.z) *
						facing * facing;
				}

				if (rc_data.rc_resolve_nearest > 0.5) {
					// diagnostic: use only the single nearest probe, no trilinear blend
					int nearest = 0;
					float nearest_d2 = 1e30;
					for (int i = 0; i < 8; i++) {
						vec3 delta = vec3(probe_p[i]) + 0.5 - local;
						float d2 = dot(delta, delta);
						if (d2 < nearest_d2) { nearest_d2 = d2; nearest = i; }
					}
					for (int i = 0; i < 8; i++) probe_w[i] = (i == nearest) ? 1.0 : 0.0;
				}

				if (rc_data.rc_vismerge > 0.5 && rc_data.rc_resolve_nearest < 0.5) {
					float gated_sum = 0.0;
					float probe_gated[8];

					for (int i = 0; i < 8; i++) {
						probe_gated[i] = probe_w[i];

						if (probe_w[i] > 0.0 && rc_occluded(world_pos, N, rc_probe_world_pos(probe_p[i]))) {
							probe_gated[i] = 0.0;
						}

						gated_sum += probe_gated[i];
					}

					// only take the gated weights when something survived. an all-occluded
					// pixel keeps the facing weights rather than falling back to the
					// un-gated trilinear, which is exactly the leaking result
					if (gated_sum > 1e-4) {
						for (int i = 0; i < 8; i++) probe_w[i] = probe_gated[i];
					}
				}

				// renormalize: zeroed probes must redistribute their weight to the
				// visible ones instead of darkening the pixel
				float weight_sum = 0.0;

				for (int i = 0; i < 8; i++) weight_sum += probe_w[i];

				if (weight_sum <= 1e-6) {
					imageStore(out_color, pos, vec4(0.0, 0.0, 0.0, 0.0));
					return;
				}

				for (int i = 0; i < 8; i++) probe_w[i] /= weight_sum;

				vec3 radiance = vec3(0.0);
				float visibility = 0.0;
				float cosine_sum = 0.0;

				for (int d = 0; d < RC_RESOLVE_DIRECTIONS * RC_RESOLVE_DIRECTIONS; d++) {
					vec3 L = rc_oct_decode(
						(vec2(float(d % RC_RESOLVE_DIRECTIONS), float(d / RC_RESOLVE_DIRECTIONS)) + 0.5) /
						float(RC_RESOLVE_DIRECTIONS)
					);
					float cosine = max(dot(N, L), 0.0);

					if (cosine <= 0.0) continue;

					vec3 acc = vec3(0.0);
					float vis_acc = 0.0;

					for (int i = 0; i < 8; i++) {
						float w = probe_w[i];

						if (w <= 0.0) continue;

						ivec2 tc = rc_texel_coord(probe_p[i], d);
						vec4 val = texelFetch(cascade_tex, tc, 0);
						acc += val.rgb * w;
						vis_acc += val.a * w;
					}

					radiance += acc * cosine;
					visibility += vis_acc * cosine;
					cosine_sum += cosine;
				}

				if (cosine_sum <= 1e-6) {
					imageStore(out_color, pos, vec4(sky, 1.0));
					return;
				}

				radiance /= cosine_sum;
				visibility /= cosine_sum;
				imageStore(out_color, pos, vec4(min(radiance, vec3(65504.0)), visibility));
			}
		]],
	}
end

local passes = {}
passes[#passes + 1] = {
	name = "radiance_cascades_probes",
	ComputePass = true,
	ColorFormat = {{"r8_unorm", {"dummy", "r"}}},
	FramebufferSize = {x = 1, y = 1},
	framebuffer_count = 1,
	LocalSize = {x = 1, y = 1, z = 1},
	shader = [[
		void main() {}
	]],
	on_draw = function(self, cmd)
		voxel_gi.Draw(cmd)
	end,
}

for cascade = radiance_cascades.CASCADE_COUNT - 1, 0, -1 do
	passes[#passes + 1] = build_cascade_pass(cascade, cascade == radiance_cascades.CASCADE_COUNT - 1)
end

passes[#passes + 1] = build_bounce_pass()
passes[#passes + 1] = build_resolve_pass()
passes[#passes + 1] = {
	name = "radiance_cascades_denoise",
	ComputePass = true,
	ColorFormat = {
		{"r16g16b16a16_sfloat", {"color", "rgba"}},
	},
	framebuffer_count = 1,
	scale = function()
		return radiance_cascades.RESOLVE_SCALE
	end,
	LocalSize = COMPUTE_LOCAL_SIZE,
	storage_images = {
		{
			binding_index = BINDING_OUTPUT,
			attachment = 1,
			dst_stage = {"compute", "fragment"},
		},
	},
	sampled_images = {
		{
			binding_index = BINDING_CASCADE_SOURCE,
			get_texture = function()
				local resolve = render3d.pipelines.radiance_cascades_resolve

				if not resolve then return nil end

				return resolve:GetFramebuffer(1):GetAttachment(1)
			end,
		},
	},
	uniform_buffers = {
		{
			name = "rc_data",
			binding_index = BINDING_UNIFORM,
			block = radiance_cascades.GetBlockLayout(),
			write = function(self, block)
				return radiance_cascades.WriteBlock(self, block, 0)
			end,
		},
	},
	custom_declarations = [[
		layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
		layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D gi_tex;
	]],
	shader = [[
		const int RC_DENOISE_RADIUS = ]] .. radiance_cascades.DENOISE_RADIUS .. [[;
		const int RC_DENOISE_STRIDE = ]] .. radiance_cascades.DENOISE_STRIDE .. [[;

		#define saturate(x) clamp(x, 0.0, 1.0)

		]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
		]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[

		void main() {
			ivec2 pos = get_screen_pos();
			ivec2 size = imageSize(out_color);

			if (!is_screen_pos_in_bounds(pos, size)) return;

			vec4 center = texelFetch(gi_tex, pos, 0);
			vec2 uv = get_screen_uv(pos, size);
			float depth = rc_probe_depth(uv);

			if (rc_data.rc_denoise <= 0.0 || depth == 1.0) {
				imageStore(out_color, pos, center);
				return;
			}

			vec3 N = rc_probe_normal(uv);
			float view_depth = rc_linear_depth(depth);
			vec4 total = center;
			float total_weight = 1.0;

			for (int y = -RC_DENOISE_RADIUS; y <= RC_DENOISE_RADIUS; y++) {
				for (int x = -RC_DENOISE_RADIUS; x <= RC_DENOISE_RADIUS; x++) {
					if (x == 0 && y == 0) continue;

					ivec2 tap = clamp(pos + ivec2(x, y) * RC_DENOISE_STRIDE, ivec2(0), size - 1);
					vec2 tap_uv = get_screen_uv(tap, size);
					float tap_depth = rc_probe_depth(tap_uv);

					if (tap_depth == 1.0) continue;

					float depth_weight = exp(
						-abs(rc_linear_depth(tap_depth) - view_depth) / max(view_depth * 0.02, 1e-3)
					);
					float weight = depth_weight *
						pow(max(dot(rc_probe_normal(tap_uv), N), 0.0), 16.0) *
						rc_data.rc_denoise;

					if (weight <= 1e-4) continue;

					total += texelFetch(gi_tex, tap, 0) * weight;
					total_weight += weight;
				}
			}

			imageStore(out_color, pos, total / total_weight);
		}
	]],
}
return passes
