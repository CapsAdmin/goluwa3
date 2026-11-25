local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local pvars = import("goluwa/cli/pvars.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Material = import("goluwa/render3d/material.lua")
local decal_projection = import("goluwa/render3d/decal_projection.lua")
local projected_decals = {}
projected_decals.KIND_QUAD = 0
projected_decals.KIND_BOX = 1
projected_decals.RECEIVE_TERRAIN = 1
projected_decals.RECEIVE_STATIC = 2
projected_decals.CELL_SIZE = 8
projected_decals.generation = 0
local MIN_FACING = 0.2
local HEIGHT_MARGIN = 1.5
local RETIRE_FRAMES = 4
local HEADER_WORDS = 8
projected_decals.enabled = pvars.Setup2{
	key = "r_projected_decals",
	category = "Rendering",
	group = "Decals",
	default = true,
	help = "draws terrain, road, object and planar decals by projecting them onto the gbuffer and onto ray hits instead of as meshes lifted off the surface. Brush decals stay meshes",
	callback = function()
		for decal in pairs(projected_decals.GetTracked()) do
			decal:Reproject()
		end

		projected_decals.Invalidate()
	end,
}
local Record = ffi.typeof([[struct {
	float a[4];
	float b[4];
	float c[4];
	float d[4];
	float u[4];
	float v[4];
	float fade[4];
	float color[4];
	int32_t kind;
	int32_t receivers;
	int32_t albedo_tex;
	int32_t normal_tex;
	int32_t roughness_tex;
	int32_t roughness_channel;
	int32_t metallic_tex;
	int32_t metallic_channel;
	float roughness;
	float roughness_min;
	float roughness_max;
	float metallic;
	int32_t border;
	int32_t premultiplied;
	float pad[2];
}]])
local RECORD_SIZE = ffi.sizeof(Record)
local Uint32Array = ffi.typeof("uint32_t[?]")
local Uint32Pointer = ffi.typeof("uint32_t *")
local FloatPointer = ffi.typeof("float *")
local decals = {}
local next_order = 0
local dirty = false
local buffer
local retired = {}

function projected_decals.IsEnabled()
	return projected_decals.enabled:Get()
end

function projected_decals.Add(decal)
	if not decals[decal] then
		next_order = next_order + 1
		decals[decal] = next_order
	end

	projected_decals.Invalidate()
end

function projected_decals.Remove(decal)
	if decals[decal] then
		decals[decal] = nil
		projected_decals.Invalidate()
	end
end

function projected_decals.GetTracked()
	return decals
end

function projected_decals.Invalidate()
	dirty = true
end

local function resolve_material(decal)
	local slots, material = Material.GetOverrideFromPath(decal.Material)
	return slots and slots[0] or material
end

local function lerp_uv(decal, x, y)
	local u_range, v_range = decal.URange, decal.VRange
	return u_range.x + (u_range.y - u_range.x) * (x * 0.5 + 0.5),
	v_range.x + (v_range.y - v_range.x) * (y * 0.5 + 0.5)
end

local function quad(out, corners, us, vs, fades, y_min, y_max, receivers, decal)
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for _, p in ipairs(corners) do
		min_x, max_x = math.min(min_x, p.x), math.max(max_x, p.x)
		min_z, max_z = math.min(min_z, p.z), math.max(max_z, p.z)
	end

	list.insert(
		out,
		{
			kind = projected_decals.KIND_QUAD,
			decal = decal,
			receivers = receivers,
			corners = corners,
			us = us,
			vs = vs,
			fades = fades,
			y_min = y_min,
			y_max = y_max,
			min_x = min_x,
			min_z = min_z,
			max_x = max_x,
			max_z = max_z,
		}
	)
end

local function height_range(height, points, extra)
	local lo, hi = extra or math.huge, extra or -math.huge

	for _, p in ipairs(points) do
		local h = height(p.x, p.z)
		lo, hi = math.min(lo, h), math.max(hi, h)
	end

	return lo - HEIGHT_MARGIN, hi + HEIGHT_MARGIN
end

local function add_terrain(out, decal, height)
	local matrix = decal.Owner.transform:GetWorldMatrix()
	local origin = Vec3(matrix.m30, matrix.m31, matrix.m32)
	local right = Vec3(matrix.m00, 0, matrix.m02)
	local up = Vec3(matrix.m10, 0, matrix.m12)
	local half_x = Vec3(matrix.m00, matrix.m01, matrix.m02):GetLength()
	local half_y = Vec3(matrix.m10, matrix.m11, matrix.m12):GetLength()
	local half_z = Vec3(matrix.m20, matrix.m21, matrix.m22):GetLength()
	local delta = origin.y - height(origin.x, origin.z)

	if delta >= half_z or delta <= -0.5 then return end

	if right:GetLength() < 1e-4 or up:GetLength() < 1e-4 then return end

	right, up = right:GetNormalized(), up:GetNormalized()
	local corners, us, vs = {}, {}, {}

	for i, c in ipairs{{-1, -1}, {1, -1}, {1, 1}, {-1, 1}} do
		corners[i] = origin + right * (c[1] * half_x) + up * (c[2] * half_y)
		us[i], vs[i] = lerp_uv(decal, c[1], c[2])
	end

	local y_min, y_max = height_range(height, corners, origin.y)
	quad(
		out,
		corners,
		us,
		vs,
		{0, 0, 0, 0},
		y_min,
		y_max,
		projected_decals.RECEIVE_TERRAIN,
		decal
	)
end

local function add_road(out, decal, height)
	local samples = decal_projection.RoadSamples(decal:BuildRoad())

	for i = 1, #samples - 1 do
		local s0, s1 = samples[i], samples[i + 1]
		local corners = {
			s0.pos - s0.side * (
				s0.width * 0.5
			),
			s0.pos + s0.side * (
				s0.width * 0.5
			),
			s1.pos + s1.side * (
				s1.width * 0.5
			),
			s1.pos - s1.side * (
				s1.width * 0.5
			),
		}
		local u0, u1 = s0.distance / decal.TileLength, s1.distance / decal.TileLength
		local y_min, y_max = height_range(height, corners, math.min(s0.pos.y, s1.pos.y))
		y_max = math.max(y_max, math.max(s0.pos.y, s1.pos.y) + HEIGHT_MARGIN)
		quad(
			out,
			corners,
			{u0, u0, u1, u1},
			{1, 0, 0, 1},
			{s0.fade, s0.fade, s1.fade, s1.fade},
			y_min,
			y_max,
			projected_decals.RECEIVE_TERRAIN,
			decal
		)
	end
end

local function add_box(out, decal, receivers)
	local matrix = decal.Owner.transform:GetWorldMatrix()
	local origin = Vec3(matrix.m30, matrix.m31, matrix.m32)
	local axes = {
		Vec3(matrix.m00, matrix.m01, matrix.m02),
		Vec3(matrix.m10, matrix.m11, matrix.m12),
		Vec3(matrix.m20, matrix.m21, matrix.m22),
	}
	local extent = Vec3(0, 0, 0)

	for _, axis in ipairs(axes) do
		extent = extent + Vec3(math.abs(axis.x), math.abs(axis.y), math.abs(axis.z))
	end

	list.insert(
		out,
		{
			kind = projected_decals.KIND_BOX,
			decal = decal,
			receivers = receivers,
			origin = origin,
			axes = axes,
			min_x = origin.x - extent.x,
			min_z = origin.z - extent.z,
			max_x = origin.x + extent.x,
			max_z = origin.z + extent.z,
		}
	)
end

local function collect()
	local ordered = {}

	for decal, order in pairs(decals) do
		if decal.world and decal.world:IsValid() then
			list.insert(ordered, {decal = decal, order = order})
		end
	end

	table.sort(ordered, function(a, b)
		if a.decal.SortPriority ~= b.decal.SortPriority then
			return a.decal.SortPriority < b.decal.SortPriority
		end

		return a.order < b.order
	end)

	local out = {}

	for _, entry in ipairs(ordered) do
		local decal = entry.decal
		local projection = decal.Projection
		local height = decal.world.TerrainHeight

		if projection == "road" then
			if height then add_road(out, decal, height) end
		elseif projection == "terrain" then
			if height then add_terrain(out, decal, height) end
		elseif projection == "objects" then
			add_box(out, decal, projected_decals.RECEIVE_STATIC)
		elseif projection == "terrain_objects" then
			if height then add_terrain(out, decal, height) end

			add_box(out, decal, projected_decals.RECEIVE_STATIC)
		else
			add_box(out, decal, projected_decals.RECEIVE_TERRAIN + projected_decals.RECEIVE_STATIC)
		end
	end

	return out
end

local function fill_record(record, item, texture_index)
	local decal = item.decal
	ffi.fill(record, RECORD_SIZE)
	record.kind = item.kind
	record.receivers = item.receivers
	record.border = decal.UVBorder and 1 or 0
	write_material(record, resolve_material(decal), texture_index)

	if item.kind == projected_decals.KIND_QUAD then
		local c = item.corners
		record.a[0], record.a[1], record.a[2], record.a[3] = c[1].x, c[1].z, c[2].x, c[2].z
		record.b[0], record.b[1], record.b[2], record.b[3] = c[3].x, c[3].z, c[4].x, c[4].z
		record.c[0], record.c[1] = item.y_min, item.y_max

		for i = 0, 3 do
			record.u[i], record.v[i], record.fade[i] = item.us[i + 1], item.vs[i + 1], item.fades[i + 1]
		end
	else
		local o, axes = item.origin, item.axes
		record.a[0], record.a[1], record.a[2], record.a[3] = o.x, o.y, o.z, MIN_FACING

		for k, target in ipairs{record.b, record.c, record.d} do
			local axis = axes[k]
			local length_squared = axis.x * axis.x + axis.y * axis.y + axis.z * axis.z
			target[0], target[1], target[2] = axis.x / length_squared, axis.y / length_squared, axis.z / length_squared
		end

		record.u[0], record.u[1] = decal.URange.x, decal.URange.y
		record.u[2], record.u[3] = decal.VRange.x, decal.VRange.y
	end
end

local function retire_buffer()
	if buffer then
		list.insert(retired, {buffer = buffer, frame = render.frame_serial + RETIRE_FRAMES})
		buffer = nil
	end
end

local function free_retired()
	local frame = render.frame_serial

	for i = #retired, 1, -1 do
		if retired[i].frame <= frame then
			retired[i].buffer:Remove()
			table.remove(retired, i)
		end
	end
end

local function build(texture_index)
	retire_buffer()
	local items = projected_decals.IsEnabled() and collect() or {}

	if not items[1] then return end

	local cell = projected_decals.CELL_SIZE
	local min_x, min_z, max_x, max_z = math.huge, math.huge, -math.huge, -math.huge

	for _, item in ipairs(items) do
		min_x, min_z = math.min(min_x, item.min_x), math.min(min_z, item.min_z)
		max_x, max_z = math.max(max_x, item.max_x), math.max(max_z, item.max_z)
	end

	local dims_x = math.max(math.ceil((max_x - min_x) / cell), 1)
	local dims_z = math.max(math.ceil((max_z - min_z) / cell), 1)
	local counts = Uint32Array(dims_x * dims_z)
	local index_count = 0

	local function cell_range(item)
		return math.floor((item.min_x - min_x) / cell),
		math.min(math.floor((item.max_x - min_x) / cell), dims_x - 1),
		math.floor((item.min_z - min_z) / cell),
		math.min(math.floor((item.max_z - min_z) / cell), dims_z - 1)
	end

	for _, item in ipairs(items) do
		local x0, x1, z0, z1 = cell_range(item)

		for z = z0, z1 do
			for x = x0, x1 do
				counts[z * dims_x + x] = counts[z * dims_x + x] + 1
				index_count = index_count + 1
			end
		end
	end

	local cell_words = dims_x * dims_z * 2
	local index_offset = HEADER_WORDS + cell_words
	local record_offset = math.ceil((index_offset + index_count) / 4) * 16
	local byte_size = record_offset + #items * RECORD_SIZE
	buffer = render.CreateBuffer{
		byte_size = byte_size,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
		label = "projected_decals",
	}
	local base = buffer:Map()
	local words = ffi.cast(Uint32Pointer, base)
	local floats = ffi.cast(FloatPointer, base)
	words[0] = #items
	words[1] = dims_x
	words[2] = dims_z
	words[3] = HEADER_WORDS
	words[4] = index_offset
	words[5] = record_offset
	floats[6] = min_x
	floats[7] = min_z
	local offset = 0

	for i = 0, dims_x * dims_z - 1 do
		words[HEADER_WORDS + i * 2] = offset
		words[HEADER_WORDS + i * 2 + 1] = 0
		offset = offset + counts[i]
	end

	for record_index, item in ipairs(items) do
		local x0, x1, z0, z1 = cell_range(item)

		for z = z0, z1 do
			for x = x0, x1 do
				local slot = HEADER_WORDS + (z * dims_x + x) * 2
				words[index_offset + words[slot] + words[slot + 1]] = record_index - 1
				words[slot + 1] = words[slot + 1] + 1
			end
		end
	end

	local records = ffi.cast(ffi.typeof("$ *", Record), ffi.cast("uint8_t *", base) + record_offset)

	for i, item in ipairs(items) do
		fill_record(records[i - 1], item, texture_index)
	end

	projected_decals.record_count = #items
end

function projected_decals.GetAddress(texture_index)
	free_retired()

	if dirty then
		dirty = false
		build(texture_index)
		projected_decals.generation = projected_decals.generation + 1
	end

	return buffer and buffer:GetDeviceAddress() or 0
end

function projected_decals.GetGLSL()
	return [=[
		#ifndef PROJECTED_DECALS_GLSL
		#define PROJECTED_DECALS_GLSL
		#define PROJECTED_DECAL_CELL ]=] .. string.format("%.4f", projected_decals.CELL_SIZE) .. [=[

		#define PROJECTED_DECAL_QUAD ]=] .. projected_decals.KIND_QUAD .. [=[

		struct ProjectedDecal {
			vec4 a;
			vec4 b;
			vec4 c;
			vec4 d;
			vec4 u;
			vec4 v;
			vec4 fade;
			vec4 color;
			int kind;
			int receivers;
			int albedo_tex;
			int normal_tex;
			int roughness_tex;
			int roughness_channel;
			int metallic_tex;
			int metallic_channel;
			float roughness;
			float roughness_min;
			float roughness_max;
			float metallic;
			int border;
			int premultiplied;
			vec2 pad;
		};

		layout(buffer_reference, scalar) readonly buffer ProjectedDecalWords { uint v[]; };
		layout(buffer_reference, scalar) readonly buffer ProjectedDecalRecords { ProjectedDecal d[]; };

		struct ProjectedDecalSurface {
			vec3 albedo;
			vec3 N;
			float roughness;
			float metallic;
		};

		vec2 projected_decal_inverse_bilinear(vec2 p, vec2 a, vec2 b, vec2 c, vec2 d) {
			vec2 e = b - a;
			vec2 f = d - a;
			vec2 g = a - b + c - d;
			vec2 h = p - a;
			float k2 = g.x * f.y - g.y * f.x;
			float k1 = e.x * f.y - e.y * f.x + h.x * g.y - h.y * g.x;
			float k0 = h.x * e.y - h.y * e.x;
			float t;

			float w = k1 * k1 - 4.0 * k0 * k2;

			if (w < 0.0) return vec2(-1.0);

			// the textbook roots cancel catastrophically when k2 is tiny, which rounding of world coordinates makes it for near parallelograms, and snap the uv into steps
			float q = -0.5 * (k1 + (k1 < 0.0 ? -sqrt(w) : sqrt(w)));
			t = abs(q) > 0.0 ? k0 / q : 0.0;

			if ((t < 0.0 || t > 1.0) && abs(k2) > 0.0) t = q / k2;

			vec2 across = e + g * t;
			float s = abs(across.x) > abs(across.y) ? (h.x - f.x * t) / across.x : (h.y - f.y * t) / across.y;
			return vec2(s, t);
		}

		vec4 projected_decal_sample(int tex, vec2 uv, vec2 uv_dx, vec2 uv_dy, float lod) {
			return lod < 0.0 ? textureGrad(TEXTURE(tex), uv, uv_dx, uv_dy) : textureLod(TEXTURE(tex), uv, lod);
		}

		struct ProjectedDecalMapping {
			vec2 uv;
			float fade;
			vec3 grad_u;
			vec3 grad_v;
			vec3 T;
			vec3 B;
		};

		bool projected_decal_map(ProjectedDecal d, vec3 P, vec3 geometric_N, out ProjectedDecalMapping m) {
			m.fade = 0.0;

			if (d.kind == PROJECTED_DECAL_QUAD) {
				if (P.y < d.c.x || P.y > d.c.y) return false;

				vec2 st = projected_decal_inverse_bilinear(P.xz, d.a.xy, d.a.zw, d.b.xy, d.b.zw);

				if (any(lessThan(st, vec2(0.0))) || any(greaterThan(st, vec2(1.0)))) return false;

				vec4 w = vec4((1.0 - st.x) * (1.0 - st.y), st.x * (1.0 - st.y), st.x * st.y, (1.0 - st.x) * st.y);
				m.uv = vec2(dot(d.u, w), dot(d.v, w));
				m.fade = dot(d.fade, w);
				mat2 position_st = mat2(mix(d.a.zw - d.a.xy, d.b.xy - d.b.zw, st.y), mix(d.b.zw - d.a.xy, d.b.xy - d.a.zw, st.x));
				mat2 uv_st = mat2(vec2(mix(d.u.y - d.u.x, d.u.z - d.u.w, st.y), mix(d.v.y - d.v.x, d.v.z - d.v.w, st.y)), vec2(mix(d.u.w - d.u.x, d.u.z - d.u.y, st.x), mix(d.v.w - d.v.x, d.v.z - d.v.y, st.x)));

				if (abs(determinant(position_st)) < 1e-8 || abs(determinant(uv_st)) < 1e-8) return false;

				mat2 uv_position = uv_st * inverse(position_st);
				mat2 position_uv = position_st * inverse(uv_st);
				m.grad_u = vec3(uv_position[0][0], 0.0, uv_position[1][0]);
				m.grad_v = vec3(uv_position[0][1], 0.0, uv_position[1][1]);
				m.T = vec3(position_uv[0].x, 0.0, position_uv[0].y);
				m.B = vec3(position_uv[1].x, 0.0, position_uv[1].y);
			} else {
				vec3 local_pos = vec3(dot(P - d.a.xyz, d.b.xyz), dot(P - d.a.xyz, d.c.xyz), dot(P - d.a.xyz, d.d.xyz));

				if (any(greaterThan(abs(local_pos), vec3(1.0)))) return false;

				if (dot(geometric_N, geometric_N) > 0.0 && dot(geometric_N, normalize(d.d.xyz)) < d.a.w) return false;

				m.uv = vec2(mix(d.u.x, d.u.y, local_pos.x * 0.5 + 0.5), mix(d.u.z, d.u.w, local_pos.y * 0.5 + 0.5));
				m.fade = local_pos.z * local_pos.z;
				m.grad_u = d.b.xyz * (0.5 * (d.u.y - d.u.x));
				m.grad_v = d.c.xyz * (0.5 * (d.u.w - d.u.z));
				m.T = m.grad_u;
				m.B = m.grad_v;
			}

			return d.border == 0 || all(greaterThanEqual(m.uv, vec2(0.0))) && all(lessThanEqual(m.uv, vec2(1.0)));
		}

		float projected_decal_alpha(ProjectedDecal d, ProjectedDecalMapping m, vec4 albedo) {
			return albedo.a * d.color.a * (1.0 - m.fade);
		}

		uint projected_decal_cell(uint64_t address, vec3 P, out uint first) {
			ProjectedDecalWords words = ProjectedDecalWords(address);
			ivec2 dims = ivec2(words.v[1], words.v[2]);
			vec2 origin = vec2(uintBitsToFloat(words.v[6]), uintBitsToFloat(words.v[7]));
			ivec2 cell = ivec2(floor((P.xz - origin) / PROJECTED_DECAL_CELL));
			first = 0u;

			if (any(lessThan(cell, ivec2(0))) || any(greaterThanEqual(cell, dims))) return 0u;

			uint slot = words.v[3] + uint(cell.y * dims.x + cell.x) * 2u;
			first = words.v[4] + words.v[slot];
			return words.v[slot + 1u];
		}

		// a compute pass has no derivatives, so lod < 0 filters with the uv footprint of the world space pixel steps dPdx and dPdy
		bool apply_projected_decals(uint64_t address, vec3 P, vec3 dPdx, vec3 dPdy, vec3 geometric_N, int receiver, float lod, inout ProjectedDecalSurface s) {
			if (address == 0ul) return false;

			uint first;
			uint count = projected_decal_cell(address, P, first);
			ProjectedDecalWords words = ProjectedDecalWords(address);
			ProjectedDecalRecords records = ProjectedDecalRecords(address + uint64_t(words.v[5]));
			bool applied = false;

			for (uint i = 0u; i < count; i++) {
				ProjectedDecal d = records.d[words.v[first + i]];
				ProjectedDecalMapping m;

				if ((d.receivers & receiver) == 0 || !projected_decal_map(d, P, geometric_N, m)) continue;

				vec2 uv_dx = vec2(dot(m.grad_u, dPdx), dot(m.grad_v, dPdx));
				vec2 uv_dy = vec2(dot(m.grad_u, dPdy), dot(m.grad_v, dPdy));
				vec4 albedo = d.albedo_tex >= 0 ? projected_decal_sample(d.albedo_tex, m.uv, uv_dx, uv_dy, lod) : vec4(1.0);
				float alpha = projected_decal_alpha(d, m, albedo);

				if (alpha <= 0.001) continue;

				if (d.premultiplied != 0) albedo.rgb /= max(albedo.a, 1.0 / 255.0);

				applied = true;
				s.albedo = mix(s.albedo, albedo.rgb * d.color.rgb, alpha);
				float roughness = d.roughness_tex >= 0 ? d.roughness * mix(d.roughness_min, d.roughness_max, projected_decal_sample(d.roughness_tex, m.uv, uv_dx, uv_dy, lod)[d.roughness_channel]) : d.roughness;
				s.roughness = mix(s.roughness, roughness, alpha);
				float metallic = d.metallic_tex >= 0 ? d.metallic * projected_decal_sample(d.metallic_tex, m.uv, uv_dx, uv_dy, lod)[d.metallic_channel] : d.metallic;
				s.metallic = mix(s.metallic, clamp(metallic, 0.0, 1.0), alpha);

				if (d.normal_tex >= 0) {
					vec2 t = projected_decal_sample(d.normal_tex, m.uv, uv_dx, uv_dy, lod).xy * 2.0 - 1.0;
					vec3 tangent = normalize(m.T - s.N * dot(m.T, s.N));
					vec3 bitangent = normalize(m.B - s.N * dot(m.B, s.N));
					vec3 n = normalize(tangent * t.x + bitangent * t.y + s.N * sqrt(max(1.0 - dot(t, t), 0.0)));
					s.N = normalize(mix(s.N, n, alpha));
				}
			}

			return applied;
		}
		#endif
	]=]
end

do
	local EasyPipeline = import("goluwa/render/easy_pipeline.lua")
	local glsl_common = import("goluwa/render3d/glsl_common.lua")
	local gpu_timing = import("goluwa/render/gpu_timing.lua")
	local STORAGE_FORMATS = {
		r8g8b8a8_unorm = "rgba8",
		r16g16b16a16_unorm = "rgba16",
		r16g16_unorm = "rg16",
	}
	local SLOTS = 8
	local pipeline
	local dispatches = 0
	local used_targets

	local function field(gbuffer_layout, name)
		for _, f in ipairs(gbuffer_layout.fields) do
			if f.name == name then return f end
		end

		error("gbuffer has no field " .. name)
	end

	local function build_shader(gbuffer_layout)
		local index = gbuffer_layout.attachment_index
		local fields = {}

		for _, name in ipairs{"normal", "geometric_normal", "roughness", "metallic", "decal_receiver"} do
			fields[name] = field(gbuffer_layout, name)
		end

		used_targets = {index.albedo}
		local seen = {[index.albedo] = true}

		for _, f in pairs(fields) do
			local i = index[f.target.texture]

			if not seen[i] then
				seen[i] = true
				list.insert(used_targets, i)
			end
		end

		table.sort(used_targets)
		local lines = {}

		for _, i in ipairs(used_targets) do
			local target = gbuffer_layout.targets[i]
			list.insert(
				lines,
				string.format(
					"layout(set = 0, binding = %d, %s) uniform image2D gbuffer_target_%d;",
					i,
					assert(STORAGE_FORMATS[target.format], target.format),
					i
				)
			)
		end

		local function texel(f)
			return "t" .. index[f.target.texture]
		end

		local function read(f)
			local raw = string.format(
				"(float((uint(%s.%s * 65535.0 + 0.5) >> %du) & %du) / %d.0)",
				texel(f),
				f.swizzle,
				f.shift,
				2 ^ f.bits - 1,
				2 ^ f.bits - 1
			)
			return f.decode and ("(" .. f.decode:gsub("%f[%w_]v%f[^%w_]", raw) .. ")") or raw
		end

		local function write(f, value)
			local encoded = f.encode and ("(" .. f.encode:gsub("%f[%w_]v%f[^%w_]", value) .. ")") or value
			return string.format(
				"%s.%s = float(bitfieldInsert(uint(%s.%s * 65535.0 + 0.5), uint(clamp(%s, 0.0, 1.0) * %d.0 + 0.5), %d, %d)) / 65535.0;",
				texel(f),
				f.swizzle,
				texel(f),
				f.swizzle,
				encoded,
				2 ^ f.bits - 1,
				f.shift,
				f.bits
			)
		end

		local loads, stores = {}, {}

		for _, i in ipairs(used_targets) do
			list.insert(loads, string.format("vec4 t%d = imageLoad(gbuffer_target_%d, pixel);", i, i))
			list.insert(stores, string.format("imageStore(gbuffer_target_%d, pixel, t%d);", i, i))
		end

		local albedo = "t" .. index.albedo
		return table.concat(lines, "\n") .. "\n" .. glsl_common.GetOctahedralGLSL() .. glsl_common.GetSRGBGLSL() .. projected_decals.GetGLSL() .. [=[

			vec3 decal_world_position(vec2 pixel, float depth) {
				vec2 ndc = pixel / decal_resolve.render_size * 2.0 - 1.0;
				vec4 view_position = decal_resolve.inv_projection * vec4(ndc, depth, 1.0);
				return (decal_resolve.inv_view * vec4(view_position.xyz / view_position.w, 1.0)).xyz;
			}

			vec3 decal_neighbour_step(ivec2 pixel, ivec2 offset, vec3 P) {
				float ahead_depth = texelFetch(TEXTURE(decal_resolve.depth_tex), pixel + offset, 0).r;
				float behind_depth = texelFetch(TEXTURE(decal_resolve.depth_tex), pixel - offset, 0).r;
				vec3 ahead = ahead_depth > 0.0 ? decal_world_position(vec2(pixel + offset) + 0.5, ahead_depth) - P : vec3(1e9);
				vec3 behind = behind_depth > 0.0 ? P - decal_world_position(vec2(pixel - offset) + 0.5, behind_depth) : vec3(1e9);
				vec3 step = dot(ahead, ahead) < dot(behind, behind) ? ahead : behind;
				return dot(step, step) < 1e17 ? step : vec3(0.0);
			}

			void main() {
				ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

				if (any(greaterThanEqual(pixel, ivec2(decal_resolve.render_size)))) return;

				]=] .. table.concat(loads, "\n") .. [=[

				int receiver = int(]=] .. read(fields.decal_receiver) .. [=[ * 15.0 + 0.5);

				if (receiver == 0) return;

				float depth = texelFetch(TEXTURE(decal_resolve.depth_tex), pixel, 0).r;

				if (depth == 0.0) return;

				vec2 center = vec2(pixel) + 0.5;
				vec3 P = decal_world_position(center, depth);
				vec3 geometric_N = oct_decode(]=] .. texel(fields.geometric_normal) .. "." .. fields.geometric_normal.swizzle .. [=[ * 2.0 - 1.0);
				ProjectedDecalSurface s;
				s.albedo = srgb_to_linear(]=] .. albedo .. [=[.rgb);
				s.N = oct_decode(]=] .. texel(fields.normal) .. "." .. fields.normal.swizzle .. [=[ * 2.0 - 1.0);
				s.roughness = ]=] .. read(fields.roughness) .. [=[;
				s.metallic = ]=] .. read(fields.metallic) .. [=[;
				vec3 dPdx = decal_neighbour_step(pixel, ivec2(1, 0), P);
				vec3 dPdy = decal_neighbour_step(pixel, ivec2(0, 1), P);

				if (!apply_projected_decals(decal_resolve.decals, P, dPdx, dPdy, geometric_N, receiver, -1.0, s)) return;

				]=] .. albedo .. [=[.rgb = linear_to_srgb(s.albedo);
				]=] .. texel(fields.normal) .. "." .. fields.normal.swizzle .. [=[ = oct_encode(s.N) * 0.5 + 0.5;
				]=] .. write(fields.roughness, "s.roughness") .. [=[

				]=] .. write(fields.metallic, "s.metallic") .. [=[

				]=] .. table.concat(stores, "\n") .. [=[
			}
		]=]
	end

	local function get_pipeline()
		if pipeline then return pipeline end

		local gbuffer_layout = import("goluwa/render3d/gbuffer_layout.lua")
		local render3d = import("goluwa/render3d/render3d.lua")
		local shader = build_shader(gbuffer_layout)
		local descriptor_sets = {}

		for _, i in ipairs(used_targets) do
			list.insert(
				descriptor_sets,
				{
					type = "storage_image",
					binding_index = i,
					stageFlags = "compute",
					set_index = 0,
				}
			)
		end

		pipeline = EasyPipeline.Compute{
			name = "projected_decals",
			DescriptorSetCount = SLOTS,
			LocalSize = {x = 8, y = 8, z = 1},
			descriptor_sets = descriptor_sets,
			uniform_buffers = {
				{
					name = "decal_resolve",
					binding_index = 0,
					block = {
						render3d.camera_block,
						{"depth_tex", "int"},
						{"decals", "uint64_t"},
					},
					write = function(self, block)
						render3d.WriteCameraBlock(self, block)
						block.depth_tex = self:GetTextureIndex(gbuffer_layout.GetDepthTexture())
						block.decals = projected_decals.GetAddress(function(texture)
							return self:GetTextureIndex(texture)
						end)
						return block
					end,
				},
			},
			shader = shader,
		}
		return pipeline
	end

	function projected_decals.Resolve(cmd, framebuffer)
		if not projected_decals.IsEnabled() or not next(decals) then return end

		local resolve = get_pipeline()
		local slot = dispatches % SLOTS + 1
		dispatches = dispatches + 1
		gpu_timing.BeginScope(cmd, "projected_decals")

		for _, i in ipairs(used_targets) do
			resolve:BindStorageImage(cmd, slot, i, framebuffer:GetAttachment(i))
		end

		local size = framebuffer:GetAttachment(used_targets[1])
		resolve:DispatchForSize(cmd, size:GetWidth(), size:GetHeight(), 1, slot)

		for _, i in ipairs(used_targets) do
			render.TransitionResourceFrom(
				framebuffer:GetAttachment(i),
				"shader_read_only_optimal",
				{
					cmd = cmd,
					srcStage = "compute",
					srcAccess = "shader_write",
					dstStage = "all_commands",
					dstAccess = "shader_read",
				}
			)
		end

		gpu_timing.EndScope(cmd, "projected_decals")
	end
end

return projected_decals
