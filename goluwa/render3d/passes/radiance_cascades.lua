local render3d = import("goluwa/render3d/render3d.lua")
local radiance_cascades = import("goluwa/render3d/radiance_cascades.lua")
local voxel_gi = import("goluwa/render3d/voxels/global_illumination.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local light_occlusion = import("goluwa/render3d/light_occlusion.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local system = import("goluwa/system.lua")
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
local BINDING_RELOCATE = BINDING_BVH_TRIANGLES + 3
-- temporal pass only uses 0 (colour out), 1 (uniform) and 2 (resolved gi)
local BINDING_TEMPORAL_DEPTH = 3
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

-- Per-probe displacement for cascade 0, rewritten in full every frame.
--
-- Unlike the feedback volume this holds no history: it is a pure function of
-- the current geometry, so a scrolling lattice cannot make it stale. That is
-- the whole reason it is recomputed rather than cached.
local relocate_tex = nil

local function get_relocate_texture()
	if not relocate_tex then
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
		tex:SetDebugName("rc probe relocation")
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
		relocate_tex = tex
	end

	return relocate_tex
end

-- read side, shared by the cascade pass, the resolve and the feedback gather
local RELOCATE_GLSL = [[
	vec3 rc_probe_relocation(ivec3 idx) {
		if (rc_data.rc_relocate <= 0.0) return vec3(0.0);

		int n = rc_data.rc_feedback_probes;
		return imageLoad(rc_relocate_tex, ivec2(idx.x + n * idx.y, idx.z)).xyz;
	}
]]

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

-- Push cascade-0 probes out of solid geometry.
--
-- A probe buried in a wall traces every ray from inside it, so it stores
-- near-zero radiance. Excluding it from the gather removes the bad sample but
-- leaves a hole; moving it just outside the surface gives back a sample that
-- actually measures the light near that wall, which is what the resolve wanted
-- from that cell in the first place.
--
-- Only cascade 0 is relocated. The coarser cascades are read by world position
-- (see the merge in build_cascade_pass), so they stay on their nominal lattice
-- and nothing downstream has to know.
local function build_relocate_pass()
	local p0 = radiance_cascades.GetProbesPerAxis(0)
	local sampled_images, volume_declarations = build_volume_bindings()
	return {
		name = "radiance_cascades_relocate",
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
				binding_index = BINDING_RELOCATE,
				get_texture = get_relocate_texture,
				dst_stage = "compute",
			},
		},
		sampled_images = sampled_images,
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
			layout(set = 0, binding = ]] .. BINDING_RELOCATE .. [[, rgba16f) uniform writeonly image2D rc_relocate_tex;
		]] .. volume_declarations,
		shader = [[
			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. radiance_cascades.GetCommonGLSL(p0) .. [[
			]] .. radiance_cascades.GetClipmapGLSL("rc_data") .. [[

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_dummy);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				int py = pos.x / RC_PROBES_PER_AXIS;
				int px = pos.x - py * RC_PROBES_PER_AXIS;
				vec3 nominal = rc_probe_world_pos(ivec3(px, py, pos.y));
				vec3 offset = vec3(0.0);

				if (rc_data.rc_relocate > 0.0 && rc_probe_in_geometry(nominal)) {
					// nearest open spot in a 3x3x3 neighbourhood. the step is
					// kept under half a cell so a relocated probe never lands
					// past its neighbour, which would fold the lattice over
					float step_size = RC_SPACING * rc_data.rc_relocate * 0.5;
					float best = 1e9;

					for (int k = 0; k < 27; k++) {
						ivec3 o = ivec3(k % 3, (k / 3) % 3, k / 9) - ivec3(1);

						if (all(equal(o, ivec3(0)))) continue;

						vec3 candidate = vec3(o) * step_size;
						float d = length(candidate);

						if (d >= best) continue;
						if (rc_probe_in_geometry(nominal + candidate)) continue;

						best = d;
						offset = candidate;
					}
				}

				imageStore(rc_relocate_tex, pos, vec4(offset, 1.0));
				imageStore(out_dummy, pos, vec4(0.0));
			}
		]],
	}
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
				{
				binding_index = BINDING_RELOCATE,
				get_texture = get_relocate_texture,
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
			layout(set = 0, binding = ]] .. BINDING_RELOCATE .. [[, rgba16f) uniform readonly image2D rc_relocate_tex;
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
			]] .. RELOCATE_GLSL .. [[

			// the feedback grid is the cascade-0 probe lattice; it does not follow the
			// per-cascade RC_PROBES_PER_AXIS/RC_SPACING, so it is derived here.
			float rc_feedback_spacing() {
				return 2.0 * RC_VOLUME_EXTENT / float(rc_data.rc_feedback_probes);
			}

			// The lattice the feedback texture was written on, which is last
			// frame's camera, not this one's. Using the current camera slid the
			// whole cached field one cell sideways on every origin snap -- the
			// texture stores probes by bare slot index and records no world
			// position, so the mapping is only ever implied by the origin in
			// force at write time. Same floor() as rc_grid_origin so the two
			// lattices cannot drift apart. See advance_feedback_camera.
			vec3 rc_feedback_grid_origin() {
				float s = rc_feedback_spacing();
				return floor((rc_data.rc_feedback_camera.xyz - vec3(RC_VOLUME_EXTENT)) / s) * s;
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
					vec3 to_probe = origin + (vec3(p) + 0.5) * s + rc_probe_relocation(p) - pos;
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
			]] .. radiance_cascades.GetClipmapGLSL("rc_data") .. radiance_cascades.GetTraceGLSL("rc_data") .. [[

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

				// trace from where the probe actually sits, or its radiance would
				// describe the nominal spot the resolve is no longer reading
				if (RC_CASCADE == 0) world_pos += rc_probe_relocation(probe_xyz);
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

-- Temporal accumulation for the resolved GI.
--
-- The resolve gathers 16 octahedral directions from 8 probes, which is a coarse
-- cubature: the per-pixel result is stable but grainy, and it shifts whenever
-- the trilinear cell or the visibility gating changes under camera motion. A
-- spatial blur alone cannot fix that without smearing the GI across edges.
-- Reprojecting the previous frame and blending gives the effective sample count
-- the cubature is missing, and it also absorbs the one-frame spikes the probe
-- cascades throw when their grid scrolls.
local function build_temporal_pass()
	return {
		name = "radiance_cascades_temporal",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"color", "rgba"}},
			{"r16_sfloat", {"view_depth", "r"}},
		},
		framebuffer_count = 2,
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
			{
				binding_index = BINDING_TEMPORAL_DEPTH,
				attachment = 2,
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
				block = {
					render3d.camera_block,
					render3d.gbuffer_block,
					render3d.prev_camera_block,
					{"history_tex", "int"},
					{"history_depth_tex", "int"},
					{"rc_temporal", "float"},
				},
				write = function(self, block)
					render3d.WriteCameraBlock(self, block)
					render3d.WriteGBufferBlock(self, block)
					render3d.WritePreviousCameraBlock(self, block)
					block.rc_temporal = radiance_cascades.TEMPORAL
					local frame = system.GetFrameNumber()

					-- a rebuilt framebuffer holds garbage until it has been
					-- written once, so skip history for a frame after that
					if self.rc_history_framebuffers ~= self.framebuffers then
						self.rc_history_framebuffers = self.framebuffers
						self.rc_history_reset_frame = frame
					end

					if render3d.ShouldUseLastFrameHistory() and frame > self.rc_history_reset_frame then
						local history = self:GetFramebuffer((frame + 1) % 2 + 1)
						block.history_tex = self:GetTextureIndex(history:GetAttachment(1))
						block.history_depth_tex = self:GetTextureIndex(history:GetAttachment(2))
					else
						block.history_tex = -1
						block.history_depth_tex = -1
					end

					return block
				end,
			},
		},
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_TEMPORAL_DEPTH .. [[, r16f) uniform writeonly image2D out_view_depth;
			layout(set = 0, binding = ]] .. BINDING_CASCADE_SOURCE .. [[) uniform sampler2D gi_tex;
		]],
		shader = [[
			#define saturate(x) clamp(x, 0.0, 1.0)

			]] .. compute_helpers.GetScreenHelpersGLSL() .. [[
			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[

			// where this pixel's surface was on screen last frame. the velocity
			// buffer handles moving geometry; the matrices cover a still scene
			// with a moving camera, which is the common case here
			bool reproject(vec2 uv, vec3 world_pos, out vec2 prev_uv, out float prev_depth) {
				if (rc_data.velocity_tex != -1) {
					vec3 motion = texture(TEXTURE(rc_data.velocity_tex), uv).rgb;
					prev_uv = uv - motion.xy;
					prev_depth = motion.z;
					return prev_depth > 1e-5;
				}

				vec4 prev_view_pos = rc_data.prev_view * vec4(world_pos, 1.0);
				vec4 prev_clip = rc_data.prev_projection * prev_view_pos;

				if (prev_clip.w <= 1e-5) return false;

				prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
				prev_depth = -prev_view_pos.z;
				return true;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				vec4 current = texelFetch(gi_tex, pos, 0);
				vec2 uv = get_screen_uv(pos, size);
				float depth = rc_probe_depth(uv);

				if (depth == 1.0 || rc_data.rc_temporal <= 0.0 || rc_data.history_tex == -1) {
					imageStore(out_color, pos, current);
					imageStore(out_view_depth, pos, vec4(depth == 1.0 ? 0.0 : rc_linear_depth(depth)));
					return;
				}

				float view_depth = rc_linear_depth(depth);
				vec3 N = rc_probe_normal(uv);
				vec3 world_pos = rc_reconstruct_world_pos(uv, depth);

				// Bounding box of the freshly resolved GI around this pixel. The
				// history gets clamped into it, which is what stops the blend
				// ghosting wherever the gather changes -- shadow edges, doorways,
				// anything the camera reveals.
				//
				// A mean +- k*sigma box would be looser and cheaper, but with a
				// 0.9 blend the history can then sit at the top of that box
				// indefinitely and the whole image drifts brighter than the input
				// it is supposed to be averaging. The min/max box cannot exceed
				// what was actually resolved nearby, so it has no such fixed point.
				vec3 lo = vec3(65504.0);
				vec3 hi = vec3(0.0);

				for (int y = -1; y <= 1; y++)
				for (int x = -1; x <= 1; x++) {
					ivec2 tap = clamp(pos + ivec2(x, y), ivec2(0), size - 1);
					vec3 c = texelFetch(gi_tex, tap, 0).rgb;
					lo = min(lo, c);
					hi = max(hi, c);
				}
				vec2 prev_uv;
				float prev_depth;
				vec4 result = current;

				if (
					reproject(uv, world_pos, prev_uv, prev_depth) &&
					all(greaterThan(prev_uv, vec2(0.0))) &&
					all(lessThan(prev_uv, vec2(1.0)))
				) {
					float history_depth = texture(TEXTURE(rc_data.history_depth_tex), prev_uv).r;

					// a history texel whose surface sat at a different distance is
					// a different surface: taking it would drag light across the
					// silhouette as the camera moves
					if (
						history_depth > 0.0 &&
						abs(history_depth - prev_depth) < prev_depth * 0.05 + 0.02
					) {
						vec4 history = texture(TEXTURE(rc_data.history_tex), prev_uv);

						if (!any(isnan(history))) {
							history.rgb = clamp(history.rgb, lo, hi);
							history.a = clamp(history.a, 0.0, 1.0);
							result = mix(current, history, rc_data.rc_temporal);
						}
					}
				}

				imageStore(out_color, pos, result);
				imageStore(out_view_depth, pos, vec4(view_depth));
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
			{
				binding_index = BINDING_RELOCATE,
				get_texture = get_relocate_texture,
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
			layout(set = 0, binding = ]] .. BINDING_RELOCATE .. [[, rgba16f) uniform readonly image2D rc_relocate_tex;
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
			]] .. RELOCATE_GLSL .. [[
			]] .. radiance_cascades.GetProbeGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetShadowGLSL("rc_data") .. [[
			]] .. radiance_cascades.GetLightGLSL("rc_data") .. [[
			]] .. voxel_gi.GetGLSLCode("rc_data.gi") .. [[
			]] .. (
				USE_BVH and
				scene_bvh.GetTraversalGLSL() or
				""
			) .. [[
			]] .. radiance_cascades.GetClipmapGLSL("rc_data") .. radiance_cascades.GetTraceGLSL("rc_data") .. [[

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

			// Per-pixel, per-frame offset inside the probe cell.
			//
			// Only the trilinear weights see this: the per-probe gating below
			// (rc_occluded and the facing wrap) is computed from world_pos, the
			// real surface point. So jittering cannot walk the lookup through a
			// wall the way the normal bias can -- it only changes which eight
			// probes get blended and in what proportion.
			vec3 rc_cell_jitter(ivec2 pos) {
				if (rc_data.rc_jitter <= 0.0) return vec3(0.0);

				// the noise texture is 64x64 with two usable channels, so a
				// second lookup a prime offset away supplies the third axis
				vec2 n0 = texelFetch(TEXTURE(rc_data.rc_blue_noise_tex), pos & 63, 0).rg;
				float n1 = texelFetch(TEXTURE(rc_data.rc_blue_noise_tex), (pos + ivec2(37, 17)) & 63, 0).r;
				// advancing every pixel by the same R3 increment each frame
				// keeps the spatial distribution blue on every individual frame
				// while walking each pixel across the cell over time
				vec3 n = fract(
					vec3(n0, n1) +
					float(rc_data.rc_frame) * vec3(0.7548776662, 0.5698402910, 0.4301597090)
				);
				return (n - 0.5) * (RC_SPACING * rc_data.rc_jitter);
			}

			// Trilinear weights for the eight cascade-0 probes around sample_pos,
			// with probes the surface cannot see zeroed when gate is set.
			// Returns the surviving weight, before renormalization.
			//
			// sample_pos only picks the cell and the blend. Every rejection test
			// uses world_pos, the true surface point, so moving the gather never
			// moves what counts as visible.
			float rc_gather_probes(
				vec3 sample_pos,
				vec3 world_pos,
				vec3 N,
				bool gate,
				out ivec3 probe_p[8],
				out float probe_w[8]
			) {
				// probe k sits at the cell centre (k + 0.5) * spacing, so the
				// cube surrounding the sample starts at floor(local - 0.5)
				vec3 local = (sample_pos - rc_grid_origin()) / RC_SPACING - 0.5;
				ivec3 base = ivec3(floor(local));
				vec3 frac = local - vec3(base);

				// smoothstep makes the reconstruction C1 across cell boundaries.
				// trilinear is only C0, and it is that gradient break -- not the
				// probe spacing itself -- that the eye picks out as boxes
				if (rc_data.rc_smooth_interp > 0.5) {
					frac = frac * frac * (3.0 - 2.0 * frac);
				}

				float sum = 0.0;

				for (int z = 0; z < 2; z++)
				for (int y = 0; y < 2; y++)
				for (int x = 0; x < 2; x++) {
					int i = z * 4 + y * 2 + x;
					probe_p[i] = clamp(base + ivec3(x, y, z), ivec3(0), ivec3(RC_PROBES_PER_AXIS - 1));
					vec3 probe_pos = rc_probe_world_pos(probe_p[i]) + rc_probe_relocation(probe_p[i]);
					vec3 to_probe = probe_pos - world_pos;
					float probe_dist = length(to_probe);
					// a probe behind the shading surface only ever sees its back side,
					// so it carries no light for this pixel. the smooth wrap keeps the
					// weight continuous instead of popping at the horizon
					float facing = probe_dist > 1e-4 ?
						(dot(to_probe / probe_dist, N) + 1.0) * 0.5 :
						1.0;
					float w = (x == 0 ? 1.0 - frac.x : frac.x) *
						(y == 0 ? 1.0 - frac.y : frac.y) *
						(z == 0 ? 1.0 - frac.z : frac.z) *
						facing * facing;

					// hard exclusion, before the visibility gate: a buried probe
					// carries no information at any weight
					if (w > 0.0 && rc_data.rc_validity > 0.5 && rc_probe_in_geometry(probe_pos)) {
						w = 0.0;
					}

					if (gate && w > 0.0 && rc_occluded(world_pos, N, probe_pos)) {
						w = 0.0;
					}

					probe_w[i] = w;
					sum += w;
				}

				return sum;
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
				vec3 sample_pos = world_pos + N * (RC_SPACING * rc_data.rc_normal_bias) +
					rc_cell_jitter(pos);

				ivec3 probe_p[8];
				float probe_w[8];
				bool gate = rc_data.rc_vismerge > 0.5;
				float weight_sum = rc_gather_probes(sample_pos, world_pos, N, gate, probe_p, probe_w);
				float gathered_sum = weight_sum;
				int fallback_path = 0;

				if (weight_sum <= rc_data.rc_collapse) {
					// Nothing around this point can see it. That is not rare: it
					// is what happens wherever a wall lands flush with a probe
					// plane. frac on the normal's axis goes to 0 or 1, the whole
					// trilinear weight collapses onto the probe slab coplanar
					// with the wall -- probes that traced from inside the
					// geometry and are therefore dark -- and the visibility gate
					// then correctly rejects every one of them.
					//
					// Reusing them anyway paints a dark seam along that plane,
					// repeating every probe spacing and sliding as the geometry
					// moves. Stepping the gather one cell along the normal lands
					// in the cell in front of the wall, whose probes can
					// actually see the surface.
					if (rc_data.rc_cell_fallback > 0.5) {
						vec3 ahead = world_pos + N * RC_SPACING;
						weight_sum = rc_gather_probes(ahead, world_pos, N, gate, probe_p, probe_w);
						fallback_path = 1;

						// still nothing visible one cell out: take those probes
						// ungated rather than going black. they are at least in
						// front of the surface, which the collapsed slab was not
						if (weight_sum <= rc_data.rc_collapse) {
							weight_sum = rc_gather_probes(ahead, world_pos, N, false, probe_p, probe_w);
							fallback_path = 2;
						}
					} else {
						weight_sum = rc_gather_probes(sample_pos, world_pos, N, false, probe_p, probe_w);
						fallback_path = 3;
					}
				}

				if (rc_data.rc_debug != 0) {
					int survivors = 0;

					for (int i = 0; i < 8; i++) if (probe_w[i] > 0.0) survivors++;

					vec3 dbg = vec3(0.0);

					if (rc_data.rc_debug == 1) {
						// how many of the eight probes survived the visibility
						// gate. red means none did
						dbg = survivors == 0 ?
							vec3(1.0, 0.0, 0.0) :
							vec3(float(survivors) / 8.0);
					} else if (rc_data.rc_debug == 2) {
						// weight before renormalization. dark means the gather
						// found almost nothing to stand on even if it did not
						// collapse outright
						dbg = vec3(clamp(gathered_sum, 0.0, 1.0));
					} else if (rc_data.rc_debug == 3) {
						// position within the probe cell along the normal's
						// dominant axis. if the seams line up with 0 or 1 here,
						// the lattice alignment is what drives them
						vec3 l = (sample_pos - rc_grid_origin()) / RC_SPACING - 0.5;
						vec3 f = l - floor(l);
						vec3 a = abs(N);
						float d = a.x > a.y && a.x > a.z ? f.x : (a.y > a.z ? f.y : f.z);
						dbg = vec3(d);
					} else if (rc_data.rc_debug == 5) {
						// share of the gather weight sitting on probes behind the
						// surface plane. trilinear is a convex combination, so a
						// result darker than every nearby probe can only mean a
						// dark contributor is in the mix -- this is how much of
						// the average those buried probes are actually holding
						float behind = 0.0;
						float total = 0.0;

						for (int i = 0; i < 8; i++) {
							if (probe_w[i] <= 0.0) continue;

							total += probe_w[i];

							if (dot(rc_probe_world_pos(probe_p[i]) - world_pos, N) <= 0.0) {
								behind += probe_w[i];
							}
						}

						dbg = total > 0.0 ? vec3(behind / total) : vec3(1.0, 0.0, 1.0);
					} else if (rc_data.rc_debug == 4) {
						// which path produced the result: grey none, red the
						// one-cell step, yellow ungated, blue the legacy reuse
						dbg = fallback_path == 0 ?
							vec3(0.15) :
							(
								fallback_path == 1 ?
								vec3(1.0, 0.0, 0.0) :
								(fallback_path == 2 ? vec3(1.0, 1.0, 0.0) : vec3(0.0, 0.3, 1.0))
							);
					}

					imageStore(out_color, pos, vec4(dbg, 1.0));
					return;
				}

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

passes[#passes + 1] = build_relocate_pass()

for cascade = radiance_cascades.CASCADE_COUNT - 1, 0, -1 do
	passes[#passes + 1] = build_cascade_pass(cascade, cascade == radiance_cascades.CASCADE_COUNT - 1)
end

passes[#passes + 1] = build_bounce_pass()
passes[#passes + 1] = build_resolve_pass()
passes[#passes + 1] = build_temporal_pass()
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
				-- the temporally accumulated result, not the raw resolve
				local temporal = render3d.pipelines.radiance_cascades_temporal

				if temporal then
					return temporal:GetFramebuffer(radiance_cascades.GetTemporalFramebufferIndex()):GetAttachment(1)
				end

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
