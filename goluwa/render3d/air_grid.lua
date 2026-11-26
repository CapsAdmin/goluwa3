local ffi = require("ffi")
local bit = require("bit")
local render = import("goluwa/render/render.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
local pvars = import("goluwa/cli/pvars.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local scene_rt = import("goluwa/render3d/scene/rt.lua")
local bridge = import("goluwa/render3d/scene/bridge.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local air_grid = {}
air_grid.LEVELS = 5
air_grid.BRICK = 32
air_grid.BRICKS = 8
air_grid.MAX_STEPS = 64
local BRICK_WORDS = air_grid.BRICK * air_grid.BRICK
local SLOTS = air_grid.BRICKS ^ 3
local RING = 4
local MAX_JOBS = 256
air_grid.FIELD = 128
local FIELD_BYTES = air_grid.FIELD ^ 3
pvars.StartGroup("Lighting", "Air grid", {store = false, prefix = "air_grid_"})
air_grid.enabled = pvars.Setup2{
	key = "air_grid",
	default = true,
	help = "build a voxel grid of the static world around the camera, telling solid cells from air, that light lookups can march instead of tracing rays",
}
local cell = pvars.Setup2{
	key = "air_grid_cell",
	default = 0.1,
	help = "meters per cell of the finest level, every coarser level doubles it",
	callback = function(_, is_init)
		if not is_init then air_grid.Reset() end
	end,
}
local close_radius = pvars.Setup2{
	key = "air_grid_close",
	default = 1,
	help = "cells the solid is grown and shrunk back by, which seals cracks up to twice as wide while openings wider than that stay open",
	callback = function(_, is_init)
		if not is_init then air_grid.Reset() end
	end,
}
local bricks_per_frame = pvars.Setup2{
	key = "air_grid_bricks_per_frame",
	default = 32,
	help = "bricks of 32x32x32 cells voxelized per frame",
}
air_grid.probe_visibility = pvars.Setup2{
	key = "air_grid_probe_visibility",
	default = false,
	help = "probe lookups march the grid toward a probe and drop it when a solid cell is in the way, rays only test what the grid does not cover",
}
local field_rounds = pvars.Setup2{
	key = "air_grid_field_rounds",
	default = 3,
	help = "rounds of sweeps along all six directions when the distance from open sky is computed, a path through air that turns more often than this is found too long",
}
air_grid.ray_check = pvars.Setup2{
	key = "air_grid_ray_check",
	default = true,
	help = "gi rays are checked against the distance from open sky along them and dropped where it jumps by more than the ray travelled, which only happens where the ray slipped through a crack the grid has sealed",
}
local DEBUG_VIEWS = {off = 0, cells = 1, finest = 2, sky = 3}
local debug_view = pvars.Setup2{
	key = "air_grid_debug",
	default = "off",
	enums = {"off", "cells", "finest", "sky"},
	help = "show the grid instead of the scene: solid cells shaded by face with their edges drawn and tinted by level (finest only the 10 cm level), bricks that are not built yet in red. sky colours each cell by how far the air in front of it is from open sky, from cyan in the open over yellow and red to dark red for air the sky cannot reach",
}
pvars.EndGroup()

function air_grid.GetDebugView()
	return DEBUG_VIEWS[debug_view:Get()]
end

local int32_ptr_t = ffi.typeof("int32_t *")
local state

function air_grid.Reset()
	if state and state.pipeline then state.pipeline:Remove() end

	if state and state.field_pipeline then state.field_pipeline:Remove() end

	state = nil
end

local function get_frame_span()
	return math.max(render.GetSwapchainImageCount() or 1, 1)
end

local function level_brick_size(level)
	return cell:Get() * 2 ^ level * air_grid.BRICK
end

local function slot_index(x, y, z)
	return (bit.band(z, 7) * 8 + bit.band(y, 7)) * 8 + bit.band(x, 7)
end

local function build_pipeline(radius)
	local D = air_grid.BRICK + 4 * radius
	return EasyPipeline.Compute{
		name = "air_grid_voxelize",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 256, y = 1, z = 1},
		descriptor_sets = {
			{type = "acceleration_structure_khr", binding_index = 0, stageFlags = "compute"},
		},
		block = {
			{"jobs", "uint64_t"},
			{"bits", "uint64_t"},
			{"cell", "float"},
		},
		write = function(self, block)
			block.jobs = state.job_address
			block.bits = state.bits_address
			block.cell = cell:Get()
			return block
		end,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) uniform accelerationStructureEXT air_tlas;
		]],
		shader = [[
			layout(buffer_reference, scalar) readonly buffer AirJobs { ivec4 j[]; };
			layout(buffer_reference, scalar) buffer AirBits { uint w[]; };

			#define R ]] .. radius .. [[

			#define D ]] .. D .. [[

			#define APRON (2 * R)
			#define MASK ]] .. string.format("0x%02Xu", instances.MASK_GI_SOLID) .. [[

			shared uint s_a[D * D * 2];
			shared uint s_b[D * D * 2];

			const uint64_t ROW_MASK = D == 64 ? ~0ul : ((1ul << uint64_t(D)) - 1ul);

			uint64_t row_a(int r) { return packUint2x32(uvec2(s_a[r * 2], s_a[r * 2 + 1])); }
			uint64_t row_b(int r) { return packUint2x32(uvec2(s_b[r * 2], s_b[r * 2 + 1])); }
			void set_a(int r, uint64_t v) { uvec2 u = unpackUint2x32(v & ROW_MASK); s_a[r * 2] = u.x; s_a[r * 2 + 1] = u.y; }
			void set_b(int r, uint64_t v) { uvec2 u = unpackUint2x32(v & ROW_MASK); s_b[r * 2] = u.x; s_b[r * 2 + 1] = u.y; }

			// rows are indexed by z * D + y and hold x in their bits
			void grow_x(bool grow) {
				for (int r = int(gl_LocalInvocationIndex); r < D * D; r += 256) {
					uint64_t v = row_a(r);
					set_b(r, grow ? (v | (v << 1) | (v >> 1)) : (v & ((v << 1) | 1ul) & ((v >> 1) | (1ul << uint64_t(D - 1)))));
				}
			}

			void grow_y(bool grow) {
				for (int r = int(gl_LocalInvocationIndex); r < D * D; r += 256) {
					int y = r % D;
					uint64_t v = row_b(r);
					uint64_t lo = y > 0 ? row_b(r - 1) : (grow ? 0ul : ~0ul);
					uint64_t hi = y < D - 1 ? row_b(r + 1) : (grow ? 0ul : ~0ul);
					set_a(r, grow ? (v | lo | hi) : (v & lo & hi));
				}
			}

			void grow_z(bool grow) {
				for (int r = int(gl_LocalInvocationIndex); r < D * D; r += 256) {
					int z = r / D;
					uint64_t v = row_a(r);
					uint64_t lo = z > 0 ? row_a(r - D) : (grow ? 0ul : ~0ul);
					uint64_t hi = z < D - 1 ? row_a(r + D) : (grow ? 0ul : ~0ul);
					set_b(r, grow ? (v | lo | hi) : (v & lo & hi));
				}
			}

			void copy_b_to_a() {
				for (int i = int(gl_LocalInvocationIndex); i < D * D * 2; i += 256) s_a[i] = s_b[i];
			}

			void main() {
				ivec4 job = AirJobs(compute.jobs).j[gl_WorkGroupID.x];
				int level = job.w;
				float cs = compute.cell * float(1 << level);
				ivec3 brick = job.xyz;
				vec3 base = vec3(brick * 32 - APRON) * cs;

				for (int i = int(gl_LocalInvocationIndex); i < D * D * 2; i += 256) s_a[i] = 0u;

				barrier();

				for (int line = int(gl_LocalInvocationIndex); line < 3 * D * D; line += 256) {
					int axis = line / (D * D);
					int u = line % D;
					int v = (line / D) % D;
					ivec3 fixed_cell = axis == 0 ? ivec3(0, u, v) : axis == 1 ? ivec3(u, 0, v) : ivec3(u, v, 0);
					vec3 dir = axis == 0 ? vec3(1, 0, 0) : axis == 1 ? vec3(0, 1, 0) : vec3(0, 0, 1);
					vec3 origin = base + (vec3(fixed_cell) + 0.5 * (1.0 - dir)) * cs;
					float len = float(D) * cs;
					float t_min = 0.0;

					for (int k = 0; k < D; k++) {
						rayQueryEXT query;
						rayQueryInitializeEXT(query, air_tlas, gl_RayFlagsOpaqueEXT, MASK, origin, t_min, dir, len);

						while (rayQueryProceedEXT(query)) {}

						if (rayQueryGetIntersectionTypeEXT(query, true) == gl_RayQueryCommittedIntersectionNoneEXT) break;

						int index = min(int(rayQueryGetIntersectionTEXT(query, true) / cs), D - 1);
						ivec3 c = fixed_cell;
						c[axis] = index;
						atomicOr(s_a[(c.z * D + c.y) * 2 + (c.x >> 5)], 1u << uint(c.x & 31));
						t_min = float(index + 1) * cs;

						if (t_min >= len) break;
					}
				}

				barrier();

				for (int i = 0; i < R; i++) {
					grow_x(true); barrier();
					grow_y(true); barrier();
					grow_z(true); barrier();
					copy_b_to_a(); barrier();
				}

				for (int i = 0; i < R; i++) {
					grow_x(false); barrier();
					grow_y(false); barrier();
					grow_z(false); barrier();
					copy_b_to_a(); barrier();
				}

				ivec3 s = brick & 7;
				uint slot = uint(level * 512 + (s.z * 8 + s.y) * 8 + s.x);
				AirBits out_bits = AirBits(compute.bits);

				for (int r = int(gl_LocalInvocationIndex); r < 1024; r += 256) {
					int y = r % 32;
					int z = r / 32;
					uint64_t v = row_a((z + APRON) * D + y + APRON);
					out_bits.w[slot * 1024u + uint(r)] = uint(v >> uint64_t(APRON));
				}
			}
		]],
	}
end

local function build_field_pipeline()
	return EasyPipeline.Compute{
		name = "air_grid_field",
		DescriptorSetCount = get_frame_span(),
		LocalSize = {x = 64, y = 1, z = 1},
		descriptor_sets = {
			{type = "acceleration_structure_khr", binding_index = 0, stageFlags = "compute"},
		},
		block = {
			{"bits", "uint64_t"},
			{"table", "uint64_t"},
			{"dst", "uint64_t"},
			{"coarse", "uint64_t"},
			{"cell", "float"},
			{"level", "int"},
			{"mode", "int"},
			{"axis", "int"},
			{"dir", "int"},
			{"origin_x", "int"},
			{"origin_y", "int"},
			{"origin_z", "int"},
			{"coarse_x", "int"},
			{"coarse_y", "int"},
			{"coarse_z", "int"},
		},
		write = function(self, block)
			for key, value in pairs(state.field_params) do
				block[key] = value
			end

			return block
		end,
		custom_declarations = [[
			#extension GL_EXT_ray_query : require
			layout(set = 0, binding = 0) uniform accelerationStructureEXT air_tlas;
		]],
		shader = [[
			layout(buffer_reference, scalar) readonly buffer FieldBits { uint w[]; };
			layout(buffer_reference, scalar) readonly buffer FieldTable { ivec4 e[]; };
			layout(buffer_reference, scalar) buffer FieldData { uint w[]; };

			#define N ]] .. air_grid.FIELD .. [[

			#define SOLID 255u
			#define FAR 254u
			#define MASK ]] .. string.format("0x%02Xu", instances.MASK_GI_SOLID) .. [[

			uint field_index(ivec3 h) {
				return uint((h.z * N + h.y) * N + h.x);
			}

			uint read_value(FieldData field, uint i) {
				return (field.w[i >> 2] >> ((i & 3u) * 8u)) & 255u;
			}

			// a field cell is 2x2x2 grid cells and never straddles a brick
			bool any_solid(ivec3 fine) {
				ivec3 brick = fine >> 5;
				ivec3 s = brick & 7;
				int slot = compute.level * 512 + (s.z * 8 + s.y) * 8 + s.x;
				ivec4 entry = FieldTable(compute.table).e[slot];

				if (entry.w == 0 || entry.xyz != brick) return false;

				ivec3 l = fine & 31;
				FieldBits bits = FieldBits(compute.bits);
				uint base = uint(slot) * 1024u;
				uint rows = bits.w[base + uint(l.z * 32 + l.y)] | bits.w[base + uint(l.z * 32 + l.y + 1)] | bits.w[base + uint((l.z + 1) * 32 + l.y)] | bits.w[base + uint((l.z + 1) * 32 + l.y + 1)];
				return (rows & (3u << uint(l.x))) != 0u;
			}

			uint relax(uint v, inout uint prev) {
				if (v == SOLID) {
					prev = SOLID;
					return v;
				}

				if (prev != SOLID) v = min(v, min(prev + 1u, FAR));

				prev = v;
				return v;
			}

			void main() {
				uint id = gl_GlobalInvocationID.x;
				FieldData field = FieldData(compute.dst);
				ivec3 origin = ivec3(compute.origin_x, compute.origin_y, compute.origin_z);

				if (compute.mode == 0) {
					if (id >= uint(N * N * N / 4)) return;

					uint packed = 0u;

					for (uint k = 0u; k < 4u; k++) {
						uint i = id * 4u + k;
						ivec3 h = ivec3(int(i) % N, (int(i) / N) % N, int(i) / (N * N));
						ivec3 world = origin + h;
						uint v = FAR;

						if (any_solid(world * 2)) {
							v = SOLID;
						} else if (compute.coarse != 0ul && (any(equal(h, ivec3(0))) || any(equal(h, ivec3(N - 1))))) {
							// the border has no neighbours outside, it starts from the coarser level's distance
							ivec3 ch = (world >> 1) - ivec3(compute.coarse_x, compute.coarse_y, compute.coarse_z);

							if (all(greaterThanEqual(ch, ivec3(0))) && all(lessThan(ch, ivec3(N)))) {
								uint cv = read_value(FieldData(compute.coarse), field_index(ch));

								if (cv < FAR) v = min(cv * 2u + 1u, FAR);
							}
						}

						packed |= v << (k * 8u);
					}

					field.w[id] = packed;
				} else if (compute.mode == 1) {
					if (id >= uint(N * N)) return;

					ivec2 xz = ivec2(int(id) % N, int(id) / N);
					vec3 top = (vec3(origin + ivec3(xz.x, N, xz.y)) + vec3(0.5, 0.0, 0.5)) * compute.cell;
					rayQueryEXT query;
					rayQueryInitializeEXT(query, air_tlas, gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT, MASK, top, 0.0, vec3(0.0, 1.0, 0.0), 1e5);

					while (rayQueryProceedEXT(query)) {}

					if (rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT) return;

					for (int y = N - 1; y >= 0; y--) {
						uint i = field_index(ivec3(xz.x, y, xz.y));
						uint shift = (i & 3u) * 8u;

						if (((field.w[i >> 2] >> shift) & 255u) == SOLID) break;

						atomicAnd(field.w[i >> 2], ~(255u << shift));
					}
				} else if (compute.axis == 0) {
					if (id >= uint(N * N)) return;

					int y = int(id) % N;
					int z = int(id) / N;
					uint prev = SOLID;

					for (int n = 0; n < N; n++) {
						int x = compute.dir > 0 ? n : N - 1 - n;
						uint i = field_index(ivec3(x, y, z));
						uint shift = (i & 3u) * 8u;
						uint word = field.w[i >> 2];
						uint v = relax((word >> shift) & 255u, prev);
						field.w[i >> 2] = (word & ~(255u << shift)) | (v << shift);
					}
				} else {
					if (id >= uint(N / 4 * N)) return;

					// a thread runs four neighbouring columns at once, the four values one word holds
					int x4 = int(id) % (N / 4);
					int other = int(id) / (N / 4);
					uint prev[4] = uint[4](SOLID, SOLID, SOLID, SOLID);

					for (int n = 0; n < N; n++) {
						int along = compute.dir > 0 ? n : N - 1 - n;
						ivec3 h = compute.axis == 1 ? ivec3(x4 * 4, along, other) : ivec3(x4 * 4, other, along);
						uint word_index = field_index(h) >> 2;
						uint word = field.w[word_index];
						uint result = 0u;

						for (int k = 0; k < 4; k++) {
							result |= relax((word >> uint(k * 8)) & 255u, prev[k]) << uint(k * 8);
						}

						field.w[word_index] = result;
					}
				}
			}
		]],
	}
end

local function get_state()
	if state then return state end

	local levels = {}

	for level = 0, air_grid.LEVELS - 1 do
		levels[level] = {origin = {math.huge, math.huge, math.huge}, keys = {}, dirty = {}, version = 0}
	end

	local bits = render.CreateBuffer{
		byte_size = air_grid.LEVELS * SLOTS * BRICK_WORDS * 4,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"device_local"},
		label = "air_grid_bits",
	}
	local tables, jobs = {}, {}

	for i = 1, RING do
		tables[i] = render.CreateBuffer{
			byte_size = air_grid.LEVELS * SLOTS * 16,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "air_grid_table",
		}
		jobs[i] = render.CreateBuffer{
			byte_size = MAX_JOBS * 16,
			buffer_usage = {"storage_buffer", "shader_device_address"},
			memory_property = {"host_visible", "host_coherent"},
			label = "air_grid_jobs",
		}
	end

	local order = {}

	for z = 0, 7 do
		for y = 0, 7 do
			for x = 0, 7 do
				list.insert(order, {x, y, z, (x - 3.5) ^ 2 + (y - 3.5) ^ 2 + (z - 3.5) ^ 2})
			end
		end
	end

	table.sort(order, function(a, b)
		return a[4] < b[4]
	end)

	local field_buffers = {}

	for i = 1, 2 do
		field_buffers[i] = render.CreateBuffer{
			byte_size = air_grid.LEVELS * FIELD_BYTES,
			buffer_usage = {"storage_buffer", "shader_device_address", "transfer_src"},
			memory_property = {"device_local"},
			label = "air_grid_field",
		}
	end

	local field_levels = {}

	for level = 0, air_grid.LEVELS - 1 do
		field_levels[level] = {current = 0, origin = {0, 0, 0}, version = -1, published_serial = -math.huge}
	end

	state = {
		field_buffers = field_buffers,
		field_addresses = {field_buffers[1]:GetDeviceAddress(), field_buffers[2]:GetDeviceAddress()},
		field_levels = field_levels,
		field_pipeline = build_field_pipeline(),
		field_params = {},
		levels = levels,
		bits = bits,
		bits_address = bits:GetDeviceAddress(),
		tables = tables,
		jobs = jobs,
		job_address = 0,
		table_address = 0,
		order = order,
		dirty_queue = bridge.CreateDirtyQueue(true),
		pipeline = build_pipeline(close_radius:Get()),
		built = 0,
	}
	return state
end

local function mark_dirty_box(box)
	for level = 0, air_grid.LEVELS - 1 do
		local info = state.levels[level]
		local size = level_brick_size(level)
		local apron = size / air_grid.BRICK * 2 * close_radius:Get()

		for z = math.floor((box[3] - apron) / size), math.floor((box[6] + apron) / size) do
			for y = math.floor((box[2] - apron) / size), math.floor((box[5] + apron) / size) do
				for x = math.floor((box[1] - apron) / size), math.floor((box[4] + apron) / size) do
					local key = info.keys[slot_index(x, y, z)]

					if key and key[1] == x and key[2] == y and key[3] == z then
						info.dirty[slot_index(x, y, z)] = true
					end
				end
			end
		end
	end
end

function air_grid.Update(cmd)
	if not (air_grid.enabled:Get() and render.GetDevice().ray_query_supported) then
		return
	end

	local tlas = scene_rt.GetTLAS(cmd)

	if not tlas then return end

	local s = get_state()
	local cam = render3d.GetCamera():GetPosition()
	local all, boxes = bridge.ConsumeDirty(s.dirty_queue)

	if all then
		for level = 0, air_grid.LEVELS - 1 do
			for slot in pairs(s.levels[level].keys) do
				s.levels[level].dirty[slot] = true
			end
		end
	else
		for _, box in ipairs(boxes) do
			mark_dirty_box(box)
		end
	end

	local ring = render.frame_serial % RING + 1
	local job_ptr = ffi.cast(int32_ptr_t, s.jobs[ring]:Map())
	local budget = math.min(bricks_per_frame:Get(), MAX_JOBS)
	local count = 0

	for level = 0, air_grid.LEVELS - 1 do
		local info = s.levels[level]
		local size = level_brick_size(level)
		info.origin[1] = math.floor(cam.x / size + 0.5) - 4
		info.origin[2] = math.floor(cam.y / size + 0.5) - 4
		info.origin[3] = math.floor(cam.z / size + 0.5) - 4
	end

	-- missing bricks are holes and come before dirty ones, which still hold usable cells. levels take turns
	-- so a camera jump or a busy finest level does not starve the coarse ones
	for pass = 1, 2 do
		local active = true

		for level = 0, air_grid.LEVELS - 1 do
			s.levels[level].scan = 1
		end

		while active and count < budget do
			active = false

			for level = 0, air_grid.LEVELS - 1 do
				if count >= budget then break end

				local info = s.levels[level]
				local ox, oy, oz = info.origin[1], info.origin[2], info.origin[3]

				while info.scan <= SLOTS do
					local offset = s.order[info.scan]
					info.scan = info.scan + 1
					local x, y, z = ox + offset[1], oy + offset[2], oz + offset[3]
					local slot = slot_index(x, y, z)
					local key = info.keys[slot]
					local missing = not key or key[1] ~= x or key[2] ~= y or key[3] ~= z

					if pass == 1 and missing or pass == 2 and not missing and info.dirty[slot] then
						local o = count * 4
						job_ptr[o], job_ptr[o + 1], job_ptr[o + 2], job_ptr[o + 3] = x, y, z, level
						info.keys[slot] = {x, y, z}
						info.dirty[slot] = nil
						info.version = info.version + 1
						count = count + 1
						active = true

						break
					end
				end
			end
		end
	end

	local table_ptr = ffi.cast(int32_ptr_t, s.tables[ring]:Map())

	for level = 0, air_grid.LEVELS - 1 do
		local keys = s.levels[level].keys

		for slot = 0, SLOTS - 1 do
			local key = keys[slot]
			local o = (level * SLOTS + slot) * 4

			if key then
				table_ptr[o], table_ptr[o + 1], table_ptr[o + 2], table_ptr[o + 3] = key[1], key[2], key[3], 1
			else
				table_ptr[o + 3] = 0
			end
		end
	end

	s.table_address = s.tables[ring]:GetDeviceAddress()
	s.job_address = s.jobs[ring]:GetDeviceAddress()
	s.last_jobs = count
	local slot = ((render.GetCurrentFrame() or 1) - 1) % get_frame_span() + 1
	cmd:PipelineBarrier{srcStage = "all_commands", dstStage = "compute", memoryBarrier = true}

	if count > 0 then
		local pipeline = s.pipeline
		pipeline:UpdateDescriptorSet("acceleration_structure_khr", slot, 0, 0, tlas)
		gpu_timing.BeginScope(cmd, "air_grid", "lighting")
		pipeline:Dispatch(cmd, count, 1, 1, slot)
		gpu_timing.EndScope(cmd, "air_grid")
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
		s.built = s.built + count
	end

	air_grid.UpdateField(cmd, s, slot, tlas)
	cmd:PipelineBarrier{srcStage = "compute", dstStage = "all_commands", memoryBarrier = true}
end

-- the distance from open sky is computed one level at a time from scratch into the buffer readers are not
-- using, coarse before fine so finer levels can start their borders from it, and published when done
function air_grid.UpdateField(cmd, s, slot, tlas)
	local job = s.field_job
	local N = air_grid.FIELD

	if not job then
		-- levels take turns from coarse to fine, a level whose bricks keep changing must not starve the others
		for i = 0, air_grid.LEVELS - 1 do
			local level = ((s.field_next or air_grid.LEVELS - 1) - i) % air_grid.LEVELS
			local info = s.levels[level]
			local field = s.field_levels[level]
			local ox, oy, oz = info.origin[1] * 16, info.origin[2] * 16, info.origin[3] * 16

			-- the buffer a rebuild writes was published before this one, and frames still in flight (the gi on the async
			-- compute queue) may read it: a half built field reads open ground as enclosed and drops the sun there
			if
				render.frame_serial - field.published_serial >= RING and
				(
					field.current == 0 or
					field.version ~= info.version or
					field.origin[1] ~= ox or
					field.origin[2] ~= oy or
					field.origin[3] ~= oz
				)
			then
				job = {
					level = level,
					stage = 0,
					target = field.current == 1 and 2 or 1,
					origin = {ox, oy, oz},
					version = info.version,
				}
				s.field_job = job
				s.field_next = level - 1

				break
			end
		end

		if not job then return end
	end

	local level = job.level
	local coarse = level < air_grid.LEVELS - 1 and s.field_levels[level + 1]
	local params = s.field_params
	params.bits = s.bits_address
	params.table = s.table_address
	params.dst = s.field_addresses[job.target] + level * FIELD_BYTES
	params.coarse = coarse and
		coarse.current ~= 0 and
		s.field_addresses[coarse.current] + (
			level + 1
		) * FIELD_BYTES or
		0
	params.cell = cell:Get() * 2 ^ (level + 1)
	params.level = level
	params.origin_x, params.origin_y, params.origin_z = job.origin[1], job.origin[2], job.origin[3]
	params.coarse_x = coarse and coarse.origin[1] or 0
	params.coarse_y = coarse and coarse.origin[2] or 0
	params.coarse_z = coarse and coarse.origin[3] or 0
	local pipeline = s.field_pipeline
	pipeline:UpdateDescriptorSet("acceleration_structure_khr", slot, 0, 0, tlas)
	gpu_timing.BeginScope(cmd, "air_grid_field", "lighting")

	if job.stage == 0 then
		params.mode, params.axis, params.dir = 0, 0, 1
		pipeline:Dispatch(cmd, N * N * N / 4 / 64, 1, 1, slot)
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
		params.mode = 1
		pipeline:Dispatch(cmd, N * N / 64, 1, 1, slot)
		cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
	else
		params.mode = 2

		for axis = 0, 2 do
			for _, dir in ipairs({1, -1}) do
				params.axis, params.dir = axis, dir
				pipeline:Dispatch(cmd, (axis == 0 and N * N or N / 4 * N) / 64, 1, 1, slot)
				cmd:PipelineBarrier{srcStage = "compute", dstStage = "compute", memoryBarrier = true}
			end
		end
	end

	gpu_timing.EndScope(cmd, "air_grid_field")
	job.stage = job.stage + 1

	if job.stage > field_rounds:Get() then
		local field = s.field_levels[level]
		field.current = job.target
		field.origin = job.origin
		field.version = job.version
		field.published_serial = render.frame_serial
		s.field_job = nil
	end
end

function air_grid.GetState()
	return state
end

function air_grid.GetPendingCount()
	if not state then return math.huge end

	local pending = 0

	for level = 0, air_grid.LEVELS - 1 do
		local info = state.levels[level]
		local ox, oy, oz = info.origin[1], info.origin[2], info.origin[3]

		for _, offset in ipairs(state.order) do
			local x, y, z = ox + offset[1], oy + offset[2], oz + offset[3]
			local slot = slot_index(x, y, z)
			local key = info.keys[slot]

			if not key or key[1] ~= x or key[2] ~= y or key[3] ~= z or info.dirty[slot] then
				pending = pending + 1
			end
		end
	end

	return pending
end

function air_grid.GetBlockLayout()
	return {
		{"air_grid_bits", "uint64_t"},
		{"air_grid_table", "uint64_t"},
		{"air_grid_origin", "vec4", air_grid.LEVELS},
		{"air_grid_field_a", "uint64_t"},
		{"air_grid_field_b", "uint64_t"},
		{"air_grid_field_origin", "vec4", air_grid.LEVELS},
		{"air_grid_cell", "float"},
		{"air_grid_probe_visibility", "int"},
		{"air_grid_ray_check", "int"},
	}
end

function air_grid.WriteBlock(block)
	local ready = state and state.table_address ~= 0 and air_grid.enabled:Get()
	block.air_grid_bits = ready and state.bits_address or 0
	block.air_grid_table = ready and state.table_address or 0
	block.air_grid_cell = cell:Get()
	block.air_grid_probe_visibility = air_grid.probe_visibility:Get() and 1 or 0
	block.air_grid_ray_check = ready and air_grid.ray_check:Get() and 1 or 0
	block.air_grid_field_a = ready and state.field_addresses[1] or 0
	block.air_grid_field_b = ready and state.field_addresses[2] or 0

	for level = 0, air_grid.LEVELS - 1 do
		local field = ready and state.field_levels[level]

		if field and field.current ~= 0 then
			block.air_grid_field_origin[level][0] = field.origin[1]
			block.air_grid_field_origin[level][1] = field.origin[2]
			block.air_grid_field_origin[level][2] = field.origin[3]
			block.air_grid_field_origin[level][3] = field.current
		else
			block.air_grid_field_origin[level][3] = 0
		end
	end

	for level = 0, air_grid.LEVELS - 1 do
		local origin = ready and state.levels[level].origin

		if origin and origin[1] ~= math.huge then
			block.air_grid_origin[level][0] = origin[1]
			block.air_grid_origin[level][1] = origin[2]
			block.air_grid_origin[level][2] = origin[3]
			block.air_grid_origin[level][3] = 1
		else
			block.air_grid_origin[level][3] = 0
		end
	end
end

function air_grid.GetGLSL(block_name)
	return (
		[[
		#ifndef AIR_GRID_GLSL
		#define AIR_GRID_GLSL
		#define AIR_GRID_LEVELS ]] .. air_grid.LEVELS .. [[

		#define AIR_GRID_MAX_STEPS ]] .. air_grid.MAX_STEPS .. [[.0
		#define AIR_GRID_UNKNOWN -1.0
		#define AIR_GRID_EMBEDDED -2.0
		#define AIR_GRID_CLEAR 2.0
		layout(buffer_reference, scalar) readonly buffer AirGridBits { uint w[]; };
		layout(buffer_reference, scalar) readonly buffer AirGridTable { ivec4 e[]; };
		layout(buffer_reference, scalar) readonly buffer AirGridField { uint w[]; };
		#define AIR_GRID_FIELD ]] .. air_grid.FIELD .. [[

		#define AIR_GRID_FIELD_BYTES ]] .. FIELD_BYTES .. [[ul
		#define AIR_GRID_SOLID 255
		#define AIR_GRID_FAR 254

		bool air_grid_available() {
			return $B.air_grid_bits != 0ul;
		}

		float air_grid_cell_size(int level) {
			return $B.air_grid_cell * float(1 << level);
		}

		int air_grid_slot(int level, ivec3 brick) {
			ivec4 origin = ivec4($B.air_grid_origin[level]);

			if (origin.w == 0 || any(lessThan(brick, origin.xyz)) || any(greaterThanEqual(brick, origin.xyz + 8))) return -1;

			ivec3 s = brick & 7;
			int slot = level * 512 + (s.z * 8 + s.y) * 8 + s.x;
			ivec4 entry = AirGridTable($B.air_grid_table).e[slot];
			return entry.w != 0 && entry.xyz == brick ? slot : -1;
		}

		float air_grid_field_cell(int level) {
			return $B.air_grid_cell * float(2 << level);
		}

		// distance from open sky through air in field cells (2x2x2 grid cells) of the level, AIR_GRID_FAR where
		// the sky is out of reach, AIR_GRID_SOLID in solid cells and -1 outside the level's field
		int air_grid_sky_distance(int level, vec3 p) {
			vec4 origin = $B.air_grid_field_origin[level];

			if (origin.w == 0.0) return -1;

			ivec3 h = ivec3(floor(p / air_grid_field_cell(level))) - ivec3(origin.xyz);

			if (any(lessThan(h, ivec3(0))) || any(greaterThanEqual(h, ivec3(AIR_GRID_FIELD)))) return -1;

			uint i = uint((h.z * AIR_GRID_FIELD + h.y) * AIR_GRID_FIELD + h.x);
			uint64_t base = (origin.w == 1.0 ? $B.air_grid_field_a : $B.air_grid_field_b) + uint64_t(level) * AIR_GRID_FIELD_BYTES;
			return int((AirGridField(base).w[i >> 2] >> ((i & 3u) * 8u)) & 255u);
		}

		// the air a surface point a with normal n is in, seen along v (toward the camera or back along the ray that
		// found it), or a point in air with both zero. v sees the point through air, so the air is looked for
		// along it first: the normal can point through a floor a sphere rests on, or into the other wall in a
		// corner. false when the grid cannot tell
		bool air_grid_reference(vec3 a, vec3 n, vec3 v, out int level, out int d, out vec3 p) {
			vec3 first = v != vec3(0.0) ? v : n;

			for (level = 0; level < AIR_GRID_LEVELS; level++) {
				float fc = air_grid_field_cell(level);
				p = a + first * fc;
				d = air_grid_sky_distance(level, p);

				if (d < 0) continue;

				for (int k = 2; k <= 3 && d == AIR_GRID_SOLID; k++) {
					p = a + first * (float(k) * fc);
					d = air_grid_sky_distance(level, p);
				}

				for (int k = 1; k <= 3 && d == AIR_GRID_SOLID && first != n; k++) {
					p = a + n * (float(k) * fc);
					d = air_grid_sky_distance(level, p);
				}

				// still in a wall's cell (a crease, a point with no direction): the neighbouring air further from
				// open sky, so a point the grid cannot place never takes the outdoor side. a surface point only looks
				// on its own side: behind it is the inside of whatever it is the surface of, which reads as sealed air
				for (int k = 1; k <= 2 && d == AIR_GRID_SOLID; k++) {
					int best = -1;
					vec3 best_p = p;

					for (int axis = 0; axis < 6; axis++) {
						vec3 dir = vec3(0.0);
						dir[axis >> 1] = (axis & 1) == 0 ? 1.0 : -1.0;

						if (first != vec3(0.0) && dot(dir, n) <= 0.0 && dot(dir, v) <= 0.0) continue;

						vec3 q = a + dir * (float(k) * fc);
						int qd = air_grid_sky_distance(level, q);

						if (qd >= 0 && qd != AIR_GRID_SOLID && qd > best) {
							best = qd;
							best_p = q;
						}
					}

					if (best >= 0) {
						d = best;
						p = best_p;
					}
				}

				return d != AIR_GRID_SOLID;
			}

			return false;
		}

		// the distance from open sky changes by at most the distance travelled through air, so b cannot be reached
		// from p through air when it is closer to open sky by more than the distance between them. light leaks from
		// the open side, and a reference that landed on the wrong side of a thin wall must not reject the dark one
		// instead. p is a point in air from air_grid_reference
		bool air_grid_unreachable(vec3 p, vec3 b) {
			for (int level = 0; level < AIR_GRID_LEVELS; level++) {
				int da = air_grid_sky_distance(level, p);
				int db = air_grid_sky_distance(level, b);

				if (da < 0 || db < 0) continue;

				if (da == AIR_GRID_SOLID || db == AIR_GRID_SOLID) return false;

				float fc = air_grid_field_cell(level);
				ivec3 moved = abs(ivec3(floor(b / fc)) - ivec3(floor(p / fc)));
				return da - db > moved.x + moved.y + moved.z + 2;
			}

			return false;
		}

		// where the distance from open sky jumps by more along a ray than the ray travelled, the ray went through
		// a wall the grid has sealed: a crack between meshes the ray tracer let it through. returns how far along
		// the ray the jump was found, or -1. a, n and v as for air_grid_reference
		float air_grid_ray_wall_distance(vec3 a, vec3 n, vec3 v, vec3 dir, float len) {
			if ($B.air_grid_ray_check == 0) return -1.0;

			int level;
			int previous;
			vec3 start;

			// light leaking out of enclosed air is the problem, a ray from open air has nothing to leak into
			if (!air_grid_reference(a, n, v, level, previous, start) || previous == 0) return -1.0;

			float fc = air_grid_field_cell(level);
			vec3 previous_p = start;
			float along = 0.0;
			float reach = len - fc;

			// a ray that leaves a level's field goes on in the next coarser one, the last sample read again there
			for (int i = 0; i < 64 && along < reach; i++) {
				along = min(along + 4.0 * fc, reach);
				vec3 q = start + dir * along;
				int d = air_grid_sky_distance(level, q);

				while (d < 0 && level < AIR_GRID_LEVELS - 1) {
					level++;
					fc = air_grid_field_cell(level);
					previous = air_grid_sky_distance(level, previous_p);
					d = air_grid_sky_distance(level, q);
				}

				if (d < 0 || previous < 0) return -1.0;

				if (previous == AIR_GRID_SOLID) {
					previous = d;
					previous_p = q;
					continue;
				}

				if (d != AIR_GRID_SOLID) {
					ivec3 moved = abs(ivec3(floor(q / fc)) - ivec3(floor(previous_p / fc)));

					if (abs(d - previous) > moved.x + moved.y + moved.z + 2) return along;

					if (d == 0) return -1.0;

					previous = d;
					previous_p = q;
				}
			}

			return -1.0;
		}

		bool air_grid_ray_crosses_wall(vec3 a, vec3 n, vec3 v, vec3 dir, float len) {
			return air_grid_ray_wall_distance(a, n, v, dir, len) >= 0.0;
		}

		// -1 when the brick is not built, 0 air, 1 solid
		int air_grid_cell_state(int level, ivec3 c) {
			int slot = air_grid_slot(level, c >> 5);

			if (slot < 0) return -1;

			ivec3 local_cell = c & 31;
			uint word = AirGridBits($B.air_grid_bits).w[uint(slot) * 1024u + uint(local_cell.z * 32 + local_cell.y)];
			return int((word >> uint(local_cell.x)) & 1u);
		}

		// fraction along the segment to b where the first solid cell starts, AIR_GRID_CLEAR when there is none and
		// AIR_GRID_UNKNOWN when no level covers it. a surface point a is pushed off along its normal n until it
		// is in an air cell; a cell cannot tell which side of a wall in it a point is on, so an end that stays
		// in a solid cell (a corner, a probe against a wall) is AIR_GRID_EMBEDDED rather than skipped. without
		// march only the ends are looked at, and a segment with both ends in air is AIR_GRID_UNKNOWN
		float air_grid_segment(vec3 a, vec3 n, vec3 b, bool march) {
			if (!air_grid_available()) return AIR_GRID_UNKNOWN;

			float len = length(b - a);

			if (!(len > 1e-4)) return AIR_GRID_CLEAR;

			int level = 0;

			while (level < AIR_GRID_LEVELS - 1 && len > AIR_GRID_MAX_STEPS * air_grid_cell_size(level)) level++;

			for (; level < AIR_GRID_LEVELS; level++) {
				float cs = air_grid_cell_size(level);
				ivec3 end_cell = ivec3(floor(b / cs));
				int end_state = air_grid_cell_state(level, end_cell);

				if (end_state < 0) continue;

				if (end_state > 0) return AIR_GRID_EMBEDDED;

				vec3 start = a + n * (0.75 * cs);
				int start_state = air_grid_cell_state(level, ivec3(floor(start / cs)));

				if (start_state > 0 && n != vec3(0.0)) {
					start = a + n * (1.75 * cs);
					start_state = air_grid_cell_state(level, ivec3(floor(start / cs)));
				}

				if (start_state < 0) continue;

				if (start_state > 0) return AIR_GRID_EMBEDDED;

				if (!march) return AIR_GRID_UNKNOWN;

				vec3 pa = start / cs;
				vec3 d = (b - start) / cs;
				ivec3 c = ivec3(floor(pa));
				ivec3 step_dir = ivec3(sign(d));
				vec3 inv = 1.0 / max(abs(d), vec3(1e-9));
				vec3 t_max = (step(0.0, d) * (vec3(c) + 1.0 - pa) + step(d, vec3(0.0)) * (pa - vec3(c))) * inv;
				t_max = mix(t_max, vec3(1e30), equal(step_dir, ivec3(0)));
				vec3 t_delta = mix(inv, vec3(1e30), equal(step_dir, ivec3(0)));
				int count = abs(end_cell.x - c.x) + abs(end_cell.y - c.y) + abs(end_cell.z - c.z);
				ivec3 brick = ivec3(-2147483647);
				int slot = -1;
				bool known = true;
				float t = 0.0;

				for (int i = 0; i <= count && i < int(AIR_GRID_MAX_STEPS) * 2; i++) {
					ivec3 cell_brick = c >> 5;

					if (cell_brick != brick) {
						brick = cell_brick;
						slot = air_grid_slot(level, brick);

						if (slot < 0) {
							known = false;
							break;
						}
					}

					ivec3 local_cell = c & 31;
					uint word = AirGridBits($B.air_grid_bits).w[uint(slot) * 1024u + uint(local_cell.z * 32 + local_cell.y)];

					if ((word & (1u << uint(local_cell.x))) != 0u) return t;

					if (t_max.x < t_max.y && t_max.x < t_max.z) {
						t = t_max.x;
						t_max.x += t_delta.x;
						c.x += step_dir.x;
					} else if (t_max.y < t_max.z) {
						t = t_max.y;
						t_max.y += t_delta.y;
						c.y += step_dir.y;
					} else {
						t = t_max.z;
						t_max.z += t_delta.z;
						c.z += step_dir.z;
					}
				}

				if (known) return AIR_GRID_CLEAR;
			}

			return AIR_GRID_UNKNOWN;
		}
		#endif
	]]
	):gsub("%$B", block_name)
end

return air_grid
