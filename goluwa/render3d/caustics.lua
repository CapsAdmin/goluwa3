local ffi = require("ffi")
local pvars = import("goluwa/cli/pvars.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local water = import("goluwa/render3d/water.lua")
local directional_shadows = import("goluwa/render3d/directional_shadows.lua")
local scene_lights = import("goluwa/render3d/scene_lights.lua")
local optical_rays = import("goluwa/render3d/optical_rays.lua")
local medium_surface = import("goluwa/render3d/medium_surface.lua")
local screen_refraction = import("goluwa/render3d/screen_refraction.lua")
local scene_instances = import("goluwa/render3d/scene/instances.lua")
local scene_materials = import("goluwa/render3d/scene/materials.lua")
local path_trace = import("goluwa/render3d/path_trace.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local Material = import("goluwa/render3d/material.lua")
local caustics = {}
local Uint32Pointer = ffi.typeof("uint32_t*")
caustics.MAX_CASTERS = 64
caustics.FIXED_POINT = 256
caustics.WORLD_FIXED_POINT = 65536
caustics.WORLD_ENTRIES = 262144
caustics.WORLD_PROBES = 8
caustics.WORLD_CELL = 0.05
caustics.WORLD_NEAR = 2.5
caustics.WAVELENGTH_MIN = 380
caustics.WAVELENGTH_MAX = 730
pvars.StartGroup("Lighting", "Caustics", {store = false, prefix = "r_caustics_"})
caustics.photons = pvars.Setup2{
	key = "r_caustics_photons",
	default = 2097152,
	integer = true,
	help = "photons traced from the sun through glass and water each frame, shared between the casters near the camera. more is less noise and a sharper pattern",
}
caustics.bounces = pvars.Setup2{
	key = "r_caustics_bounces",
	default = 8,
	integer = true,
	help = "how many refractions and reflections at glass and water surfaces a photon follows before it is dropped",
}
caustics.dispersion = pvars.Setup2{
	key = "r_caustics_dispersion",
	default = true,
	help = "photons crossing a dispersive surface (an AbbeNumber on glass, the water presets) are traced again as three bands of the spectrum, each bent by its own index of refraction, splitting white light into its colours. off every photon bends as white light",
}
caustics.dispersion_spread = pvars.Setup2{
	key = "r_caustics_dispersion_spread",
	default = 0.01,
	help = "the least spread of the index of refraction across the spectrum, (n - 1) / AbbeNumber, at which a surface splits light into colours. water is about 0.006 and crown glass 0.009, whose colour fringes are under a millimetre per metre of travel, flint glass 0.03. 0 splits at every dispersive surface. the path tracer always splits",
}
caustics.history = pvars.Setup2{
	key = "r_caustics_history",
	default = 8,
	integer = true,
	help = "most frames the caustic light averages. more is smoother, but moving caustics (waves) trail behind",
}
caustics.water_history = pvars.Setup2{
	key = "r_caustics_water_history",
	default = 1,
	integer = true,
	help = "most frames the caustic light averages while a lit caster is moving water. waves move the pattern many pixels a frame, so a long history smears it into flat blobs",
}
caustics.filter_radius = pvars.Setup2{
	key = "r_caustics_filter_radius",
	default = 8,
	integer = true,
	help = "radius in pixels of the widest blur over the photons that landed on the same surface, used where few photons land. where many land the blur narrows to keep the pattern sharp",
}
caustics.world = pvars.Setup2{
	key = "r_caustics_world",
	default = true,
	help = "photons also land in a world space grid that reflection, refraction and gi rays read, so caustics show in reflections and light their surroundings. off only the surfaces the camera sees get them",
}
caustics.world_history = pvars.Setup2{
	key = "r_caustics_world_history",
	default = 16,
	integer = true,
	help = "most frames a cell of the world caustic grid averages",
}
caustics.filter_photons = pvars.Setup2{
	key = "r_caustics_filter_photons",
	default = 8,
	help = "photons the narrow blur must gather before it is used instead of the wide one, more is smoother and less sharp",
}
pvars.EndGroup()
caustics.coverage_block = {
	{"caustic_rects", "vec4", caustics.MAX_CASTERS * 2},
	{"caustic_sun", "vec4"},
	{"caustic_sun_u", "vec4"},
	{"caustic_sun_v", "vec4"},
	{"caustic_caster_count", "int"},
}
caustics.world_block = {
	{"caustic_world_grid", "uint64_t"},
	{"caustic_world_origin", "vec4"},
}
caustics.hit_block = {caustics.coverage_block, caustics.world_block}
caustics.block = {
	caustics.world_block,
	{"caustic_grids", "vec4", caustics.MAX_CASTERS * 2},
	{"caustic_photon_count", "int"},
	{"caustic_frame", "int"},
	{"caustic_bounces", "int"},
	{"caustic_dispersion_spread", "float"},
	{"caustic_stats", "uint64_t"},
	medium_surface.block,
}

do
	local function lobe(x, mu, below, above)
		local t = (x - mu) / (x < mu and below or above)
		return math.exp(-0.5 * t * t)
	end

	local function spectrum(nm)
		local x = 1.056 * lobe(nm, 599.8, 37.9, 31.0) + 0.362 * lobe(nm, 442.0, 16.0, 26.7) - 0.065 * lobe(nm, 501.1, 20.4, 26.2)
		local y = 0.821 * lobe(nm, 568.8, 46.9, 40.5) + 0.286 * lobe(nm, 530.9, 16.3, 31.1)
		local z = 1.217 * lobe(nm, 437.0, 11.8, 36.0) + 0.681 * lobe(nm, 459.0, 26.0, 13.8)
		return math.max(3.2406 * x - 1.5372 * y - 0.4986 * z, 0),
		math.max(-0.9689 * x + 1.8758 * y + 0.0415 * z, 0),
		math.max(0.0557 * x - 0.2040 * y + 1.0570 * z, 0)
	end

	local r, g, b = 0, 0, 0
	local steps = 2000

	for i = 0, steps - 1 do
		local nm = caustics.WAVELENGTH_MIN + (
				caustics.WAVELENGTH_MAX - caustics.WAVELENGTH_MIN
			) * (
				i + 0.5
			) / steps
		local sr, sg, sb = spectrum(nm)
		r, g, b = r + sr / steps, g + sg / steps, b + sb / steps
	end

	caustics.SPECTRUM_NORMALIZATION = {1 / r, 1 / g, 1 / b}
end

local casters = {}
local entries = {}
local volume_keys = table.weak("k")
local volume_key_count = 0

local function add_caster(count, x, y, z, radius, camera, volume, key)
	if count >= #casters then casters[count + 1] = {} end

	local c = casters[count + 1]
	local dx, dy, dz = x - camera.x, y - camera.y, z - camera.z
	c.x, c.y, c.z, c.radius, c.volume, c.key = x, y, z, radius, volume, key
	c.importance = 1 / math.max(dx * dx + dy * dy + dz * dz - radius * radius, radius * radius, 0.25)
	c.animated = volume and volume:GetWaveHeight() > 0
	return count + 1
end

local function add_entry(count)
	if count >= #entries then entries[count + 1] = {} end

	return count + 1, entries[count + 1]
end

local function by_weight(a, b)
	return a.weight > b.weight
end

local function by_rank(a, b)
	return a.rank > b.rank
end

local glass_ids = {}
local glass_key = {}

local function find_glass()
	if
		glass_key.version == scene_instances.version and
		glass_key.materials == Material.ray_material_generation
	then
		return glass_ids
	end

	glass_key.version = scene_instances.version
	glass_key.materials = Material.ray_material_generation
	list.clear(glass_ids)
	local data = scene_instances.GetDataTable():Get()
	local runs = scene_instances.GetVisualRows()

	for r = 1, #runs, 2 do
		for id = runs[r], runs[r] + runs[r + 1] - 1 do
			local d = data[id]

			if
				bit.band(d.mask_lod, scene_instances.MASK_GLASS) ~= 0 and
				bit.band(d.flags, scene_instances.FLAG_REMOVED) == 0
			then
				local material = scene_materials.list[d.material_row + 1]

				if
					material and
					material:IsGlass() and
					material:GetCastsCaustics() and
					not material:GetDoubleSided()
				then
					glass_ids[#glass_ids + 1] = id
				end
			end
		end
	end

	return glass_ids
end

local function gather_casters(camera)
	local count = 0

	if optical_rays.IsEnabled() and scene_instances.IsAlive() then
		local data = scene_instances.GetDataTable():Get()
		local last_x, last_y, last_z, last_radius

		for _, id in ipairs(find_glass()) do
			local d = data[id]

			if
				d.radius > 0 and
				not (
					d.center_x == last_x and
					d.center_y == last_y and
					d.center_z == last_z and
					d.radius == last_radius
				)
				and
				scene_instances.IsLevelShown(id, camera)
			then
				last_x, last_y, last_z, last_radius = d.center_x, d.center_y, d.center_z, d.radius
				count = add_caster(
					count,
					d.center_x,
					d.center_y,
					d.center_z,
					d.radius * 1.02 + 0.01,
					camera,
					false,
					id
				)
			end
		end
	end

	for _, volume in ipairs(water.GetNearestVolumes(camera)) do
		if not volume_keys[volume] then
			volume_key_count = volume_key_count + 1
			volume_keys[volume] = 2 ^ 24 + volume_key_count
		end

		local size = volume:GetSize()
		local x, y, z = volume.Owner.transform:GetWorldMatrix():TransformVectorUnpacked(0, -size.y / 2, 0)
		count = add_caster(
			count,
			x,
			y,
			z,
			math.sqrt(size.x * size.x + size.y * size.y + size.z * size.z) / 2 + 0.01,
			camera,
			volume,
			volume_keys[volume]
		)
	end

	return count
end

local function add_sun_entries(count, caster_count, sun_index, axes, lux)
	local sx, sy, sz, tx, ty, tz, bx, by, bz = unpack(axes, 1, 9)

	for i = 1, caster_count do
		local c = casters[i]
		local u0, v0, u1, v1, extent

		if c.volume then
			local size = c.volume:GetSize()
			local m = c.volume.Owner.transform:GetWorldMatrix()
			u0, v0, u1, v1 = math.huge, math.huge, -math.huge, -math.huge

			for corner = 0, 7 do
				local x, y, z = m:TransformVectorUnpacked(
					(bit.band(corner, 1) == 0 and -0.5 or 0.5) * size.x,
					bit.band(corner, 2) == 0 and -size.y or 0,
					(bit.band(corner, 4) == 0 and -0.5 or 0.5) * size.z
				)
				local u, v = x * tx + y * ty + z * tz, x * bx + y * by + z * bz
				u0, v0, u1, v1 = math.min(u0, u), math.min(v0, v), math.max(u1, u), math.max(v1, v)
			end
		else
			local u, v = c.x * tx + c.y * ty + c.z * tz, c.x * bx + c.y * by + c.z * bz
			u0, v0, u1, v1 = u - c.radius, v - c.radius, u + c.radius, v + c.radius
		end

		local e
		count, e = add_entry(count)
		e.kind, e.light, e.key = 0, sun_index, sun_index * 2 ^ 25 + c.key
		e.a, e.b, e.c, e.d = u0, v0, u1, v1
		e.s = c.x * sx + c.y * sy + c.z * sz
		e.start = c.radius + optical_rays.SUN_DISTANCE
		e.weight = (u1 - u0) * (v1 - v0) * c.importance
		e.animated = c.animated
		e.rank = e.weight * lux
		e.solid_angle, e.distance = 0, 0
	end

	return count
end

local function add_lamp_entries(count, caster_count, light, index)
	if light.Type ~= "light_point" and light.Type ~= "light_spot" then
		return count
	end

	local intensity = light:GetPhotometricAmount() * light:GetInverseEmissionSolidAngle()
	local range = light:GetEffectiveRange()

	if intensity <= 0 or range <= 0 then return count end

	local px, py, pz = light.Owner.transform:GetWorldMatrix():GetTranslation()

	for i = 1, caster_count do
		local c = casters[i]
		local dx, dy, dz = c.x - px, c.y - py, c.z - pz
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

		if distance - c.radius < range then
			local cos_max = -1
			local ax, ay, az = 0, 1, 0
			local lx, ly, lz

			if c.volume then
				lx, ly, lz = c.volume.Owner.transform:GetWorldMatrixInverse():TransformVectorUnpacked(px, py, pz)
			end

			local size = c.volume and c.volume:GetSize()
			local under_water = size and
				ly < 0 and
				ly > -size.y and
				math.abs(lx) < size.x / 2 and
				math.abs(lz) < size.z / 2

			if under_water then
				local reach_x, reach_z = size.x / 2 + math.abs(lx), size.z / 2 + math.abs(lz)
				cos_max = -ly / math.sqrt(ly * ly + reach_x * reach_x + reach_z * reach_z)
			elseif distance > c.radius then
				cos_max = math.sqrt(1 - (c.radius / distance) ^ 2)
				ax, ay, az = dx / distance, dy / distance, dz / distance
			end

			local solid_angle = 2 * math.pi * (1 - cos_max)
			local area = under_water and size.x * size.z or math.pi * c.radius * c.radius
			local e
			count, e = add_entry(count)
			e.kind, e.light, e.key = 1, index, index * 2 ^ 25 + c.key
			e.a, e.b, e.c, e.d = ax, ay, az, cos_max
			e.s, e.start = 0, 0
			e.solid_angle, e.distance = solid_angle, math.max(distance - c.radius, 0.01)
			e.weight = area * c.importance
			e.animated = c.animated
			e.rank = intensity * solid_angle * c.importance
		end
	end

	return count
end

local function round_up(x, step)
	return math.max(math.ceil(x / step), 1) * step
end

local efficiency = {}
local MIN_EFFICIENCY = 0.002
local WORLD_ONLY_SHARE = 0.1
local frame_state = {frame = -1, count = 0, sun_index = -1, axes = {0, 1, 0, 1, 0, 0, 0, 0, 1}}

local function prepare()
	local frame = system.GetFrameNumber()

	if frame_state.frame == frame then return frame_state end

	frame_state.frame = frame
	frame_state.count = 0
	frame_state.sun_index = -1
	local lights = render3d.GetLights()
	local camera = render3d.GetCamera():GetPosition()
	local caster_count = gather_casters(camera)
	local sun, sun_index = directional_shadows.GetPrimarySun(lights)
	local count = 0

	if sun and sun_index < scene_lights.MAX_LIGHTS then
		frame_state.sun_index = sun_index
		local to_sun = directional_shadows.GetPrimarySunDirection(lights)

		if to_sun.y > 0 then
			local sx, sy, sz = to_sun.x, to_sun.y, to_sun.z
			local length = math.sqrt(sx * sx + sy * sy + sz * sz)
			sx, sy, sz = sx / length, sy / length, sz / length
			local ax, ay, az = 0, 1, 0

			if math.abs(sy) > 0.99 then ax, ay = 1, 0 end

			local tx, ty, tz = ay * sz - az * sy, az * sx - ax * sz, ax * sy - ay * sx
			length = math.sqrt(tx * tx + ty * ty + tz * tz)
			tx, ty, tz = tx / length, ty / length, tz / length
			local bx, by, bz = sy * tz - sz * ty, sz * tx - sx * tz, sx * ty - sy * tx
			local axes = frame_state.axes
			axes[1], axes[2], axes[3], axes[4], axes[5], axes[6], axes[7], axes[8], axes[9] = sx, sy, sz, tx, ty, tz, bx, by, bz
			count = add_sun_entries(count, caster_count, sun_index, axes, sun:GetPhotometricAmount())
		end
	end

	for i = 1, math.min(#lights, scene_lights.MAX_LIGHTS) do
		count = add_lamp_entries(count, caster_count, lights[i], i - 1)
	end

	for i = 1, count do
		local e = entries[i]
		local seen = efficiency[e.key]

		if seen then
			e.weight = e.weight * math.max(seen.landed, MIN_EFFICIENCY)
			e.rank = e.rank * seen.landed
		end
	end

	for i = count + 1, #entries do
		entries[i].weight = -1
		entries[i].rank = -1
	end

	if count > caustics.MAX_CASTERS then
		table.sort(entries, by_rank)

		for i = caustics.MAX_CASTERS + 1, #entries do
			entries[i].weight = -1
		end
	end

	table.sort(entries, by_weight)
	frame_state.count = math.min(count, caustics.MAX_CASTERS)
	frame_state.animated = false

	for i = 1, frame_state.count do
		local seen = efficiency[entries[i].key]

		if seen then seen.frame = frame end

		if entries[i].animated then frame_state.animated = true end
	end

	return frame_state
end

function caustics.HasCasters()
	return prepare().count > 0
end

function caustics.GetHistory()
	return prepare().animated and caustics.water_history:Get() or caustics.history:Get()
end

function caustics.IsLit()
	return render3d.IsPassEnabled("caustics") and caustics.HasCasters()
end

function caustics.IsActive()
	return render3d.IsPassEnabled("caustics") or path_trace.AreCausticsTraced()
end

local function write_coverage(block, state)
	block.caustic_caster_count = state and state.count or 0
	block.caustic_sun[3] = state and state.sun_index or -1

	if not state or state.count == 0 then return end

	local axes = state.axes
	block.caustic_sun[0], block.caustic_sun[1], block.caustic_sun[2] = axes[1], axes[2], axes[3]
	block.caustic_sun_u[0], block.caustic_sun_u[1], block.caustic_sun_u[2] = axes[4], axes[5], axes[6]
	block.caustic_sun_v[0], block.caustic_sun_v[1], block.caustic_sun_v[2] = axes[7], axes[8], axes[9]
	local out = block.caustic_rects

	for i = 1, state.count do
		local e = entries[i]
		local base = (i - 1) * 2
		out[base][0], out[base][1], out[base][2], out[base][3] = e.a, e.b, e.c, e.d
		out[base + 1][0], out[base + 1][1], out[base + 1][2], out[base + 1][3] = e.s, e.start, e.light, e.kind
	end
end

function caustics.WriteCoverageBlock(block)
	write_coverage(block, caustics.IsActive() and prepare())
end

function caustics.WriteHitBlock(self, block)
	local lit = caustics.world:Get() and caustics.IsLit()
	write_coverage(block, lit and prepare())
	block.caustic_world_grid = lit and caustics.GetWorldGridAddress() or 0
	local camera = render3d.GetCamera():GetPosition()
	block.caustic_world_origin[0], block.caustic_world_origin[1], block.caustic_world_origin[2] = camera.x, camera.y, camera.z
end

local stats_ring = {}

-- the counters this frame slot wrote when it last ran are complete once the slot comes around again
local function read_stats(state)
	local slot = render.GetCurrentFrame()
	local ring = stats_ring[slot]

	if not ring then
		ring = {
			buffer = render.CreateBuffer{
				byte_size = caustics.MAX_CASTERS * 8,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "caustics_stats",
			},
			keys = {},
			emitted = {},
			count = 0,
		}
		ffi.fill(ring.buffer:Map(), caustics.MAX_CASTERS * 8)
		stats_ring[slot] = ring
	end

	local counts = ffi.cast(Uint32Pointer, ring.buffer:Map())

	for i = 1, ring.count do
		local fraction = (counts[i * 2 - 1] + WORLD_ONLY_SHARE * counts[i * 2 - 2]) / ring.emitted[i]
		local seen = efficiency[ring.keys[i]]

		if seen then
			seen.landed = seen.landed + (fraction - seen.landed) * 0.25
		else
			efficiency[ring.keys[i]] = {landed = fraction, frame = state.frame}
		end

		counts[i * 2 - 2], counts[i * 2 - 1] = 0, 0
	end

	if state.frame % 256 == 0 then
		for key, seen in pairs(efficiency) do
			if state.frame - seen.frame > 256 then efficiency[key] = nil end
		end
	end

	return ring
end

function caustics.WriteBlock(self, block, budget, exact)
	medium_surface.WriteBlock(self, block)
	block.caustic_photon_count = 0
	block.caustic_stats = 0
	block.caustic_frame = system.GetFrameNumber()
	block.caustic_bounces = caustics.bounces:Get()
	block.caustic_dispersion_spread = not caustics.dispersion:Get() and
		-1 or
		exact and
		0 or
		caustics.dispersion_spread:Get()
	block.caustic_world_grid = not exact and caustics.world:Get() and caustics.GetWorldGridAddress() or 0
	local camera = render3d.GetCamera():GetPosition()
	block.caustic_world_origin[0], block.caustic_world_origin[1], block.caustic_world_origin[2] = camera.x, camera.y, camera.z

	if budget <= 0 then return 0 end

	local state = prepare()

	if state.count == 0 then return 0 end

	local total_weight = 0

	for i = 1, state.count do
		total_weight = total_weight + entries[i].weight
	end

	local first = 0
	local out = block.caustic_grids
	local ring = not exact and read_stats(state)

	for i = 1, state.count do
		local e = entries[i]
		local photons = math.max(budget * e.weight / total_weight, 256)
		local columns, rows, base = 0, 0, (i - 1) * 2

		if e.kind == 0 then
			local width, height = e.c - e.a, e.d - e.b
			columns = round_up(math.sqrt(photons * width / height), 8)
			rows = round_up(photons / columns, 8)
			out[base][0], out[base][1] = width / columns, height / rows
		else
			columns = round_up(math.sqrt(photons), 8)
			rows = round_up(photons / columns, 8)
			out[base][0], out[base][1] = 1 / columns, 1 / rows
		end

		out[base][2] = first
		first = first + columns * rows
		out[base][3] = first
		out[base + 1][0], out[base + 1][1] = columns, rows
		out[base + 1][2] = e.solid_angle / (columns * rows)
		out[base + 1][3] = e.distance * math.sqrt(e.solid_angle / (columns * rows))

		if ring then
			ring.keys[i] = e.key
			ring.emitted[i] = columns * rows
		end
	end

	if ring then
		ring.count = state.count
		block.caustic_stats = ring.buffer:GetDeviceAddress()
	end

	block.caustic_photon_count = first
	return first
end

function caustics.GetCoverageGLSL(block_name, function_name)
	return (
		[[
		bool NAME(int light, vec3 light_position, vec3 P) {
			vec2 uv = vec2(dot(P, $B.caustic_sun_u.xyz), dot(P, $B.caustic_sun_v.xyz));

			for (int k = 0; k < $B.caustic_caster_count; k++) {
				vec4 meta = $B.caustic_rects[k * 2 + 1];

				if (int(meta.z) != light) continue;

				vec4 rect = $B.caustic_rects[k * 2];

				if (meta.w > 0.5 ? dot(normalize(P - light_position), rect.xyz) >= rect.w : all(greaterThanEqual(uv, rect.xy)) && all(lessThan(uv, rect.zw))) return true;
			}

			return false;
		}
	]]
	):gsub("%$B", block_name):gsub("NAME", function_name or "caustic_covered")
end

function caustics.GetWorldGLSL(block_name)
	return glsl_common.GetHashGLSL() .. string.format(
			"#define CAUSTIC_WORLD_ENTRIES %du\n#define CAUSTIC_WORLD_PROBES %du\n#define CAUSTIC_WORLD_CELL %.6f\n#define CAUSTIC_WORLD_NEAR %.6f\n#define CAUSTIC_WORLD_FIXED_POINT %.1f\n",
			caustics.WORLD_ENTRIES,
			caustics.WORLD_PROBES,
			caustics.WORLD_CELL,
			caustics.WORLD_NEAR,
			caustics.WORLD_FIXED_POINT
		) .. (
			[[
		layout(buffer_reference, scalar) buffer CausticWorldGrid { uint v[]; };

		uint caustic_world_key(vec3 P, vec3 N, out float cell) {
			float level = max(floor(log2(max(distance(P, $B.caustic_world_origin.xyz), 1e-3) / CAUSTIC_WORLD_NEAR)), 0.0);
			cell = CAUSTIC_WORLD_CELL * exp2(level);
			ivec3 q = ivec3(floor(P / cell));
			vec3 a = abs(N);
			int axis = a.x > a.y && a.x > a.z ? 0 : (a.y > a.z ? 1 : 2);
			uvec4 h = pcg4d(uvec4(uvec3(q), uint(level) * 8u + uint(axis * 2) + (N[axis] < 0.0 ? 1u : 0u)));
			return max(h.x ^ h.y, 1u);
		}

		uint caustic_world_slot(uint key, uint probe) {
			return ((key + probe) & (CAUSTIC_WORLD_ENTRIES - 1u)) * 8u;
		}

		vec3 caustic_world_irradiance(vec3 P, vec3 N) {
			if ($B.caustic_world_grid == 0ul) return vec3(0.0);

			float cell;
			uint key = caustic_world_key(P, N, cell);
			CausticWorldGrid grid = CausticWorldGrid($B.caustic_world_grid);

			for (uint i = 0u; i < CAUSTIC_WORLD_PROBES; i++) {
				uint slot = caustic_world_slot(key, i);

				if (grid.v[slot] == key) return vec3(uintBitsToFloat(grid.v[slot + 4u]), uintBitsToFloat(grid.v[slot + 5u]), uintBitsToFloat(grid.v[slot + 6u]));
			}

			return vec3(0.0);
		}
	]]
		):gsub("%$B", block_name)
end

function caustics.GetHitGLSL()
	return "#ifndef CAUSTIC_HIT_GLSL\n#define CAUSTIC_HIT_GLSL\n" .. caustics.GetCoverageGLSL("radiance_cache_data", "caustic_hit_covered") .. caustics.GetWorldGLSL("radiance_cache_data") .. "\n#endif\n"
end

function caustics.GetGLSL(block_name)
	local normalization = caustics.SPECTRUM_NORMALIZATION
	return glsl_common.GetHashGLSL() .. glsl_common.GetFresnelGLSL() .. medium_surface.GetGLSL(block_name) .. caustics.GetWorldGLSL(block_name) .. optical_rays.GetGlassThroughGLSL() .. (
			[[
		#define CAUSTIC_MASK ]] .. string.format("0x%02X", scene_instances.MASK_SURFACES) .. [[

		#define CAUSTIC_FIXED_POINT ]] .. string.format("%.1f", caustics.FIXED_POINT) .. [[

		#define CAUSTIC_RAY_DISTANCE ]] .. string.format("%.1f", optical_rays.GetMaxDistance()) .. [[

		#define CAUSTIC_WAVELENGTH_MIN ]] .. string.format("%.1f", caustics.WAVELENGTH_MIN) .. [[

		#define CAUSTIC_WAVELENGTH_MAX ]] .. string.format("%.1f", caustics.WAVELENGTH_MAX) .. [[

		uint caustic_rng;

		float caustic_random() {
			caustic_rng = caustic_rng * 747796405u + 2891336453u;
			uint word = ((caustic_rng >> ((caustic_rng >> 28u) + 4u)) ^ caustic_rng) * 277803737u;
			return float(((word >> 22u) ^ word) >> 8u) / 16777216.0;
		}

		float caustic_lobe(float x, float mu, float below, float above) {
			float t = (x - mu) / (x < mu ? below : above);
			return exp(-0.5 * t * t);
		}

		vec3 caustic_spectrum(float nm) {
			float x = 1.056 * caustic_lobe(nm, 599.8, 37.9, 31.0) + 0.362 * caustic_lobe(nm, 442.0, 16.0, 26.7) - 0.065 * caustic_lobe(nm, 501.1, 20.4, 26.2);
			float y = 0.821 * caustic_lobe(nm, 568.8, 46.9, 40.5) + 0.286 * caustic_lobe(nm, 530.9, 16.3, 31.1);
			float z = 1.217 * caustic_lobe(nm, 437.0, 11.8, 36.0) + 0.681 * caustic_lobe(nm, 459.0, 26.0, 13.8);
			vec3 rgb = max(vec3(3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z), vec3(0.0));
			return rgb * vec3(NORMALIZATION);
		}

		float caustic_ior(float ior, float abbe, float nm) {
			if (abbe <= 0.0 || nm <= 0.0) return ior;

			float b = (ior - 1.0) / abbe / (1.0 / (WAVELENGTH_C * WAVELENGTH_C) - 1.0 / (WAVELENGTH_F * WAVELENGTH_F));
			float um = nm * 0.001;
			return ior + b * (1.0 / (um * um) - 1.0 / (WAVELENGTH_D * WAVELENGTH_D));
		}

		bool caustic_splits(float ior, float abbe, float dispersion_spread) {
			return dispersion_spread >= 0.0 && abbe > 0.0 && (ior - 1.0) / abbe >= dispersion_spread;
		}

		void caustic_basis(vec3 n, out vec3 t, out vec3 b) {
			float s = n.z >= 0.0 ? 1.0 : -1.0;
			float a = -1.0 / (s + n.z);
			float c = n.x * n.y * a;
			t = vec3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
			b = vec3(c, s + n.y * n.y * a, -n.y);
		}

		vec3 caustic_scatter(vec3 dir, vec3 N, float alpha, float eta, out bool refracted) {
			vec3 m = N;

			if (alpha > 1e-3) {
				vec3 T;
				vec3 B;
				caustic_basis(N, T, B);
				vec3 V = -dir;
				vec3 h = ImportanceSampleGGXVNDF(vec3(dot(V, T), dot(V, B), dot(V, N)), alpha, vec2(caustic_random(), caustic_random()));
				m = normalize(T * h.x + B * h.y + N * h.z);
			}

			float cos_i = dot(-dir, m);

			if (cos_i <= 0.0) m = N;

			vec3 out_dir = refract(dir, m, eta);
			refracted = dot(out_dir, out_dir) > 1e-6 && caustic_random() >= fresnel_dielectric(max(dot(-dir, m), 0.0), eta);
			return refracted ? normalize(out_dir) : reflect(dir, m);
		}

		int caustic_water_top(vec3 origin, vec3 dir, float max_t, out float hit_t) {
			hit_t = max_t;
			int hit = -1;

			if (abs(dir.y) < 1e-6) return -1;

			for (int i = optical_ranges.x; i < optical_ranges.x + optical_ranges.y; i++) {
				float t = (optical_volumes[i].surface_y - origin.y) / dir.y;

				if (t <= 0.0 || t >= hit_t) continue;

				vec3 local = (optical_volumes[i].to_local * vec4(origin + dir * t, 1.0)).xyz;

				if (abs(local.x) > optical_volumes[i].shape.x || abs(local.z) > optical_volumes[i].shape.z) continue;

				hit_t = t;
				hit = i;
			}

			return hit;
		}

		int caustic_water_at(vec3 P) {
			for (int i = optical_ranges.x; i < optical_ranges.x + optical_ranges.y; i++) {
				vec3 local = (optical_volumes[i].to_local * vec4(P, 1.0)).xyz;

				if (abs(local.x) <= optical_volumes[i].shape.x && abs(local.z) <= optical_volumes[i].shape.z && local.y <= 0.0 && local.y >= -optical_volumes[i].shape.y) return i;
			}

			return -1;
		}

		float caustic_water_exit(int volume, vec3 origin, vec3 dir) {
			float entry;
			float exit;

			if (!medium_box_intersect(optical_volumes[volume].to_local, -optical_volumes[volume].shape, vec3(optical_volumes[volume].shape.x, 0.0, optical_volumes[volume].shape.z), origin, dir, entry, exit)) return 0.0;

			return exit;
		}

		vec3 caustic_body_tint(ray_material material, float distance, uint instance, uint primitive, vec2 barycentrics) {
			vec3 through = ray_material_has_medium(material) ? medium_transmittance(material.medium_extinction, medium_scattering_at(material.medium_scattering, material.medium_porous_scattering, material.medium_porosity), material.medium_g, distance) : optical_glass_through(material, instance, primitive, barycentrics);

			return clamp(material.glass_refraction * through + (1.0 - material.glass_refraction) * (1.0 - material.glass_covering), vec3(0.0), vec3(1.0));
		}

		vec3 caustic_offset(vec3 P, vec3 N, float scale) {
			vec3 magnitude = abs(P);
			return P + N * (0.0005 * scale + 4e-6 * max(max(magnitude.x, magnitude.y), magnitude.z));
		}

		#define CAUSTIC_LOST 0
		#define CAUSTIC_LANDED 1
		#define CAUSTIC_DISPERSED 2

		int caustic_trace(vec3 origin, vec3 dir, inout vec3 flux, float wavelength, float footprint, int max_events, float dispersion_spread, float scale, out vec3 hit_P, out vec3 hit_Ng, out vec3 hit_dir, out float travelled) {
			int events = 0;
			travelled = 0.0;
			int water = caustic_water_at(origin);
			int glass_depth = 0;
			float max_t = CAUSTIC_RAY_DISTANCE;
			hit_P = vec3(0.0);
			hit_Ng = vec3(0.0);
			hit_dir = dir;

			for (int segment = 0; segment < 32; segment++) {
				rayQueryEXT query;
				rayQueryInitializeEXT(query, scene_tlas, gl_RayFlagsNoneEXT, CAUSTIC_MASK, origin, 0.0, dir, max_t);

				while (rayQueryProceedEXT(query)) {
					uint candidate = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, false));
					ray_material candidate_material = ray_materials[scene_instance_material(candidate)];

					if (candidate_material.glass != 0 || (candidate_material.transparent == 0 && ray_alpha_passes(candidate, scene_query_primitive(query, false), rayQueryGetIntersectionBarycentricsEXT(query, false)))) rayQueryConfirmIntersectionEXT(query);
				}

				bool hit = rayQueryGetIntersectionTypeEXT(query, true) != gl_RayQueryCommittedIntersectionNoneEXT;
				float t = hit ? rayQueryGetIntersectionTEXT(query, true) : max_t;
				float top_t;
				int top = caustic_water_top(origin, dir, t, top_t);
				float travel = top >= 0 ? top_t : t;
				travelled += travel;

				if (water >= 0 && glass_depth == 0) {
					float inside = caustic_water_exit(water, origin, dir);
					flux *= exp(-optical_volumes[water].extinction * min(travel, inside));

					if (inside < travel) water = -1;
				}

				if (top >= 0) {
					if (++events > max_events) return CAUSTIC_LOST;

					vec3 P = origin + dir * top_t;
					optical_volume volume = optical_volumes[top];

					if (wavelength <= 0.0 && caustic_splits(volume.ior, volume.abbe, dispersion_spread)) return CAUSTIC_DISPERSED;

					vec2 grad;
					vec3 hess = vec3(0.0);
					medium_surface_gradient(vec4(volume.wave, volume.wave_length, volume.wind_direction, volume.foam), volume.flow, P.xz, footprint, grad, hess);
					vec3 up = normalize(vec3(-grad.x, 1.0, -grad.y));
					bool entering = dir.y < 0.0;
					float ior = caustic_ior(volume.ior, volume.abbe, wavelength);
					bool refracted;
					dir = caustic_scatter(dir, entering ? up : -up, volume.roughness, entering ? 1.0 / ior : ior, refracted);

					if (refracted) water = entering ? top : -1;

					origin = P + dir * (0.0005 * scale);
					max_t = CAUSTIC_RAY_DISTANCE;
					continue;
				}

				if (!hit) return CAUSTIC_LOST;

				uint instance = uint(rayQueryGetIntersectionInstanceCustomIndexEXT(query, true));
				uint primitive = scene_query_primitive(query, true);
				vec2 barycentrics = rayQueryGetIntersectionBarycentricsEXT(query, true);
				scene_triangle tri = scene_hit_tri(instance, primitive);
				ray_material material = ray_materials[tri.material];
				vec3 P = origin + dir * t;
				vec3 Ng = -tri.normal;
				bool entering = dot(dir, Ng) < 0.0;

				if (material.glass == 0) {
					if (events == 0) return CAUSTIC_LOST;

					hit_P = P;
					hit_Ng = entering ? Ng : -Ng;
					hit_dir = dir;
					return CAUSTIC_LANDED;
				}

				if (!entering || material.double_sided != 0) flux *= caustic_body_tint(material, t, instance, primitive, barycentrics);

				if (material.caustic == 0) {
					origin = P + dir * (0.0005 * scale);
					max_t = CAUSTIC_RAY_DISTANCE;
					continue;
				}

				if (++events > max_events) return CAUSTIC_LOST;

				if (wavelength <= 0.0 && caustic_splits(material.medium_ior, material.abbe, dispersion_spread)) return CAUSTIC_DISPERSED;

				vec3 N = scene_hit_smooth_normal(instance, primitive, barycentrics);

				if (dot(N, Ng) <= 0.0) N = Ng;

				float outside_ior = water >= 0 ? caustic_ior(optical_volumes[water].ior, optical_volumes[water].abbe, wavelength) : 1.0;
				float ior = caustic_ior(material.medium_ior, material.abbe, wavelength);
				bool refracted;
				dir = caustic_scatter(dir, entering ? N : -N, material.roughness * material.roughness, entering ? outside_ior / ior : ior / outside_ior, refracted);

				if (refracted) glass_depth = max(glass_depth + (entering ? 1 : -1), 0);

				origin = caustic_offset(P, dot(dir, Ng) > 0.0 ? Ng : -Ng, scale);
				max_t = CAUSTIC_RAY_DISTANCE;
			}

			return CAUSTIC_LOST;
		}

		bool caustic_emit(uint id, out vec3 origin, out vec3 dir, out vec3 flux, out float footprint, out float stratum, out int lamp) {
			origin = vec3(0.0);
			dir = vec3(0.0);
			flux = vec3(0.0);
			footprint = 0.0;
			stratum = 0.0;
			lamp = -1;
			int k = 0;

			for (; k < $B.caustic_caster_count; k++) {
				if (float(id) < $B.caustic_grids[k * 2].w) break;
			}

			if (k >= $B.caustic_caster_count) return false;

			vec4 rect = $B.caustic_rects[k * 2];
			vec4 meta = $B.caustic_rects[k * 2 + 1];
			vec4 cell = $B.caustic_grids[k * 2];
			vec4 grid = $B.caustic_grids[k * 2 + 1];
			uint local_id = id - uint(cell.z);
			uint tile = local_id / 64u;
			uint inner = local_id % 64u;
			uint tiles_x = uint(grid.x) / 8u;
			uvec2 in_tile = uvec2(inner % 8u, inner / 8u);
			vec2 cell_index = vec2((tile % tiles_x) * 8u + in_tile.x, (tile / tiles_x) * 8u + in_tile.y);
			uint diagonal = in_tile.x ^ in_tile.y;
			uint bayer = ((in_tile.x & 1u) << 5u) | ((diagonal & 1u) << 4u) | ((in_tile.x & 2u) << 2u) | ((diagonal & 2u) << 1u) | ((in_tile.x & 4u) >> 1u) | ((diagonal & 4u) >> 2u);
			stratum = (float(bayer) + caustic_random()) / 64.0;
			vec2 uv = (cell_index + vec2(caustic_random(), caustic_random())) * cell.xy;
			int light_index = int(meta.z);
			lights_t light = $B.lights[light_index];

			if (meta.w > 0.5) {
				float one_minus_cos = uv.x * (1.0 - rect.w);
				float sin_theta = sqrt(max(one_minus_cos * (2.0 - one_minus_cos), 0.0));
				float phi = 6.28318530718 * uv.y;
				vec3 T;
				vec3 B;
				caustic_basis(rect.xyz, T, B);
				dir = normalize(T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + rect.xyz * (1.0 - one_minus_cos));

				for (int j = 0; j < k; j++) {
					vec4 other = $B.caustic_rects[j * 2 + 1];

					if (other.w > 0.5 && int(other.z) == light_index && dot(dir, $B.caustic_rects[j * 2].xyz) >= $B.caustic_rects[j * 2].w) return false;
				}

				caustic_basis(dir, T, B);
				float radius = sqrt(caustic_random()) * light.direction.w;
				float angle = 6.28318530718 * caustic_random();
				origin = light.position.xyz + (T * cos(angle) + B * sin(angle)) * radius;
				flux = light.color.rgb * light.color.a * grid.z;
				footprint = grid.w;
				lamp = light_index;
				return true;
			}

			vec3 S = $B.caustic_sun.xyz;
			vec3 T = $B.caustic_sun_u.xyz;
			vec3 B = $B.caustic_sun_v.xyz;
			uv += rect.xy;
			vec3 P = T * uv.x + B * uv.y + S * meta.x;
			float one_minus_cos = caustic_random() * (1.0 - cos(SUN_ANGULAR_RADIUS));
			float sin_theta = sqrt(max(one_minus_cos * (2.0 - one_minus_cos), 0.0));
			float phi = 6.28318530718 * caustic_random();
			dir = -normalize(T * (sin_theta * cos(phi)) + B * (sin_theta * sin(phi)) + S * (1.0 - one_minus_cos));
			origin = P - dir * meta.y;

			for (int j = 0; j < k; j++) {
				if ($B.caustic_rects[j * 2 + 1].w > 0.5) continue;

				vec4 other = $B.caustic_rects[j * 2];
				vec3 p = origin + dir * ((dot(origin, S) - $B.caustic_rects[j * 2 + 1].x) / -dot(dir, S));
				vec2 other_uv = vec2(dot(p, T), dot(p, B));

				if (all(greaterThanEqual(other_uv, other.xy)) && all(lessThan(other_uv, other.zw))) return false;
			}

			flux = light.color.rgb * light.color.a * get_ground_fog_sun_transmittance(get_atmosphere_camera_origin(P), S) * get_cloud_shadow(P) * (cell.x * cell.y);
			footprint = max(cell.x, cell.y);
			return true;
		}

		void caustic_world_add(vec3 P, vec3 N, vec3 flux) {
			if ($B.caustic_world_grid == 0ul) return;

			float cell;
			uint key = caustic_world_key(P, N, cell);
			CausticWorldGrid grid = CausticWorldGrid($B.caustic_world_grid);
			vec3 value = flux / (cell * cell) * CAUSTIC_WORLD_FIXED_POINT + vec3(caustic_random(), caustic_random(), caustic_random());

			for (uint i = 0u; i < CAUSTIC_WORLD_PROBES; i++) {
				uint slot = caustic_world_slot(key, i);
				uint previous = atomicCompSwap(grid.v[slot], 0u, key);

				if (previous == 0u || previous == key) {
					atomicAdd(grid.v[slot + 1u], uint(value.r));
					atomicAdd(grid.v[slot + 2u], uint(value.g));
					atomicAdd(grid.v[slot + 3u], uint(value.b));
					return;
				}
			}
		}

		bool caustic_land(vec3 P, vec3 Ng, vec3 incoming, vec3 flux);

		bool caustic_lamp_falloff(int lamp, vec3 emitted, float travelled, inout vec3 flux) {
			if (lamp < 0) return true;

			vec3 L;
			float attenuation;

			if (!get_light_vector_and_attenuation($B.lights[lamp], $B.lights[lamp].position.xyz + emitted * travelled, L, attenuation)) return false;

			flux *= attenuation * travelled * travelled;
			return true;
		}

		#define CAUSTIC_LANDED_SEEN 3

		int caustic_photon(uint id, int max_events, float dispersion_spread, float scale) {
			vec3 origin;
			vec3 dir;
			vec3 flux;
			float footprint;
			float stratum;
			int lamp;

			if (!caustic_emit(id, origin, dir, flux, footprint, stratum, lamp) || max(max(flux.r, flux.g), flux.b) <= 0.0) return CAUSTIC_LOST;

			uint rng = caustic_rng;
			vec3 P;
			vec3 Ng;
			vec3 incoming;
			float travelled;
			vec3 white = flux;
			int result = caustic_trace(origin, dir, white, 0.0, footprint, max_events, dispersion_spread, scale, P, Ng, incoming, travelled);

			if (result == CAUSTIC_LANDED && caustic_lamp_falloff(lamp, dir, travelled, white)) return caustic_land(P, Ng, incoming, white) ? CAUSTIC_LANDED_SEEN : CAUSTIC_LANDED;

			if (result != CAUSTIC_DISPERSED) return CAUSTIC_LOST;

			int landed = CAUSTIC_LOST;

			for (int band = 0; band < 3; band++) {
				caustic_rng = rng;
				float wavelength = mix(CAUSTIC_WAVELENGTH_MIN, CAUSTIC_WAVELENGTH_MAX, (float(band) + stratum) / 3.0);
				vec3 colored = flux * caustic_spectrum(wavelength) / 3.0;

				if (caustic_trace(origin, dir, colored, wavelength, footprint, max_events, dispersion_spread, scale, P, Ng, incoming, travelled) == CAUSTIC_LANDED && caustic_lamp_falloff(lamp, dir, travelled, colored)) {
					landed = max(landed, caustic_land(P, Ng, incoming, colored) ? CAUSTIC_LANDED_SEEN : CAUSTIC_LANDED);
				}
			}

			return landed;
		}

		layout(buffer_reference, scalar) buffer CausticStats { uint counts[]; };

		shared uint caustic_group_landed;
		shared uint caustic_group_seen;

		// photon counts and starts are multiples of 64, so a workgroup of 64 consecutive photons belongs to one entry
		void caustic_run(uint id, int max_events, float dispersion_spread, float scale) {
			if (gl_LocalInvocationIndex == 0u) {
				caustic_group_landed = 0u;
				caustic_group_seen = 0u;
			}

			barrier();

			int result = id < uint($B.caustic_photon_count) ? caustic_photon(id, max_events, dispersion_spread, scale) : CAUSTIC_LOST;

			if (result != CAUSTIC_LOST) atomicAdd(caustic_group_landed, 1u);

			if (result == CAUSTIC_LANDED_SEEN) atomicAdd(caustic_group_seen, 1u);

			barrier();

			if (gl_LocalInvocationIndex != 0u || caustic_group_landed == 0u || $B.caustic_stats == 0ul) return;

			for (int k = 0; k < $B.caustic_caster_count; k++) {
				if (float(id) < $B.caustic_grids[k * 2].w) {
					atomicAdd(CausticStats($B.caustic_stats).counts[k * 2], caustic_group_landed);
					atomicAdd(CausticStats($B.caustic_stats).counts[k * 2 + 1], caustic_group_seen);
					return;
				}
			}
		}

		float caustic_pixel_area(vec3 P, vec3 Ng) {
			vec3 to_camera = $B.camera_position.xyz - P;
			float r = length(to_camera);
			float z = abs(($B.view * vec4(P, 1.0)).z);
			float pixel = 4.0 / (abs($B.projection[0][0] * $B.projection[1][1]) * $B.render_size.x * $B.render_size.y);
			return pixel * z * z * z / (r * max(dot(Ng, to_camera) / r, 0.05));
		}

		ivec2 caustic_screen_pixel(vec3 P, vec3 Ng) {
			vec4 clip = $B.projection * ($B.view * vec4(P, 1.0));

			if (clip.w <= 1e-5) return ivec2(-1);

			vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

			if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) return ivec2(-1);

			vec3 to_camera = $B.camera_position.xyz - P;

			if (dot(Ng, to_camera) <= 0.0) return ivec2(-1);

			ivec2 pixel = ivec2(uv * $B.render_size);
			float depth = gbuffer_depth(pixel);

			if (depth <= 0.0) return ivec2(-1);

			vec3 G = get_world_pos_at((vec2(pixel) + 0.5) / $B.render_size, depth);

			if (abs(dot(Ng, G - P)) > 0.01 * $B.view_scale + 0.004 * length(to_camera)) return ivec2(-1);

			return pixel;
		}

		void caustic_add(uint index, vec3 value) {
			if (any(isnan(value)) || any(isinf(value))) return;

			vec3 fixed_value = value * CAUSTIC_FIXED_POINT + vec3(caustic_random(), caustic_random(), caustic_random());
			atomicAdd(caustic_raw[index * 4u], uint(fixed_value.r));
			atomicAdd(caustic_raw[index * 4u + 1u], uint(fixed_value.g));
			atomicAdd(caustic_raw[index * 4u + 2u], uint(fixed_value.b));
			atomicAdd(caustic_raw[index * 4u + 3u], 1u);
		}

		vec3 caustic_take(uint index) {
			vec3 value = vec3(caustic_raw[index * 4u], caustic_raw[index * 4u + 1u], caustic_raw[index * 4u + 2u]) / CAUSTIC_FIXED_POINT;
			caustic_raw[index * 4u] = 0u;
			caustic_raw[index * 4u + 1u] = 0u;
			caustic_raw[index * 4u + 2u] = 0u;
			caustic_raw[index * 4u + 3u] = 0u;
			return value;
		}
	]]
		):gsub("%$B", block_name):gsub(
			"NORMALIZATION",
			string.format("%.6f, %.6f, %.6f", normalization[1], normalization[2], normalization[3])
		):gsub("WAVELENGTH_([CDF])", function(line)
			return string.format("%.4f", screen_refraction["WAVELENGTH_" .. line])
		end)
end

function caustics.GetBufferDeclarationGLSL(binding)
	return [[
		layout(std430, set = 0, binding = ]] .. binding .. [[) buffer CausticRaw {
			uint caustic_raw[];
		};
	]]
end

do
	local buffers = {}

	function caustics.GetBuffer(name, cmd, width, height)
		local entry = buffers[name]
		local size = math.max(width * height * 16, 16)

		if entry and entry.size == size then return entry.buffer end

		if entry then entry.buffer:Remove() end

		local buffer = render.CreateBuffer{
			byte_size = size,
			buffer_usage = {"storage_buffer", "transfer_dst"},
			memory_property = {"device_local"},
			label = "caustics_" .. name,
		}
		cmd:FillBuffer(buffer, 0, size, 0)
		cmd:PipelineBarrier{
			srcStage = "transfer",
			dstStage = "compute",
			bufferBarriers = {
				{
					buffer = buffer,
					srcAccessMask = "transfer_write",
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
		buffers[name] = {buffer = buffer, size = size}
		return buffer
	end

	local world

	function caustics.GetWorldGrid(cmd)
		if world then return world end

		world = render.CreateBuffer{
			byte_size = caustics.WORLD_ENTRIES * 32,
			buffer_usage = {"storage_buffer", "shader_device_address", "transfer_dst"},
			memory_property = {"device_local"},
			label = "caustics_world",
		}
		cmd:FillBuffer(world, 0, world:GetSize(), 0)
		cmd:PipelineBarrier{
			srcStage = "transfer",
			dstStage = "compute",
			bufferBarriers = {
				{
					buffer = world,
					srcAccessMask = "transfer_write",
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
		buffers.world = {buffer = world, size = world:GetSize()}
		return world
	end

	function caustics.GetWorldGridAddress()
		return world and world:GetDeviceAddress() or 0
	end

	function caustics.Barrier(cmd, name, stages)
		cmd:PipelineBarrier{
			srcStage = "compute",
			dstStage = stages or "compute",
			bufferBarriers = {
				{
					buffer = buffers[name].buffer,
					srcAccessMask = {"shader_read", "shader_write"},
					dstAccessMask = {"shader_read", "shader_write"},
				},
			},
		}
	end
end

return caustics
