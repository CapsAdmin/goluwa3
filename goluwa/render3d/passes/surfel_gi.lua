local render = import("goluwa/render/render.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
local compute_helpers = import("goluwa/render3d/compute_helpers.lua")
local screen_reconstruct = import("goluwa/render3d/screen_reconstruct.lua")
local ibl = import("goluwa/render3d/ibl.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local post_source = import("goluwa/render3d/post_source.lua")
local ambient_occlusion = import("goluwa/render3d/ambient_occlusion.lua")
local scene_reflection = import("goluwa/render3d/scene_reflection.lua")
local gi = import("goluwa/render3d/gi.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local scene_emitters = import("goluwa/render3d/scene/emitters.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local surfel_gi = import("goluwa/render3d/surfel_gi.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local system = import("goluwa/system.lua")
local BINDING_OUTPUT = 0
local BINDING_PASS = 1
local BINDING_GI = 2
local BINDING_TABLE = 3
local BINDING_KEY = 4
local BINDING_SURFEL = 5
local BINDING_HITS = 6
local BINDING_STATS = 7
local BINDING_SCENE = 8
local BINDING_SCREEN_GEOMETRY = 13
local BINDING_SCREEN_SPECULAR = 14
local BINDING_SCREEN_DEBUG = 15
local BINDING_EMITTERS = 16
local SCENE_BINDINGS = {scene = 10, hit = 30, materials = 11, light_grid = 12}
-- decals float a hair above the surface they decorate: a surfel on that surface would trace into their undersides and stay black
local NO_DECALS_GLSL = string.format(
	"#define SCENE_REFLECTION_MASK 0x%02X\n",
	bit.band(0xFF, bit.bnot(scene_instances.MASK_DECAL))
)
local SOLID_MASK = string.format("0x%02X", scene_instances.MASK_SOLID)
local DUMMY_FORMAT = {{"r8_unorm", {"surfel_dummy", "r"}}}

local function pass_uniform(options)
	local layout = {
		render3d.camera_block,
		gbuffer_layout.block,
		post_source.pre_exposure_block,
		surfel_gi.GetPassBlockLayout(),
		{"surfel_positions_tex", "int"},
	}

	if options.trace then
		layout[#layout + 1] = scene_reflection.block
		layout[#layout + 1] = atmosphere.GetBlockLayout()
		layout[#layout + 1] = {"primary_sun_illuminance", "float"}
		layout[#layout + 1] = {"env_tex", "int"}
	end

	return {
		name = "surfel_data",
		binding_index = BINDING_PASS,
		block = layout,
		write = function(self, block)
			render3d.WriteCameraBlock(self, block)
			gbuffer_layout.WriteBlock(self, block)
			post_source.WritePreExposureBlock(self, block)
			surfel_gi.WritePassBlock(self, block)
			block.surfel_positions_tex = -1

			if options.trace then
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
			end

			if options.write then options.write(self, block) end

			return block
		end,
	}
end

local function gi_uniform()
	return {
		name = "ddgi_data",
		binding_index = BINDING_GI,
		block = gi.GetProbeBlockLayout(),
		write = gi.WriteProbeBlock,
	}
end

local function storage_image(binding, name)
	return {
		binding_index = binding,
		dst_stage = "compute",
		get_texture = function()
			return surfel_gi.GetResources()[name]
		end,
	}
end

local function bind_buffers(self, desc)
	local resources = surfel_gi.GetResources()
	self:UpdateDescriptorSet(
		"storage_buffer",
		desc,
		BINDING_TABLE,
		0,
		resources.table,
		resources.table:GetSize()
	)
	self:UpdateDescriptorSet("storage_buffer", desc, BINDING_HITS, 0, resources.hits, resources.hits:GetSize())
	self:UpdateDescriptorSet(
		"storage_buffer",
		desc,
		BINDING_STATS,
		0,
		resources.stats,
		resources.stats:GetSize()
	)
end

local function compute_barrier(cmd)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}
end

local HITS_GLSL = [[
	layout(std430, set = 0, binding = ]] .. BINDING_HITS .. [[) coherent buffer SurfelHits {
		uint surfel_hit_count;
		uint surfel_hit_attempts;
		uint surfel_hit_last_attempts;
		uint surfel_hit_pad;
		uint surfel_budget_rays[3];
		uint surfel_budget_pad;
		vec4 surfel_hits[];
	};
	#define SURFEL_TOUCH_SAMPLES ]] .. surfel_gi.TOUCH_SAMPLES .. [[

	#define SURFEL_HIT_SAMPLES ]] .. surfel_gi.HIT_SAMPLES .. [[

	// a sample at a crease lies on both surfaces (a hair outside one of them in depth precision), and rays from it see through the other one: pull it off both, along the normals of the neighbouring pixels whose plane it lies on (never toward the camera, which can see through single sided planes)
	#define SURFEL_SAMPLE_PULL 0.01

]]
local TABLE_GLSL = [[
	struct SurfelSlot {
		uint lock;
		uint stamp;
		uint election;
		uint flags;
		uint screen_stamp;
		uint position_stamp;
		uint hidden;
		uint backfaces;
		uint ratio_sum;
		uint drift;
	};
	layout(std430, set = 0, binding = ]] .. BINDING_TABLE .. [[) coherent buffer SurfelTable {
		SurfelSlot surfel_table[];
	};
	layout(std430, set = 0, binding = ]] .. BINDING_STATS .. [[) coherent buffer SurfelStats {
		uint surfel_stats[];
	};
	#define SURFEL_STAT(field) surfel_stats[(uint(surfel_data.surfel_frame) & 3u) * ]] .. surfel_gi.STATS_STRIDE .. [[u + uint(field)]
	#define SURFEL_POSITION_HOLD 30
	#define SURFEL_POSITION_CONFIRM 8
	#define SURFEL_CHANGE_THRESHOLD 0.4
	#define SURFEL_CHANGE_BOOST 4u
	#define SURFEL_IDLE_INTERVAL_SCALE 16
	#define SURFEL_STAT_ALIVE 0
	#define SURFEL_STAT_FAILED 4
	#define SURFEL_STAT_SCREEN 8
	#define SURFEL_STAT_HITS 12

]] .. HITS_GLSL

local function visit_glsl(touch)
	return surfel_gi.GetDefinesGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("surfel_data") .. screen_reconstruct.GetWorldPosFromUVGLSL("surfel_data") .. [[

		float surfel_cell_size_at(int level) {
			return surfel_data.surfel_cell_size * exp2(float(level));
		}

		bool surfel_touch_sample(int index, out vec3 P, out vec3 N) {
			if (index >= SURFEL_TOUCH_SAMPLES) {
				int hit = index - SURFEL_TOUCH_SAMPLES;

				if (hit >= int(min(surfel_hit_count, uint(SURFEL_HIT_SAMPLES)))) return false;

				vec4 sample_hit = surfel_hits[hit];
				P = sample_hit.xyz;
				N = surfel_unpack_normal(sample_hit.w);
				return true;
			}

			ivec2 grid = ivec2(surfel_data.surfel_touch_size);
			// when a table is full the samples that run first win the free slots, and threads run in screen rows: scramble which cell a thread takes
			int scrambled = SURFEL_ON(SURFEL_FEATURE_TOUCH_SCRAMBLE) ? int((uint(index) * 0x9E3779B1u + uint(surfel_data.surfel_frame) * 0x632BE5ABu) & uint(SURFEL_TOUCH_SAMPLES - 1)) : index;

			if (scrambled >= grid.x * grid.y) return false;

			ivec2 cell = ivec2(scrambled % grid.x, scrambled / grid.x);
			ivec2 depth_size = textureSize(TEXTURE(surfel_data.depth_tex), 0);
			vec2 jitter = vec2(pcg3d(uvec3(uint(index), uint(surfel_data.surfel_frame), 0x51ed27u)).xy >> 8u) / 16777216.0;
			ivec2 pixel = min(ivec2((vec2(cell) + jitter) * vec2(depth_size) / vec2(grid)), depth_size - 1);
			float depth = gbuffer_depth(pixel);

			if (depth <= 0.0) return false;

			P = get_world_pos((vec2(pixel) + 0.5) / vec2(depth_size), depth);
			N = normalize(gbuffer_normal(pixel));
			vec3 pull = N;

			for (int i = 0; i < 4; i++) {
				ivec2 q = clamp(pixel + ivec2(i == 0 ? 1 : i == 1 ? -1 : 0, i == 2 ? 1 : i == 3 ? -1 : 0), ivec2(0), depth_size - 1);
				float q_depth = gbuffer_depth(q);

				if (q_depth <= 0.0) continue;

				vec3 q_N = normalize(gbuffer_normal(q));

				if (abs(dot(P - get_world_pos((vec2(q) + 0.5) / vec2(depth_size), q_depth), q_N)) < SURFEL_SAMPLE_PULL) pull += q_N;
			}

			P += normalize(pull) * SURFEL_SAMPLE_PULL;
			return true;
		}

		]] .. (
			touch and
			"" or
			[[
		bool surfel_sees(vec3 from, vec3 to) {
			vec3 delta = to - from;
			float len = length(delta);

			if (len < 1e-3) return true;

			rayQueryEXT query;
			rayQueryInitializeEXT(query, surfel_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. SOLID_MASK .. [[, from, 0.0, delta / len, len);

			while (rayQueryProceedEXT(query)) {}

			return rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
		}
		]]
		) .. [[

		int surfel_table_find(ivec3 cell, int packed, int c) {
			int mask = surfel_capacity(c) - 1;
			int offset = surfel_offset(c);
			uint h = surfel_key_hash(cell, packed, c);

			for (int k = 0; k < SURFEL_PROBES; k++) {
				int g = offset + int((h + uint(k)) & uint(mask));
				uint v = surfel_table[g].lock;

				if (v == h) return g;

				if (v == 0u) return -1;
			}

			return -1;
		}

		]] .. (
			touch and
			[[
		int surfel_insert(ivec3 cell, int packed, int c, uint frame, bool screen) {
			int mask = surfel_capacity(c) - 1;
			int offset = surfel_offset(c);
			uint h = surfel_key_hash(cell, packed, c);
			int candidate = -1;
			uint expected = 0u;

			for (int k = 0; k < SURFEL_PROBES; k++) {
				int g = offset + int((h + uint(k)) & uint(mask));
				uint v = surfel_table[g].lock;

				if (v == h) {
					surfel_table[g].stamp = frame;
					return g;
				}

				if (v == 0u) {
					if (candidate < 0) {
						candidate = g;
						expected = 0u;
					}

					break;
				}

				uint lifetime = uint(surfel_data.surfel_lifetime);

				if (candidate < 0 && (frame - surfel_table[g].stamp > lifetime || SURFEL_ON(SURFEL_FEATURE_SCREEN_PRIORITY) && screen && frame - surfel_table[g].screen_stamp > lifetime)) {
					candidate = g;
					expected = v;
				}
			}

			if (candidate < 0) return -1;

			uint previous = atomicCompSwap(surfel_table[candidate].lock, expected, h);

			if (previous == expected) {
				surfel_table[candidate].stamp = frame;
				surfel_table[candidate].screen_stamp = frame - uint(surfel_data.surfel_lifetime) - 1u;
				surfel_table[candidate].position_stamp = frame - uint(SURFEL_POSITION_HOLD) - 1u;
				surfel_table[candidate].hidden = 0x3FFFFFFu;
				surfel_table[candidate].backfaces = 0u;
				surfel_table[candidate].ratio_sum = 0u;
				surfel_table[candidate].drift = 0u;
				atomicOr(surfel_table[candidate].flags, 1u);
				imageStore(out_key, surfel_slot_texel(candidate), vec4(vec3(cell), float(packed)));
				return candidate;
			}

			if (previous == h) {
				surfel_table[candidate].stamp = frame;
				return candidate;
			}

			return -1;
		}
		]] or
			""
		) .. [[

		void surfel_visit(int index) {
			vec3 P;
			vec3 N;

			if (!surfel_touch_sample(index, P, N)) return;

			if (distance(P, surfel_data.camera_position) > surfel_data.surfel_max_distance) return;

			float lod = min(surfel_lod(P, surfel_data.camera_position, surfel_data.surfel_lod_distance), float(SURFEL_TOP_LEVEL));
			int level = int(lod);
			int levels = level < SURFEL_TOP_LEVEL && lod > 0.0 ? 2 : 1;
			vec3 buckets = surfel_bucket_weights(N);
			uint frame = uint(surfel_data.surfel_frame);

			for (int l = 0; l < levels; l++) {
				for (int axis = 0; axis < 3; axis++) {
					if (buckets[axis] <= 0.0) continue;

					int bucket = surfel_bucket(axis, N[axis]);

					for (int c = 0; c < SURFEL_CASCADES; c++) {
						int cell_level = level + l + c;
						int packed = surfel_pack(cell_level, bucket);
						ivec3 cell = ivec3(floor(surfel_cell_position(P, bucket, surfel_cell_size_at(cell_level))));
						uint vote = (((pcg3d(uvec3(uint(index), uint(packed) | (uint(c) << 8u), frame)).x | 1u) & 0x7FFFu) << 17u) | uint(index);
						]] .. (
			touch and
			[[
						bool screen = index < SURFEL_TOUCH_SAMPLES;
						int g = surfel_insert(cell, packed, c, frame, screen);

						if (g >= 0) {
							atomicMax(surfel_table[g].election, vote);

							if (screen) {
								surfel_table[g].screen_stamp = frame;
								vec4 current = texelFetch(TEXTURE(surfel_data.surfel_positions_tex), surfel_slot_texel(g), 0);
								float size = surfel_cell_size_at(cell_level);

								if (current.w != 0.0 && distance(current.xyz, P) < 0.75 * size && abs(dot(P - current.xyz, surfel_unpack_normal(current.w))) < 0.1 * size) surfel_table[g].position_stamp = frame;
							}
						} else if (screen && surfel_data.surfel_debug != 0) {
							atomicAdd(SURFEL_STAT(SURFEL_STAT_FAILED + c), 1u);
						}
						]] or
			[[
						int g = surfel_table_find(cell, packed, c);

						if (g >= 0 && surfel_table[g].election == vote) {
							vec4 current = imageLoad(out_surfel, surfel_slot_texel(g));
							float bias = 0.01 + 0.05 * surfel_cell_size_at(level + l);

							bool screen = index < SURFEL_TOUCH_SAMPLES;
							vec3 current_N = surfel_unpack_normal(current.w);
							float lift = bias + surfel_curvature_lift(current.xyz, current_N, P, N);
							uint rays = surfel_table[g].backfaces;
							bool buried = SURFEL_ON(SURFEL_FEATURE_BURIED) && (rays & 0xFFFFu) * 4u >= (rays >> 16u) && rays >= (8u << 16u);
							bool fresh = (surfel_table[g].flags & 1u) != 0u || current.w == 0.0;
							bool confirmed = SURFEL_ON(SURFEL_FEATURE_POSITION_CONFIRM) && frame - surfel_table[g].position_stamp <= uint(SURFEL_POSITION_CONFIRM);
							bool seen = fresh || buried || !confirmed && (!SURFEL_ON(SURFEL_FEATURE_STICKY_POSITIONS) || surfel_sees(current.xyz + current_N * lift, P + N * lift));

							if (buried && !fresh) {
								atomicOr(surfel_table[g].flags, 1u);
								surfel_table[g].backfaces = 0u;
							}

							if (!seen && screen && frame - surfel_table[g].position_stamp > uint(SURFEL_POSITION_HOLD)) {
								seen = true;
								atomicOr(surfel_table[g].flags, 1u);
							}

							if (seen) {
								imageStore(out_surfel, surfel_slot_texel(g), vec4(P, surfel_pack_normal(N)));

								if (screen) surfel_table[g].position_stamp = frame;
							}
						}
						]]
		) .. [[
					}
				}
			}
		}

		void main() {
			if (surfel_data.surfel_reset != 0) return;

			int index = int(gl_GlobalInvocationID.x);

			surfel_visit(index);
		}
	]]
end

local function pass_visit(name, touch)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {storage_image(BINDING_OUTPUT, touch and "key" or "surfel")},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		uniform_buffers = {
			pass_uniform{
				write = touch and
					function(self, block)
						block.surfel_positions_tex = self:GetTextureIndex(surfel_gi.GetResources().surfel)
					end or
					nil,
			},
		},
		descriptor_sets = not touch and
			{
				{
					type = "acceleration_structure_khr",
					binding_index = BINDING_SCENE,
					stageFlags = "compute",
				},
			} or
			nil,
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)

			if not touch then
				self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, scene_rt.GetTLAS(cmd))
			end
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(
				cmd,
				surfel_gi.TOUCH_SAMPLES + surfel_gi.HIT_SAMPLES,
				1,
				1,
				desc,
				self.dynamic_offsets
			)
			compute_barrier(cmd)
		end,
		custom_declarations = TABLE_GLSL .. (
				touch and
				[[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform writeonly image2D out_key;
		]] or
				[[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT surfel_scene;
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform image2D out_surfel;
		]]
			),
		shader = visit_glsl(touch),
	}
end

local function pass_update()
	return {
		name = "surfel_update",
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {
			storage_image(BINDING_OUTPUT, "state"),
			storage_image(BINDING_KEY, "key"),
			storage_image(BINDING_SURFEL, "surfel"),
		},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					block.surfel_positions_tex = self:GetTextureIndex(surfel_gi.GetResources().surfel)
				end,
			},
			gi_uniform(),
		},
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.SLOT_COUNT, 1, 1, desc, self.dynamic_offsets)
			compute_barrier(cmd)

			if surfel_gi.GetDebugMode() == 0 then return end

			local stats = surfel_gi.ReadStats()

			for c, cascade in ipairs(stats) do
				gpu_timing.SetInfo(
					"surfel_update",
					"cascade " .. (c - 1),
					string.format(
						"%d alive (%d screen) of %d, %d failed",
						cascade.alive,
						cascade.screen,
						cascade.capacity,
						cascade.failed
					)
				)
			end

			gpu_timing.SetInfo("surfel_update", "hit samples", stats.hit_samples)

			if system.GetElapsedTime() - (self.surfel_stats_logged or 0) < 2 then return end

			self.surfel_stats_logged = system.GetElapsedTime()
			logf("[surfel_gi] hit samples %d\n", stats.hit_samples)

			for c, cascade in ipairs(stats) do
				logf(
					"[surfel_gi]   cascade %d: %s\n",
					c - 1,
					gpu_timing.GetInfo("surfel_update")["cascade " .. (c - 1)]
				)
			end
		end,
		custom_declarations = TABLE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform image2D surfel_state;
			layout(set = 0, binding = ]] .. BINDING_KEY .. [[, rgba32f) uniform writeonly image2D out_key;
			layout(set = 0, binding = ]] .. BINDING_SURFEL .. [[, rgba32f) uniform writeonly image2D out_surfel;
		]],
		shader = surfel_gi.GetDefinesGLSL() .. [[
			void main() {
				int g = int(gl_GlobalInvocationID.x);

				if (g >= SURFEL_SLOT_COUNT) return;

				if (g < ]] .. surfel_gi.STATS_STRIDE .. [[) surfel_stats[((uint(surfel_data.surfel_frame) + 1u) & 3u) * ]] .. surfel_gi.STATS_STRIDE .. [[u + uint(g)] = 0u;

				if (g == 0) {
					if (surfel_data.surfel_debug != 0) SURFEL_STAT(SURFEL_STAT_HITS) = min(surfel_hit_count, uint(SURFEL_HIT_SAMPLES));

					surfel_hit_count = 0u;
					surfel_hit_last_attempts = surfel_data.surfel_reset != 0 ? 0u : surfel_hit_attempts;
					surfel_hit_attempts = 0u;
					surfel_budget_rays[(uint(surfel_data.surfel_frame) + 1u) % 3u] = 0u;

					if (surfel_data.surfel_reset != 0) {
						surfel_budget_rays[0] = 0u;
						surfel_budget_rays[1] = 0u;
						surfel_budget_rays[2] = 0u;
					}
				}

				ivec2 texel = surfel_slot_texel(g);

				if (surfel_data.surfel_reset != 0) {
					surfel_table[g] = SurfelSlot(0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u);
					imageStore(out_key, texel, vec4(0.0));
					imageStore(out_surfel, texel, vec4(0.0));
					imageStore(surfel_state, texel, vec4(0.0));
					return;
				}

				SurfelSlot entry = surfel_table[g];
				surfel_table[g].election = 0u;

				if (entry.lock == 0u) {
					imageStore(surfel_state, texel, vec4(0.0));
					return;
				}

				surfel_table[g].flags = 0u;
				float count = (entry.flags & 1u) != 0u ? 0.0 : imageLoad(surfel_state, texel).x;
				uint frame = uint(surfel_data.surfel_frame);
				uint age = frame - entry.stamp;
				int c = 0;

				while (c < SURFEL_CASCADES - 1 && g >= surfel_offset(c + 1)) c++;

				bool alive = age <= uint(surfel_data.surfel_lifetime);
				uint interval = uint(min(1 << c, surfel_data.surfel_update_interval_max)) * (alive ? 1u : uint(SURFEL_IDLE_INTERVAL_SCALE));

				bool moved = false;

				if (SURFEL_ON(SURFEL_FEATURE_MOVED_RESET) && surfel_data.surfel_dirty_count > 0 && count > 0.0) {
					vec4 position = texelFetch(TEXTURE(surfel_data.surfel_positions_tex), texel, 0);
					float margin = 1.5 * surfel_data.surfel_cell_size * exp2(float(surfel_packed_level(max(int(texelFetch(TEXTURE(ddgi_data.surfel_key_tex), texel, 0).w), 1))));

					for (int i = 0; i < surfel_data.surfel_dirty_count; i++) {
						vec3 low = surfel_data.surfel_dirty_min[i].xyz;
						vec3 high = surfel_data.surfel_dirty_max[i].xyz;
						vec3 grow = vec3(max(margin, 0.5 * max(high.x - low.x, max(high.y - low.y, high.z - low.z))));

						if (all(greaterThan(position.xyz, low - grow)) && all(lessThan(position.xyz, high + grow))) {
							count = min(count, 1.0);
							moved = true;
							surfel_table[g].position_stamp = frame - uint(SURFEL_POSITION_CONFIRM) - 1u;
							surfel_table[g].flags = 4u;
							break;
						}
					}
				}

				bool due = moved || count == 0.0 || (alive || SURFEL_ON(SURFEL_FEATURE_IDLE_REFRESH)) && (uint(g) + frame) % interval == 0u;
				float throttle = 1.0;

				if (due) {
					atomicAdd(surfel_budget_rays[frame % 3u], uint(surfel_side(c) * surfel_side(c)));

					if (!moved && count > 0.0) {
						throttle = max(float(surfel_budget_rays[(frame + 2u) % 3u]) / surfel_data.surfel_ray_budget, 1.0);

						if (pcg_unorm(pcg3d(uvec3(uint(g), frame, 0x2545F491u)).x) * throttle > 1.0) due = false;
					}
				}

				uint boost = 1u;

				if (due) {
					uint rays = entry.backfaces >> 16u;

					if (SURFEL_ON(SURFEL_FEATURE_CHANGE_DETECTOR) && rays > 0u && count > 2.0) {
						float drift = mix(uintBitsToFloat(entry.drift), log2(max(float(entry.ratio_sum) / (1024.0 * float(rays)), 1e-3)), 0.5);

						if (abs(drift) > SURFEL_CHANGE_THRESHOLD) {
							boost = SURFEL_CHANGE_BOOST;
							drift = 0.0;
						}

						surfel_table[g].drift = floatBitsToUint(drift);
					}

					surfel_table[g].backfaces = 0u;
					surfel_table[g].ratio_sum = 0u;
				}

				if (surfel_data.surfel_debug != 0) {
					if (alive) atomicAdd(SURFEL_STAT(SURFEL_STAT_ALIVE + c), 1u);

					if (frame - entry.screen_stamp <= uint(surfel_data.surfel_lifetime)) atomicAdd(SURFEL_STAT(SURFEL_STAT_SCREEN + c), 1u);
				}

				imageStore(surfel_state, texel, vec4(due ? min(count + 1.0, 1024.0) : count, due ? float(interval * boost) * throttle : 0.0, float(min(age, 60000u)), entry.screen_stamp == frame ? 1.0 : 0.0));
			}
		]],
	}
end

local function pass_visibility()
	return {
		name = "surfel_visibility",
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		descriptor_sets = {
			{
				type = "acceleration_structure_khr",
				binding_index = BINDING_SCENE,
				stageFlags = "compute",
			},
		},
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					block.surfel_state_tex = self:GetTextureIndex(surfel_gi.GetResources().state)
				end,
			},
			gi_uniform(),
		},
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)
			self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, scene_rt.GetTLAS(cmd))
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.GetCapacity(0) * 26, 1, 1, desc, self.dynamic_offsets)
			compute_barrier(cmd)
		end,
		custom_declarations = TABLE_GLSL .. [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT surfel_scene;
		]],
		shader = glsl_common.GetConstantsGLSL() .. ibl.GetEnvironmentGLSLCode() .. gi.GetCommonGLSL() .. [[
			void main() {
				int id = int(gl_GlobalInvocationID.x);
				int g = id / 26;

				if (g >= surfel_capacity(0)) return;

				if (!SURFEL_ON(SURFEL_FEATURE_NEIGHBOUR_MASKS)) return;

				int neighbour = id - g * 26;
				ivec2 slot_texel = surfel_slot_texel(g);
				vec4 state = texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0);

				if (state.y == 0.0) return;

				if (state.x > 1.0 && (surfel_table[g].flags & 4u) == 0u && uint(neighbour + surfel_data.surfel_frame) % 4u != 0u) return;

				int index = neighbour < 13 ? neighbour : neighbour + 1;
				ivec3 offset = ivec3(index % 3, (index / 3) % 3, index / 9) - 1;
				vec4 key = texelFetch(TEXTURE(ddgi_data.surfel_key_tex), slot_texel, 0);
				int other = surfel_find(ivec3(key.xyz) + offset, int(key.w), 0);
				uint bit = 1u << uint(neighbour);

				if (other < 0) {
					atomicOr(surfel_table[g].hidden, bit);
					return;
				}

				float bias = 0.01 + 0.05 * surfel_cell_size(surfel_packed_level(int(key.w)));
				vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), slot_texel, 0);
				vec4 target = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(other), 0);
				vec3 surfel_N = surfel_unpack_normal(surfel.w);
				vec3 target_N = surfel_unpack_normal(target.w);
				float lift = bias + surfel_curvature_lift(surfel.xyz, surfel_N, target.xyz, target_N);
				vec3 from = surfel.xyz + surfel_N * lift;
				vec3 delta = target.xyz + target_N * lift - from;
				float len = length(delta);
				bool visible = true;

				if (len > 1e-3) {
					rayQueryEXT query;
					rayQueryInitializeEXT(query, surfel_scene, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, ]] .. SOLID_MASK .. [[, from, 0.0, delta / len, len);

					while (rayQueryProceedEXT(query)) {}

					visible = rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT;
				}

				if (visible) atomicAnd(surfel_table[g].hidden, ~bit); else atomicOr(surfel_table[g].hidden, bit);
			}
		]],
	}
end

local function pass_trace()
	return {
		name = "surfel_trace",
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {storage_image(BINDING_OUTPUT, "atlas")},
		descriptor_sets = scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {
			pass_uniform{
				trace = true,
				write = function(self, block)
					block.surfel_state_tex = self:GetTextureIndex(surfel_gi.GetResources().state)
				end,
			},
			gi_uniform(),
		},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
			bind_buffers(self, desc)
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			for c = surfel_gi.CASCADES - 1, 0, -1 do
				self.surfel_cascade = c
				self:UploadConstants()
				local side = surfel_gi.GetDirectionSide(c)
				self.pipeline:DispatchForSize(
					cmd,
					surfel_gi.GetCapacity(c) * side * side,
					1,
					1,
					desc,
					self.dynamic_offsets
				)
				compute_barrier(cmd)
			end
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform image2D surfel_atlas;
		]] .. TABLE_GLSL .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = "#define SURFEL_UNSCALED\n#define SCENE_HIT_SKY_RAYS 1\n#define SCENE_HIT_EMISSION (ddgi_data.ddgi_emitter_count == 0)\n" .. NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("surfel_data") .. atmosphere.GetGLSLDefines("surfel_data", "surfel_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("surfel_data") .. [[

			ivec3 surfel_merge_corner(int c, vec3 P, int level, int bucket, int i, out vec3 f) {
				vec3 grid = surfel_cell_position(P, bucket, surfel_cell_size(level + 1)) - 0.5;
				ivec3 base = ivec3(floor(grid));
				f = grid - vec3(base);
				return base + ivec3(i & 1, (i >> 1) & 1, i >> 2);
			}

			vec4 surfel_merge(int c, ivec2 dir_texel, vec3 P, int level, int bucket, uint visible, out float weight) {
				int coarse = c + 1;
				int coarse_level = level + 1;
				int coarse_offset = surfel_offset(coarse);
				int packed = surfel_pack(coarse_level, bucket);
				float size = surfel_cell_size(coarse_level);
				vec3 grid = surfel_cell_position(P, bucket, size) - 0.5;
				ivec3 base = ivec3(floor(grid));
				vec3 f = grid - vec3(base);
				vec4 sum = vec4(0.0);
				weight = 0.0;

				for (int i = 0; i < 8; i++) {
					if ((visible & (1u << uint(i))) == 0u) continue;

					ivec3 o = ivec3(i & 1, (i >> 1) & 1, i >> 2);
					vec3 k = mix(1.0 - f, f, vec3(o));
					float w = k.x * k.y * k.z;

					if (w <= 0.0) continue;

					int g = surfel_find(base + o, packed, coarse);

					if (g < 0) continue;

					vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(g), 0);
					w *= saturate(1.5 - abs(dot(P - surfel.xyz, surfel_unpack_normal(surfel.w))) / size);

					if (w <= 0.0) continue;

					vec4 children = vec4(0.0);
					float valid = 0.0;

					for (int j = 0; j < 4; j++) {
						vec4 v = imageLoad(surfel_atlas, surfel_atlas_texel(coarse, g - coarse_offset, dir_texel * 2 + ivec2(j & 1, j >> 1)));

						if (v.a < 0.0) continue;

						children += v;
						valid += 1.0;
					}

					if (valid == 0.0) continue;

					sum += children / valid * w;
					weight += w;
				}

				return sum / max(weight, 1e-6);
			}

			shared uint s_visible[64 / (]] .. surfel_gi.BASE_DIRECTIONS .. [[ * ]] .. surfel_gi.BASE_DIRECTIONS .. [[)];

			void main() {
				int c = surfel_data.surfel_cascade;
				int side = surfel_side(c);
				int dirs = side * side;
				int id = int(gl_GlobalInvocationID.x);
				int local_slot = id / dirs;
				int d = id - local_slot * dirs;
				uint group_slot = dirs < 64 ? gl_LocalInvocationID.x / uint(dirs) : 0u;
				int corner = dirs < 64 ? d : int(gl_LocalInvocationID.x);
				ivec2 dir_texel = ivec2(d % side, d / side);
				int g = surfel_offset(c) + local_slot;
				ivec2 slot_texel = surfel_slot_texel(g);
				vec4 state = texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0);
				vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), slot_texel, 0);
				int packed = max(int(texelFetch(TEXTURE(ddgi_data.surfel_key_tex), slot_texel, 0).w), 1);
				int level = surfel_packed_level(packed);
				vec3 N = surfel_unpack_normal(surfel.w);
				float size0 = surfel_cell_size(level - c);
				bool last = c == SURFEL_CASCADES - 1;

				float bias = 0.01 + 0.05 * size0;
				vec3 origin = surfel.xyz + N * bias;

				if (corner == 0) s_visible[group_slot] = 0u;

				barrier();

				if (state.y != 0.0 && !last && corner < 8) {
					vec3 f;
					int coarse = surfel_find(surfel_merge_corner(c, surfel.xyz, level, surfel_packed_bucket(packed), corner, f), surfel_pack(level + 1, surfel_packed_bucket(packed)), c + 1);

					if (coarse >= 0) {
						vec4 neighbour = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(coarse), 0);
						vec3 neighbour_N = surfel_unpack_normal(neighbour.w);
						float lift = surfel_curvature_lift(surfel.xyz, N, neighbour.xyz, neighbour_N);
						vec3 from = origin + N * lift;
						vec3 to = neighbour.xyz + neighbour_N * (bias + lift) - from;
						float len = length(to);

						if (!SURFEL_ON(SURFEL_FEATURE_MERGE_VISIBILITY) || len < 1e-3 || scene_reflection_visible(from, to / len, len)) atomicOr(s_visible[group_slot], 1u << uint(corner));
					}
				}

				barrier();
				uint visible = s_visible[group_slot];

				if (state.y == 0.0) return;

				ivec2 atlas_texel = surfel_atlas_texel(c, local_slot, dir_texel);

				if (dot(surfel_texel_direction(side, vec2(dir_texel) + 0.5), N) < -1.2 / float(side)) {
					imageStore(surfel_atlas, atlas_texel, vec4(0.0, 0.0, 0.0, -1.0));
					return;
				}

				vec2 jitter = vec2(pcg3d(uvec3(uint(g), uint(d), uint(surfel_data.surfel_frame))).xy >> 8u) / 16777216.0;
				vec3 dir = surfel_texel_direction(side, vec2(dir_texel) + jitter);
				float facing = dot(dir, N);

				if (facing < 0.02) dir = normalize(dir + N * (0.02 - facing));

				float t_end = last ? surfel_data.surfel_max_ray_distance : size0 * surfel_data.surfel_interval * float(1 << (2 * c));
				float t;
				uint instance;
				uint primitive;
				vec2 barycentrics;
				float t_start = SURFEL_ON(SURFEL_FEATURE_RAYS_FROM_ORIGIN) || c == 0 ? 0.0 : size0 * surfel_data.surfel_interval * float(1 << (2 * (c - 1)));
				bool hit = trace_scene_interval(origin, dir, t_start, t_end, t, instance, primitive, barycentrics);
				bool backface = false;

				if (hit) {
					scene_triangle hit_tri = scene_hit_tri(instance, primitive);
					backface = dot(dir, hit_tri.normal) < 0.0 && ddgi_materials[hit_tri.material].double_sided == 0;
				}

				atomicAdd(surfel_table[g].backfaces, backface ? 0x10001u : 0x10000u);
				float glass_distance = hit ? t : t_end;
				vec4 result = vec4(0.0);

				if (!hit && !last) {
					float merge_weight;
					result = surfel_merge(c, dir_texel, surfel.xyz, level, surfel_packed_bucket(packed), visible, merge_weight);

					if (merge_weight <= 0.0) {
						hit = trace_scene_interval(origin, dir, t_end, surfel_data.surfel_max_ray_distance, t, instance, primitive, barycentrics);
						glass_distance = hit ? t : surfel_data.surfel_max_ray_distance;

						if (!hit) result = vec4(ddgi_sky(dir), 1.0);
					}
				} else if (!hit) {
					result = vec4(ddgi_sky(dir), 1.0);
				}

				if (hit) {
					result = vec4(shade_scene_reflection_hit(origin, dir, 1.0, t, instance, primitive, barycentrics), 0.0);

					if (surfel_data.surfel_hit_spawns != 0 && state.w > 0.5) {
						scene_triangle tri = scene_hit_tri(instance, primitive);
						vec3 hit_N = -tri.normal;
						bool front = dot(dir, hit_N) <= 0.0;

						if (front || ddgi_materials[tri.material].double_sided != 0) {
							uint attempts = atomicAdd(surfel_hit_attempts, 1u);
							float rate = float(SURFEL_HIT_SAMPLES) / float(max(surfel_hit_last_attempts, uint(SURFEL_HIT_SAMPLES)));

							if (pcg_unorm(pcg3d(uvec3(attempts, uint(surfel_data.surfel_frame), 0x2c1b3c6du)).x) < rate) {
								uint slot = atomicAdd(surfel_hit_count, 1u);

								if (slot < uint(SURFEL_HIT_SAMPLES)) surfel_hits[slot] = vec4(origin + dir * max(t - SURFEL_SAMPLE_PULL, 0.0), surfel_pack_normal(front ? hit_N : -hit_N));
							}
						}
					}
				}

				if (surfel_data.glass_light != 0) result.rgb *= get_glass_light(origin, dir, glass_distance, 0.0);

				result.rgb = dot(result.rgb, vec3(1.0)) >= 0.0 ? min(result.rgb, vec3(60000.0)) : vec3(0.0);
				vec4 previous = imageLoad(surfel_atlas, atlas_texel);
				bool history = previous.a >= 0.0 && !any(isnan(previous)) && !any(isinf(previous));
				atomicAdd(surfel_table[g].ratio_sum, uint(1024.0 * (history ? clamp((luminance(result.rgb) + 1e-3) / (luminance(previous.rgb) + 1e-3), 0.0, 16.0) : 1.0)));
				float alpha = previous.a < 0.0 ? 1.0 : max(1.0 / state.x, 1.0 - pow(surfel_data.surfel_hysteresis, state.y));
				// fresh atlas memory can hold NaN, and mix(NaN, x, 1.0) is still NaN
				if (alpha >= 1.0 || any(isnan(previous)) || any(isinf(previous))) previous = result;

				imageStore(surfel_atlas, atlas_texel, mix(previous, result, alpha));
			}
		]],
	}
end

local function pass_emitters()
	return {
		name = "surfel_emitters",
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {storage_image(BINDING_OUTPUT, "emitter")},
		descriptor_sets = scene_reflection.GetDescriptorSets(SCENE_BINDINGS, "compute"),
		uniform_buffers = {
			pass_uniform{
				trace = true,
				write = function(self, block)
					block.surfel_state_tex = self:GetTextureIndex(surfel_gi.GetResources().state)
				end,
			},
			gi_uniform(),
		},
		storage_buffers = {{binding_index = BINDING_EMITTERS}},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
			local emitters = scene_emitters.BuildActive(cmd)
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_EMITTERS, 0, emitters, emitters:GetSize())
		end,
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.GetCapacity(0), 1, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform image2D surfel_emitter;
		]] .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS) .. scene_emitters.GetDeclarationGLSL(BINDING_EMITTERS),
		shader = "#define SURFEL_UNSCALED\n" .. NO_DECALS_GLSL .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("surfel_data") .. atmosphere.GetGLSLDefines("surfel_data", "surfel_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("surfel_data") .. scene_emitters.GetGLSL() .. scene_emitters.GetLightGLSL() .. [[
			#define SURFEL_EMITTER_SAMPLES EMITTER_LOCAL_CANDIDATES

			void main() {
				int g = int(gl_GlobalInvocationID.x);

				if (g >= surfel_capacity(0)) return;

				ivec2 slot_texel = surfel_slot_texel(g);
				vec4 state = texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0);

				if (state.y == 0.0) return;

				vec3 a = vec3(0.0);
				vec3 bx = vec3(0.0);
				vec3 by = vec3(0.0);
				vec3 bz = vec3(0.0);
				int emitter_count = ddgi_data.ddgi_emitter_count;

				if (emitter_count > 0 && ddgi_data.ddgi_rt_ready != 0) {
					vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), slot_texel, 0);
					vec3 N = surfel_unpack_normal(surfel.w);
					int packed = max(int(texelFetch(TEXTURE(ddgi_data.surfel_key_tex), slot_texel, 0).w), 1);
					float size = surfel_cell_size(surfel_packed_level(packed));
					vec3 origin = surfel.xyz + N * (0.01 + 0.05 * size);

					int source_count = int(emitter_words[2]);
					bool local = source_count <= EMITTER_LOCAL_SOURCES;
					int triangles[EMITTER_LOCAL_CANDIDATES];
					float weights[EMITTER_LOCAL_CANDIDATES];
					uint frame = uint(surfel_data.surfel_frame);

					if (local && !emitter_local_candidates(uint(g), frame, source_count, origin, N, size, triangles, weights)) {
						local = false;
						source_count = 0;
					}

					for (int k = 0; k < SURFEL_EMITTER_SAMPLES; k++) {
						vec3 dir;
						float dist;
						vec3 light;

						if (local) {
							int emitter = triangles[k];
							light = emitter_light(emitter, emitter_candidate_point(uint(g), frame, int(uint(emitter) | (uint(k) << 26u))), origin, N, weights[k], dir, dist);
						} else if (source_count > 0) {
							light = emitter_sample_light(uint(g * SURFEL_EMITTER_SAMPLES + k), frame, emitter_count, origin, N, size, dir, dist);
						} else {
							continue;
						}

						if (dot(dir, N) <= 0.0 || !(dot(light, vec3(1.0)) > 0.0)) continue;

						if (dist > 0.02 && !scene_reflection_visible(origin, dir, dist - 0.02)) continue;

						if (surfel_data.glass_light != 0) light *= get_glass_light(origin, dir, dist, 0.0);

						a += light;
						bx += light * dir.x;
						by += light * dir.y;
						bz += light * dir.z;
					}

					float scale = 1.0 / (float(SURFEL_EMITTER_SAMPLES) * 6.28318530718);
					a *= 0.5 * scale;
					bx *= scale;
					by *= scale;
					bz *= scale;
				}

				float alpha = max(1.0 / max(state.x, 1.0), 1.0 - pow(surfel_data.surfel_hysteresis, state.y));
				vec3 current[4] = vec3[4](a, bx, by, bz);

				for (int i = 0; i < 4; i++) {
					ivec2 texel = surfel_irradiance_texel(g, i);
					vec3 previous = imageLoad(surfel_emitter, texel).rgb;
					// fresh memory can hold NaN, and mix(NaN, x, 1.0) is still NaN
					if (alpha >= 1.0 || any(isnan(previous)) || any(isinf(previous))) previous = current[i];

					imageStore(surfel_emitter, texel, vec4(min(mix(previous, current[i], alpha), vec3(60000.0)), 0.0));
				}
			}
		]],
	}
end

local function pass_irradiance_filter(name, source, target)
	return {
		name = name,
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {storage_image(BINDING_OUTPUT, target)},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)
		end,
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					local r = surfel_gi.GetResources()
					block.surfel_state_tex = self:GetTextureIndex(r.state)
					block.surfel_filter_tex = self:GetTextureIndex(r[source])
				end,
			},
			gi_uniform(),
		},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.GetCapacity(0), 1, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = TABLE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_irradiance;
		]],
		shader = glsl_common.GetConstantsGLSL() .. ibl.GetEnvironmentGLSLCode() .. gi.GetCommonGLSL() .. [[
			void main() {
				int g = int(gl_GlobalInvocationID.x);

				if (g >= surfel_capacity(0)) return;

				ivec2 slot_texel = surfel_slot_texel(g);

				if (texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0).y == 0.0) return;

				vec4 key = texelFetch(TEXTURE(ddgi_data.surfel_key_tex), slot_texel, 0);
				vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), slot_texel, 0);
				vec3 N = surfel_unpack_normal(surfel.w);
				float size = surfel_cell_size(surfel_packed_level(int(key.w)));
				uint hidden = SURFEL_ON(SURFEL_FEATURE_NEIGHBOUR_MASKS) ? surfel_table[g].hidden : 0u;
				vec3 sum[4] = vec3[4](vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
				float sky = 0.0;
				float total = 0.0;

				for (int index = 0; index < 27; index++) {
					ivec3 offset = ivec3(index % 3, (index / 3) % 3, index / 9) - 1;
					int other = g;

					if (index != 13) {
						if (!SURFEL_ON(SURFEL_FEATURE_FILTER)) continue;

						if ((hidden & (1u << uint(index < 13 ? index : index - 1))) != 0u) continue;

						other = surfel_find(ivec3(key.xyz) + offset, int(key.w), 0);

						if (other < 0) continue;
					}

					vec4 neighbour = texelFetch(TEXTURE(ddgi_data.surfel_tex), surfel_slot_texel(other), 0);
					float w = exp2(-float(abs(offset.x) + abs(offset.y) + abs(offset.z))) * saturate(1.5 - abs(dot(neighbour.xyz - surfel.xyz, N)) / size) * saturate(dot(surfel_unpack_normal(neighbour.w), N));

					if (w <= 0.0) continue;

					vec4 a = texelFetch(TEXTURE(surfel_data.surfel_filter_tex), surfel_irradiance_texel(other, 0), 0);
					sum[0] += a.rgb * w;
					sky += a.a * w;

					for (int i = 1; i < 4; i++) {
						sum[i] += texelFetch(TEXTURE(surfel_data.surfel_filter_tex), surfel_irradiance_texel(other, i), 0).rgb * w;
					}

					total += w;
				}

				float inv_total = 1.0 / max(total, 1e-6);
				imageStore(out_irradiance, surfel_irradiance_texel(g, 0), vec4(sum[0] * inv_total, sky * inv_total));

				for (int i = 1; i < 4; i++) {
					imageStore(out_irradiance, surfel_irradiance_texel(g, i), vec4(sum[i] * inv_total, texelFetch(TEXTURE(surfel_data.surfel_filter_tex), surfel_irradiance_texel(g, i), 0).a));
				}
			}
		]],
	}
end

local function pass_integrate()
	return {
		name = "surfel_integrate",
		ComputePass = true,
		ColorFormat = DUMMY_FORMAT,
		FramebufferSize = {x = 1, y = 1},
		framebuffer_count = 1,
		LocalSize = {x = 64, y = 1, z = 1},
		storage_images = {storage_image(BINDING_OUTPUT, "irradiance_raw")},
		storage_buffers = {
			{binding_index = BINDING_TABLE},
			{binding_index = BINDING_HITS},
			{binding_index = BINDING_STATS},
		},
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)
		end,
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					local r = surfel_gi.GetResources()
					block.surfel_state_tex = self:GetTextureIndex(r.state)
					block.surfel_atlas_tex = self:GetTextureIndex(r.atlas)
					block.surfel_positions_tex = self:GetTextureIndex(r.surfel)
					block.surfel_emitter_tex = self:GetTextureIndex(r.emitter)
				end,
			},
		},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.GetCapacity(0), 1, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = TABLE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_irradiance;
		]],
		shader = surfel_gi.GetDefinesGLSL() .. [[
			vec3 surfel_emitter_irradiance(int g, int i) {
				return texelFetch(TEXTURE(surfel_data.surfel_emitter_tex), surfel_irradiance_texel(g, i), 0).rgb;
			}

			void main() {
				int g = int(gl_GlobalInvocationID.x);

				if (g >= surfel_capacity(0)) return;

				ivec2 slot_texel = surfel_slot_texel(g);

				if (texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0).y == 0.0) return;

				vec3 N = surfel_unpack_normal(texelFetch(TEXTURE(surfel_data.surfel_positions_tex), slot_texel, 0).w);
				int side = surfel_side(0);
				float total = 0.0;
				vec3 a = vec3(0.0);
				vec3 bx = vec3(0.0);
				vec3 by = vec3(0.0);
				vec3 bz = vec3(0.0);
				float sky = 0.0;

				for (int i = 0; i < side * side; i++) {
					ivec2 texel = ivec2(i % side, i / side);
					vec3 dir = surfel_texel_direction(side, vec2(texel) + 0.5);
					vec3 d = abs(dir);
					float l1 = d.x + d.y + d.z;
					float solid_angle = l1 * l1 * l1;
					total += solid_angle;
					vec4 radiance = texelFetch(TEXTURE(surfel_data.surfel_atlas_tex), surfel_atlas_texel(0, g, texel), 0);

					if (radiance.a < 0.0) continue;

					solid_angle *= saturate(0.5 + dot(dir, N) * float(side) / 2.4);
					a += radiance.rgb * solid_angle;
					bx += radiance.rgb * (dir.x * solid_angle);
					by += radiance.rgb * (dir.y * solid_angle);
					bz += radiance.rgb * (dir.z * solid_angle);
					sky += radiance.a * max(dot(dir, N), 0.0) * solid_angle;
				}

				float scale = 4.0 / max(total, 1e-6);
				uint hidden = surfel_table[g].hidden;
				imageStore(out_irradiance, surfel_irradiance_texel(g, 0), vec4(a * (0.25 * scale) + surfel_emitter_irradiance(g, 0), saturate(sky * scale)));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 1), vec4(bx * (0.5 * scale) + surfel_emitter_irradiance(g, 1), float(hidden & 511u)));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 2), vec4(by * (0.5 * scale) + surfel_emitter_irradiance(g, 2), float((hidden >> 9u) & 511u)));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 3), vec4(bz * (0.5 * scale) + surfel_emitter_irradiance(g, 3), float(hidden >> 18u)));
			}
		]],
	}
end

local function pass_resolve()
	return {
		name = "surfel_resolve",
		ComputePass = true,
		ColorFormat = {
			{"r16g16b16a16_sfloat", {"surfel_screen", "rgba"}},
			{"r16g16b16a16_sfloat", {"surfel_screen_geometry", "rgba"}},
			{"r16g16b16a16_sfloat", {"surfel_screen_specular", "rgba"}},
			{"r8g8b8a8_unorm", {"surfel_debug", "rgb"}},
		},
		framebuffer_count = 1,
		scale = function()
			return surfel_gi.GetResolveScale()
		end,
		LocalSize = {x = 8, y = 8, z = 1},
		present_texture = function()
			if surfel_gi.GetDebugMode() == 0 then return nil end

			return render3d.pipelines.surfel_resolve:GetFramebuffer(1):GetAttachment(4)
		end,
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
			{
				binding_index = BINDING_SCREEN_DEBUG,
				attachment = 4,
				dst_stage = {"compute", "fragment"},
			},
		},
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					local bent_normal = ambient_occlusion.GetBentNormalTexture()
					block.surfel_bent_normal_tex = bent_normal and self:GetTextureIndex(bent_normal) or -1
				end,
			},
			gi_uniform(),
		},
		descriptor_sets = {
			{
				type = "acceleration_structure_khr",
				binding_index = BINDING_SCENE,
				stageFlags = "compute",
			},
		},
		on_pre_draw = function(self, cmd, frame, desc)
			self:UpdateDescriptorSet("acceleration_structure_khr", desc, BINDING_SCENE, 0, scene_rt.GetTLAS(cmd))
		end,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			#define DDGI_VISIBILITY_RAYS
			#define SURFEL_SCREEN_LOOKUP
			layout(set = 0, binding = ]] .. BINDING_SCENE .. [[) uniform accelerationStructureEXT ddgi_scene;
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_GEOMETRY .. [[, rgba16f) uniform writeonly image2D out_geometry;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_SPECULAR .. [[, rgba16f) uniform writeonly image2D out_specular;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_DEBUG .. [[, rgba8) uniform writeonly image2D out_debug;
		]],
		shader = glsl_common.GetConstantsGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("surfel_data") .. ibl.GetEnvironmentGLSLCode() .. gi.GetCommonGLSL() .. screen_reconstruct.GetWorldPosFromUVGLSL("surfel_data") .. [[

			vec3 surfel_debug_color(vec3 P, vec3 N, float found, float sky) {
				if (surfel_data.surfel_debug == 2) return vec3(1.0 - found, found, 0.0);

				if (surfel_data.surfel_debug == 3) return vec3(sky);

				vec3 a = abs(N);
				int axis = a.x >= a.y && a.x >= a.z ? 0 : (a.y >= a.z ? 1 : 2);
				int level = int(min(surfel_lod(P, ddgi_data.surfel_camera.xyz, ddgi_data.surfel_params.y), float(SURFEL_TOP_LEVEL)));
				int bucket = surfel_bucket(axis, N[axis]);
				int g = surfel_find(ivec3(floor(surfel_cell_position(P, bucket, surfel_cell_size(level)))), surfel_pack(level, bucket), 0);

				if (g < 0) return vec3(0.0);

				return (vec3(pcg3d(uvec3(uint(g), 7u, 13u)) >> 24u) / 255.0 * 0.8 + 0.2) ;
			}

			void main() {
				ivec2 pos = get_screen_pos();
				ivec2 size = imageSize(out_color);

				if (!is_screen_pos_in_bounds(pos, size)) return;

				ivec2 depth_size = textureSize(TEXTURE(surfel_data.depth_tex), 0);
				mat4 inv_projection = surfel_data.inv_projection;
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
					bool thin = gbuffer_is_thin(pixel);
					bent_sum += thin ? vec3(N.x, abs(N.y), N.z) : N;

					if (surfel_data.surfel_bent_normal_tex >= 0 && !thin) {
						vec3 bent = texture(TEXTURE(surfel_data.surfel_bent_normal_tex), uv).xyz;
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
					imageStore(out_debug, pos, vec4(0.0, 0.0, 0.0, 1.0));
					return;
				}

				vec3 P = position_sum / count;
				vec3 N = normalize(normal_sum / count + 1e-6);
				vec3 L = normalize(bent_sum / count + 1e-6);
				vec3 V = normalize(surfel_data.camera_position - P);
				float roughness = roughness_sum / count;
				imageStore(out_geometry, pos, vec4(N, depth_sum / count));
				bool rough = roughness > 0.25;
				vec3 R = rough ? get_specular_dominant_direction(reflect(-V, N), N, roughness) : L;
				float weight;
				vec4 specular;
				vec4 gi = surfel_sample_irradiance_pair(P, N, L, R, true, 0, weight, specular);
				float strength = ddgi_data.surfel_params.z;
				if (weight <= 0.0) {
					gi = vec4(sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, N) * strength, 1.0);
					specular = vec4(sample_environment_irradiance(ddgi_data.ddgi_env_irradiance_tex, R) * strength, 1.0);
				}

				if (!rough) specular = gi;
				imageStore(out_color, pos, gi);
				imageStore(out_specular, pos, specular);
				imageStore(out_debug, pos, vec4(surfel_data.surfel_debug == 0 ? vec3(0.0) : surfel_debug_color(P, N, weight, gi.a), 1.0));
			}
		]],
	}
end

if not render.GetDevice().ray_query_supported then return {} end

return {
	pass_visit("surfel_touch", true),
	pass_visit("surfel_elect", false),
	pass_update(),
	pass_visibility(),
	pass_trace(),
	pass_emitters(),
	pass_integrate(),
	pass_irradiance_filter("surfel_irradiance_blur", "irradiance_raw", "irradiance_blurred"),
	pass_irradiance_filter("surfel_irradiance_filter", "irradiance_blurred", "irradiance"),
	pass_resolve(),
}
