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
local BINDING_SCREEN_GEOMETRY = 13
local BINDING_SCREEN_SPECULAR = 14
local BINDING_SCREEN_DEBUG = 15
local SCENE_BINDINGS = {scene = 10, hit = 30, materials = 11, light_grid = 12}
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
		vec4 surfel_hits[];
	};
	#define SURFEL_TOUCH_SAMPLES ]] .. surfel_gi.TOUCH_SAMPLES .. [[

	#define SURFEL_HIT_SAMPLES ]] .. surfel_gi.HIT_SAMPLES .. [[

]]
local TABLE_GLSL = [[
	struct SurfelSlot {
		uint lock;
		uint stamp;
		uint election;
		uint flags;
		uint screen_stamp;
		uint pad0;
		uint pad1;
		uint pad2;
	};
	layout(std430, set = 0, binding = ]] .. BINDING_TABLE .. [[) coherent buffer SurfelTable {
		SurfelSlot surfel_table[];
	};
	layout(std430, set = 0, binding = ]] .. BINDING_STATS .. [[) coherent buffer SurfelStats {
		uint surfel_stats[];
	};
	#define SURFEL_STAT(field) surfel_stats[(uint(surfel_data.surfel_frame) & 3u) * ]] .. surfel_gi.STATS_STRIDE .. [[u + uint(field)]
	#define SURFEL_STAT_ALIVE 0
	#define SURFEL_STAT_FAILED 4
	#define SURFEL_STAT_SCREEN 8
	#define SURFEL_STAT_HITS 12
	#define SURFEL_SLOT_COUNT ]] .. surfel_gi.SLOT_COUNT .. [[

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
			ivec2 cell = ivec2(index % grid.x, index / grid.x);
			ivec2 depth_size = textureSize(TEXTURE(surfel_data.depth_tex), 0);
			vec2 jitter = vec2(pcg3d(uvec3(uint(index), uint(surfel_data.surfel_frame), 0x51ed27u)).xy >> 8u) / 16777216.0;
			ivec2 pixel = min(ivec2((vec2(cell) + jitter) * vec2(depth_size) / vec2(grid)), depth_size - 1);
			float depth = gbuffer_depth(pixel);

			if (depth <= 0.0) return false;

			P = get_world_pos((vec2(pixel) + 0.5) / vec2(depth_size), depth);
			N = normalize(gbuffer_normal(pixel));
			return true;
		}

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

				if (candidate < 0 && (frame - surfel_table[g].stamp > lifetime || screen && frame - surfel_table[g].screen_stamp > lifetime)) {
					candidate = g;
					expected = v;
				}
			}

			if (candidate < 0) return -1;

			uint previous = atomicCompSwap(surfel_table[candidate].lock, expected, h);

			if (previous == expected) {
				surfel_table[candidate].stamp = frame;
				surfel_table[candidate].screen_stamp = frame - uint(surfel_data.surfel_lifetime) - 1u;
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
			int levels = level < SURFEL_TOP_LEVEL && lod - float(level) > 0.5 ? 2 : 1;
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

							if (screen) surfel_table[g].screen_stamp = frame;
						} else if (screen && surfel_data.surfel_debug != 0) {
							atomicAdd(SURFEL_STAT(SURFEL_STAT_FAILED + c), 1u);
						}
						]] or
			[[
						int g = surfel_table_find(cell, packed, c);

						if (g >= 0 && surfel_table[g].election == vote) imageStore(out_surfel, surfel_slot_texel(g), vec4(P, surfel_pack_normal(N)));
						]]
		) .. [[
					}
				}
			}
		}

		void main() {
			if (surfel_data.surfel_reset != 0) return;

			int index = int(gl_GlobalInvocationID.x);

			if (index < SURFEL_TOUCH_SAMPLES && index >= int(surfel_data.surfel_touch_size.x) * int(surfel_data.surfel_touch_size.y)) return;

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
		uniform_buffers = {pass_uniform{}},
		on_pre_draw = function(self, cmd, frame, desc)
			bind_buffers(self, desc)
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
		custom_declarations = TABLE_GLSL .. [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba32f) uniform writeonly image2D ]] .. (
				touch and
				"out_key" or
				"out_surfel"
			) .. [[;
		]],
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
		uniform_buffers = {pass_uniform{}},
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
				}

				ivec2 texel = surfel_slot_texel(g);

				if (surfel_data.surfel_reset != 0) {
					surfel_table[g] = SurfelSlot(0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u);
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

				uint interval = uint(min(1 << c, surfel_data.surfel_update_interval_max));
				bool alive = age <= uint(surfel_data.surfel_lifetime);
				bool due = alive && (count == 0.0 || (uint(g) + frame) % interval == 0u);

				if (surfel_data.surfel_debug != 0) {
					if (alive) atomicAdd(SURFEL_STAT(SURFEL_STAT_ALIVE + c), 1u);

					if (frame - entry.screen_stamp <= uint(surfel_data.surfel_lifetime)) atomicAdd(SURFEL_STAT(SURFEL_STAT_SCREEN + c), 1u);
				}

				imageStore(surfel_state, texel, vec4(due ? min(count + 1.0, 1024.0) : count, due ? 1.0 : 0.0, float(min(age, 60000u)), entry.screen_stamp == frame ? 1.0 : 0.0));
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
		storage_buffers = {{binding_index = BINDING_HITS}},
		on_pre_draw = function(self, cmd, frame, desc)
			scene_reflection.Bind(self, cmd, desc, SCENE_BINDINGS)
			local hits = surfel_gi.GetResources().hits
			self:UpdateDescriptorSet("storage_buffer", desc, BINDING_HITS, 0, hits, hits:GetSize())
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
		]] .. HITS_GLSL .. scene_reflection.GetDeclarationGLSL(SCENE_BINDINGS),
		shader = "#define SURFEL_UNSCALED\n#define SCENE_HIT_SKY_RAYS 1\n" .. glsl_common.GetConstantsGLSL() .. render3d.GetEmissiveGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. ibl.GetEnvironmentGLSLCode() .. post_source.GetPreExposureGLSL("surfel_data") .. atmosphere.GetGLSLDefines("surfel_data", "surfel_data.primary_sun_illuminance") .. atmosphere.GetAerialPerspectiveGLSLCode() .. scene_reflection.GetGLSL("surfel_data") .. [[

			vec4 surfel_merge(int c, ivec2 dir_texel, vec3 P, int level, int bucket, out float weight) {
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

			void main() {
				int c = surfel_data.surfel_cascade;
				int side = surfel_side(c);
				int dirs = side * side;
				int id = int(gl_GlobalInvocationID.x);
				int local_slot = id / dirs;

				if (local_slot >= surfel_capacity(c)) return;

				int d = id - local_slot * dirs;
				ivec2 dir_texel = ivec2(d % side, d / side);
				int g = surfel_offset(c) + local_slot;
				ivec2 slot_texel = surfel_slot_texel(g);
				vec4 state = texelFetch(TEXTURE(surfel_data.surfel_state_tex), slot_texel, 0);

				if (state.y == 0.0) return;

				vec4 surfel = texelFetch(TEXTURE(ddgi_data.surfel_tex), slot_texel, 0);
				int packed = int(texelFetch(TEXTURE(ddgi_data.surfel_key_tex), slot_texel, 0).w);
				int level = surfel_packed_level(packed);
				vec3 N = surfel_unpack_normal(surfel.w);
				ivec2 atlas_texel = surfel_atlas_texel(c, local_slot, dir_texel);

				if (dot(surfel_texel_direction(side, vec2(dir_texel) + 0.5), N) < -1.2 / float(side)) {
					imageStore(surfel_atlas, atlas_texel, vec4(0.0, 0.0, 0.0, -1.0));
					return;
				}

				vec2 jitter = vec2(pcg3d(uvec3(uint(g), uint(d), uint(surfel_data.surfel_frame))).xy >> 8u) / 16777216.0;
				vec3 dir = surfel_texel_direction(side, vec2(dir_texel) + jitter);
				float facing = dot(dir, N);

				if (facing < 0.02) dir = normalize(dir + N * (0.02 - facing));

				float size0 = surfel_cell_size(level - c);
				vec3 origin = surfel.xyz + N * (0.01 + 0.05 * size0);
				float reach = size0 * surfel_data.surfel_interval;
				bool last = c == SURFEL_CASCADES - 1;
				float t_start = c == 0 ? 0.0 : max(reach * float(1 << (2 * (c - 1))) - 1.5 * surfel_cell_size(level), 0.0);
				float t_end = last ? surfel_data.surfel_max_ray_distance : reach * float(1 << (2 * c));
				float t;
				uint instance;
				uint primitive;
				vec2 barycentrics;
				bool hit = trace_scene_interval(origin, dir, t_start, t_end, t, instance, primitive, barycentrics);
				float glass_distance = hit ? t : t_end;
				vec4 result = vec4(0.0);

				if (!hit && !last) {
					float merge_weight;
					result = surfel_merge(c, dir_texel, surfel.xyz, level, surfel_packed_bucket(packed), merge_weight);

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

								if (slot < uint(SURFEL_HIT_SAMPLES)) surfel_hits[slot] = vec4(origin + dir * t, surfel_pack_normal(front ? hit_N : -hit_N));
							}
						}
					}
				}

				if (surfel_data.glass_light != 0) result.rgb *= get_glass_light(origin, dir, glass_distance, 0.0);

				result.rgb = dot(result.rgb, vec3(1.0)) >= 0.0 ? min(result.rgb, vec3(60000.0)) : vec3(0.0);
				vec4 previous = imageLoad(surfel_atlas, atlas_texel);
				float alpha = previous.a < 0.0 ? 1.0 : max(1.0 / state.x, 1.0 - surfel_data.surfel_hysteresis);
				imageStore(surfel_atlas, atlas_texel, mix(previous, result, alpha));
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
		storage_images = {storage_image(BINDING_OUTPUT, "irradiance")},
		uniform_buffers = {
			pass_uniform{
				write = function(self, block)
					local r = surfel_gi.GetResources()
					block.surfel_state_tex = self:GetTextureIndex(r.state)
					block.surfel_atlas_tex = self:GetTextureIndex(r.atlas)
					block.surfel_positions_tex = self:GetTextureIndex(r.surfel)
				end,
			},
		},
		on_draw = function(self, cmd, fb, frame, desc)
			self:UploadConstants()
			self.pipeline:DispatchForSize(cmd, surfel_gi.GetCapacity(0), 1, 1, desc, self.dynamic_offsets)
		end,
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_irradiance;
		]],
		shader = surfel_gi.GetDefinesGLSL() .. [[
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
				imageStore(out_irradiance, surfel_irradiance_texel(g, 0), vec4(a * (0.25 * scale), saturate(sky * scale)));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 1), vec4(bx * (0.5 * scale), 0.0));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 2), vec4(by * (0.5 * scale), 0.0));
				imageStore(out_irradiance, surfel_irradiance_texel(g, 3), vec4(bz * (0.5 * scale), 0.0));
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
		custom_declarations = [[
			layout(set = 0, binding = ]] .. BINDING_OUTPUT .. [[, rgba16f) uniform writeonly image2D out_color;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_GEOMETRY .. [[, rgba16f) uniform writeonly image2D out_geometry;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_SPECULAR .. [[, rgba16f) uniform writeonly image2D out_specular;
			layout(set = 0, binding = ]] .. BINDING_SCREEN_DEBUG .. [[, rgba8) uniform writeonly image2D out_debug;
		]],
		shader = glsl_common.GetConstantsGLSL() .. compute_helpers.GetScreenHelpersGLSL() .. gbuffer_layout.GetDecodeGLSL("surfel_data") .. ibl.GetEnvironmentGLSLCode() .. surfel_gi.GetLookupGLSL() .. screen_reconstruct.GetWorldPosFromUVGLSL("surfel_data") .. [[

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
	pass_trace(),
	pass_integrate(),
	pass_resolve(),
}
