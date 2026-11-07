local ffi = require("ffi")
local event = import("goluwa/event.lua")
local commands = import("goluwa/cli/commands.lua")
local system = import("goluwa/system.lua")
local render = import("goluwa/render/render.lua")
local Texture = import("goluwa/render/texture.lua")
local Entity = import("goluwa/entities/entity.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local store = import("goluwa/render3d/scene/store.lua")
local instances = import("goluwa/render3d/scene/instances.lua")
local Visual = import("goluwa/entities/components/visual.lua")
local raycast = import("goluwa/render3d/raycast.lua")
local atmosphere = import("goluwa/render3d/atmosphere.lua")
local surface_weather = import("goluwa/render3d/surface_weather.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local glsl_common = import("goluwa/render3d/glsl_common.lua")
local shader_features = import("goluwa/render3d/shader_features.lua")
local vfs = import("goluwa/vfs.lua")
local surface_conditions = {}
surface_conditions.CELL_SIZE = 0.5
surface_conditions.TICK = 1 / 15
surface_conditions.RAY_TIME = 0.0015
surface_conditions.MAX_CELLS = 200000
surface_conditions.MAX_SITES = 4096
surface_conditions.LIGHT_COUNT = 8
surface_conditions.LIGHT_CLUSTER_SIZE = 4
surface_conditions.WARP_SCALE = 0.29
surface_conditions.DYNAMIC_SCAN_TICKS = 30
surface_conditions.WEATHER_WETNESS = 0.8
surface_conditions.WARP_DISTANCE = 0.9
surface_conditions.kinds = {
	import("goluwa/render3d/surface_conditions/fire.lua"),
	import("goluwa/render3d/surface_conditions/frost.lua"),
	import("goluwa/render3d/surface_conditions/water.lua"),
}

for _, file in ipairs(vfs.Find("lua/surface_conditions/%.lua$")) do
	surface_conditions.kinds[#surface_conditions.kinds + 1] = import("lua/surface_conditions/" .. file)
end

local CELL = surface_conditions.CELL_SIZE
local INV_CELL = 1 / CELL
local BRICK = 4
local BRICK_CELLS = BRICK * BRICK * BRICK
local MAX_CHANNELS = 6
local kinds = surface_conditions.kinds
local kinds_by_name = {}
local channels = {}

for i, kind in ipairs(kinds) do
	kind.index = i - 1
	kinds_by_name[kind.name] = kind

	for _, name in ipairs(kind.channels) do
		channels[#channels + 1] = name
	end
end

assert(#channels <= MAX_CHANNELS, "surface conditions have more than 6 channels")
surface_conditions.channels = channels
surface_conditions.weather_wetness = 0
local cells = {}
local cell_count = 0
local active = {}
local dirty = {}
local ray_deadline = 0
local bounds_min = Vec3(math.huge, math.huge, math.huge)
local bounds_max = Vec3(-math.huge, -math.huge, -math.huge)
local OFFSET = 65536
local SPAN = 131072

local function cell_key(x, y, z)
	return ((x + OFFSET) * SPAN + (y + OFFSET)) * SPAN + (z + OFFSET)
end

function surface_conditions.SetExposure(kind_name, entries)
	kinds_by_name[kind_name].exposure = entries
end

function surface_conditions.GetCell(x, y, z)
	return cells[cell_key(x, y, z)]
end

function surface_conditions.GetCellAt(px, py, pz)
	return cells[cell_key(math.floor(px * INV_CELL), math.floor(py * INV_CELL), math.floor(pz * INV_CELL))]
end

function surface_conditions.GetCellCount()
	return cell_count
end

function surface_conditions.GetActiveCount()
	return #active
end

function surface_conditions.Touch(cell)
	if not cell.dirty then
		cell.dirty = true
		dirty[#dirty + 1] = cell
	end
end

function surface_conditions.Activate(cell)
	if not cell.active then
		cell.active = true
		active[#active + 1] = cell
	end
end

local function create_cell(x, y, z, px, py, pz, nx, ny, nz, flammability, thin)
	local key = cell_key(x, y, z)
	local cell = cells[key]

	if cell then
		if not cell.omni and cell.nx * nx + cell.ny * ny + cell.nz * nz < -0.3 then
			cell.omni = true
			surface_conditions.Touch(cell)
		end

		return cell
	end

	if cell_count >= surface_conditions.MAX_CELLS then return nil end

	cell = {
		key = key,
		x = x,
		y = y,
		z = z,
		px = px,
		py = py,
		pz = pz,
		nx = nx,
		ny = ny,
		nz = nz,
		omni = false,
		flammability = flammability,
		thin = thin,
		active = false,
		dirty = false,
		brick = false,
		slot = 0,
		word0 = -1,
		word1 = -1,
		word2 = -1,
	}

	for _, name in ipairs(channels) do
		cell[name] = 0
	end

	for _, kind in ipairs(kinds) do
		kind.Init(cell)
	end

	cells[key] = cell
	cell_count = cell_count + 1
	bounds_min.x = math.min(bounds_min.x, x * CELL)
	bounds_min.y = math.min(bounds_min.y, y * CELL)
	bounds_min.z = math.min(bounds_min.z, z * CELL)
	bounds_max.x = math.max(bounds_max.x, (x + 1) * CELL)
	bounds_max.y = math.max(bounds_max.y, (y + 1) * CELL)
	bounds_max.z = math.max(bounds_max.z, (z + 1) * CELL)
	surface_conditions.Touch(cell)
	return cell
end

local function is_static(entity)
	while entity and entity:IsValid() do
		local body = entity.rigid_body

		if body and not body.WorldGeometry and not body:IsStatic() then return false end

		entity = entity:GetParent()
	end

	return true
end

local function get_material_response(material)
	return material:GetFlammability() * (
			1 - math.clamp(material:GetMetallicMultiplier(), 0, 1)
		),
	material:GetAlphaTest() or material:GetDetailBending() ~= "none"
end

do
	local function get_surface(hit)
		local model = hit.model
		local entry = model:GetRenderEntries()[hit.primitive_index]

		if not entry then return 0, false end

		return get_material_response(model:GetResolvedMaterial(entry))
	end

	function surface_conditions.Cast(ox, oy, oz, dx, dy, dz, distance)
		if system.GetTime() > ray_deadline then return nil end

		local hit = raycast.CastClosest(Vec3(ox, oy, oz), Vec3(dx, dy, dz), distance, is_static)

		if not hit or not hit.model then return nil end

		return hit
	end

	function surface_conditions.CellFromHit(hit)
		local p, n = hit.position, hit.normal
		local flammability, thin = get_surface(hit)
		return create_cell(
			math.floor(p.x * INV_CELL),
			math.floor(p.y * INV_CELL),
			math.floor(p.z * INV_CELL),
			p.x,
			p.y,
			p.z,
			n.x,
			n.y,
			n.z,
			flammability,
			thin
		)
	end
end

function surface_conditions.RandomTangent(cell, bias_x, bias_y, bias_z)
	local nx, ny, nz = cell.nx, cell.ny, cell.nz
	local rx, ry, rz = math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1
	rx, ry, rz = rx + bias_x, ry + bias_y, rz + bias_z
	local d = rx * nx + ry * ny + rz * nz
	rx, ry, rz = rx - nx * d, ry - ny * d, rz - nz * d
	local length = math.sqrt(rx * rx + ry * ry + rz * rz)

	if length < 1e-4 then
		if math.abs(ny) < 0.9 then
			rx, ry, rz = nz, 0, -nx
		else
			rx, ry, rz = 1, 0, 0
		end

		length = math.sqrt(rx * rx + ry * ry + rz * rz)
	end

	return rx / length, ry / length, rz / length
end

function surface_conditions.Reach(cell, tx, ty, tz)
	local step = CELL * 1.5
	local lift = CELL * 0.4
	local px, py, pz, nx, ny, nz = cell.px, cell.py, cell.pz, cell.nx, cell.ny, cell.nz
	local tx2, ty2, tz2 = px + tx * step, py + ty * step, pz + tz * step
	local x, y, z = math.floor(tx2 * INV_CELL), math.floor(ty2 * INV_CELL), math.floor(tz2 * INV_CELL)
	local key = cell_key(x, y, z)

	if key == cell.key then return nil end

	local found = cells[key]

	if found then return found end

	if cell.probed and cell.probed[key] then return nil end

	if system.GetTime() > ray_deadline then return nil end

	local ox, oy, oz = px + nx * lift, py + ny * lift, pz + nz * lift
	local hit = surface_conditions.Cast(ox, oy, oz, tx, ty, tz, step)

	if not hit then
		local sx, sy, sz = ox + tx * step, oy + ty * step, oz + tz * step
		hit = surface_conditions.Cast(sx, sy, sz, -nx, -ny, -nz, lift + CELL)

		if not hit then
			hit = surface_conditions.Cast(
				sx - nx * (lift + CELL * 0.5),
				sy - ny * (lift + CELL * 0.5),
				sz - nz * (lift + CELL * 0.5),
				-tx,
				-ty,
				-tz,
				step
			)
		end
	end

	if hit then
		local found = surface_conditions.CellFromHit(hit)

		if found and found ~= cell then return found end
	elseif system.GetTime() > ray_deadline then
		return nil
	end

	cell.probed = cell.probed or {}
	cell.probed[key] = true
	return nil
end

local exposed_direction = Vec3(0, 1, 0)

function surface_conditions.IsExposed(cell)
	local exposed = cell.exposed

	if exposed ~= nil then return exposed end

	local direction = exposed_direction
	local facing = cell.nx * direction.x + cell.ny * direction.y + cell.nz * direction.z

	if facing < -0.3 then return false end

	if system.GetTime() > ray_deadline then return facing > 0.3 end

	exposed = not surface_conditions.Cast(
		cell.px + cell.nx * 0.1,
		cell.py + cell.ny * 0.1,
		cell.pz + cell.nz * 0.1,
		direction.x,
		direction.y,
		direction.z,
		60
	)
	cell.exposed = exposed
	return exposed
end

function surface_conditions.GetWeatherWetness(cell)
	local weather = surface_conditions.weather_wetness

	if weather <= 0 or not surface_conditions.IsExposed(cell) then return 0 end

	return weather
end

function surface_conditions.Above(cell, height)
	local x, z = cell.x, cell.z

	for step = 1, math.ceil(height * INV_CELL) do
		local found = cells[cell_key(x, cell.y + step, z)]

		if found then return found end
	end

	if cell.probed_above or system.GetTime() > ray_deadline then return nil end

	cell.probed_above = true
	local hit = surface_conditions.Cast(cell.px, cell.py + CELL * 0.5, cell.pz, 0, 1, 0, height)

	if hit then return surface_conditions.CellFromHit(hit) end

	return nil
end

do
	local function basis(nx, ny, nz)
		local ax, ay, az = 0, 1, 0

		if math.abs(ny) > 0.9 then ax, ay, az = 1, 0, 0 end

		local ux, uy, uz = ay * nz - az * ny, az * nx - ax * nz, ax * ny - ay * nx
		local length = math.sqrt(ux * ux + uy * uy + uz * uz)
		ux, uy, uz = ux / length, uy / length, uz / length
		return ux, uy, uz, ny * uz - nz * uy, nz * ux - nx * uz, nx * uy - ny * ux
	end

	local found = {}
	local SPHERE = {}

	for i = 0, 13 do
		local y = 1 - (i + 0.5) / 14 * 2
		local r = math.sqrt(1 - y * y)
		local a = i * 2.39996323
		SPHERE[#SPHERE + 1] = {math.cos(a) * r, y, math.sin(a) * r}
	end

	local function add(cell, position, radius)
		if not cell or found[cell] then return end

		local dx, dy, dz = cell.px - position.x, cell.py - position.y, cell.pz - position.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)

		if distance > radius + CELL then return end

		found[cell] = 1 - math.smoothstep(radius * 0.5, radius + CELL, distance)
	end

	function surface_conditions.FindSurfaces(position, radius, normal)
		table.clear(found)
		local saved = ray_deadline
		ray_deadline = math.huge
		local nx, ny, nz = normal.x, normal.y, normal.z
		local ux, uy, uz, vx, vy, vz = basis(nx, ny, nz)
		local reach = math.max(radius, 1)
		local spacing = math.max(CELL * 2, radius / 3)
		local steps = math.floor(radius / spacing + 0.5)
		local fill = math.ceil(spacing * INV_CELL)

		for i = -steps, steps do
			for j = -steps, steps do
				local u, v = (i + (math.random() - 0.5) * 0.6) * spacing,
				(j + (math.random() - 0.5) * 0.6) * spacing

				if u * u + v * v <= (radius + spacing * 0.5) ^ 2 then
					local hit = surface_conditions.Cast(
						position.x + nx * reach + ux * u + vx * v,
						position.y + ny * reach + uy * u + vy * v,
						position.z + nz * reach + uz * u + vz * v,
						-nx,
						-ny,
						-nz,
						reach * 2
					)

					if hit then
						local center = surface_conditions.CellFromHit(hit)
						add(center, position, radius)

						if center and fill > 0 then
							local p, n = hit.position, hit.normal
							local hux, huy, huz, hvx, hvy, hvz = basis(n.x, n.y, n.z)

							for a = -fill, fill do
								for b = -fill, fill do
									local ja, jb = a + (math.random() - 0.5) * 0.6, b + (math.random() - 0.5) * 0.6
									local px = p.x + (hux * ja + hvx * jb) * CELL
									local py = p.y + (huy * ja + hvy * jb) * CELL
									local pz = p.z + (huz * ja + hvz * jb) * CELL
									add(
										create_cell(
											math.floor(px * INV_CELL),
											math.floor(py * INV_CELL),
											math.floor(pz * INV_CELL),
											px,
											py,
											pz,
											n.x,
											n.y,
											n.z,
											center.flammability,
											center.thin
										),
										position,
										radius
									)
								end
							end
						end
					end
				end
			end
		end

		for _, dir in ipairs(SPHERE) do
			local hit = surface_conditions.Cast(
				position.x + nx * 0.1,
				position.y + ny * 0.1,
				position.z + nz * 0.1,
				dir[1],
				dir[2],
				dir[3],
				radius + CELL
			)

			if hit then add(surface_conditions.CellFromHit(hit), position, radius) end
		end

		ray_deadline = saved
		return found
	end
end

function surface_conditions.HasContent()
	return cell_count > 0
end

function surface_conditions.Apply(kind_name, position, radius, amount, normal)
	local kind = assert(kinds_by_name[kind_name], "unknown surface condition " .. tostring(kind_name))

	for cell, falloff in pairs(surface_conditions.FindSurfaces(position, radius, normal or Vec3(0, 1, 0))) do
		kind.Apply(surface_conditions, cell, amount * falloff)
		surface_conditions.Activate(cell)
		surface_conditions.Touch(cell)
	end
end

function surface_conditions.Query(position, radius, channel)
	local result = 0
	local x0, x1 = math.floor((position.x - radius) * INV_CELL),
	math.floor((position.x + radius) * INV_CELL)
	local y0, y1 = math.floor((position.y - radius) * INV_CELL),
	math.floor((position.y + radius) * INV_CELL)
	local z0, z1 = math.floor((position.z - radius) * INV_CELL),
	math.floor((position.z + radius) * INV_CELL)

	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local cell = cells[cell_key(x, y, z)]

				if cell and cell[channel] > result then result = cell[channel] end
			end
		end
	end

	return result
end

local build_sites
local update_light_targets

function surface_conditions.Clear()
	cells = {}
	cell_count = 0
	table.clear(active)
	table.clear(dirty)
	bounds_min:Set(math.huge, math.huge, math.huge)
	bounds_max:Set(-math.huge, -math.huge, -math.huge)
	surface_conditions.ResetGPU()
	build_sites()
	surface_conditions.RemoveLights()
end

function surface_conditions.MarkDynamicVisuals()
	for _, visual in ipairs(Visual.Instances) do
		local list = visual.scene_instances

		if list then
			local dynamic = Visual.Library.IsVisualDynamic(visual) and 1 or 0

			for i = 1, #list do
				instances.SetDynamic(list[i].id, dynamic)
			end
		end
	end
end

local dynamic_countdown = 0

function surface_conditions.Step(dt)
	dynamic_countdown = dynamic_countdown - 1

	if dynamic_countdown <= 0 then
		dynamic_countdown = surface_conditions.DYNAMIC_SCAN_TICKS
		surface_conditions.MarkDynamicVisuals()
	end

	ray_deadline = system.GetTime() + surface_conditions.RAY_TIME
	surface_conditions.wind = atmosphere.GetWind()
	surface_conditions.temperature = atmosphere.GetTemperature()
	surface_conditions.weather_wetness = math.max(surface_weather.GetWetness(), surface_weather.GetSnowCover()) * surface_conditions.WEATHER_WETNESS

	if surface_weather.precipitation_direction:GetDot(exposed_direction) < 0.995 then
		exposed_direction = surface_weather.precipitation_direction:Copy()

		for _, cell in pairs(cells) do
			cell.exposed = nil
		end
	end

	for i = #active, 1, -1 do
		local cell = active[i]
		local keep = false

		for k = 1, #kinds do
			if kinds[k].Step(surface_conditions, cell, dt) then keep = true end
		end

		if not keep then
			cell.active = false
			active[i] = active[#active]
			active[#active] = nil
		end
	end

	build_sites()
	update_light_targets()
end

do
	local Site = ffi.typeof([[struct {
		float position[3];
		uint32_t kind_seed;
		float normal[3];
		float spare0;
		float values[4];
	}]])
	local SITE_BYTES = ffi.sizeof(Site)
	local sites = ffi.typeof("$[?]", Site)(surface_conditions.MAX_SITES)
	local site_count = 0
	local kind_first = {}
	local kind_count = {}
	local value_sums = {}
	local buffers = {}
	local current_buffer

	for _, kind in ipairs(kinds) do
		value_sums[kind.index] = {0, 0, 0, 0}
	end

	local function site_seed(a, b, c, kind)
		return bit.bor(
			bit.lshift(
				bit.band(
					bit.bxor(bit.tobit(a * 73856093), bit.tobit(b * 19349663), bit.tobit(c * 83492791)),
					0xFFFFFF
				),
				4
			),
			kind.index
		)
	end

	surface_conditions.SITE_BYTES = SITE_BYTES

	function build_sites()
		site_count = 0

		for _, kind in ipairs(kinds) do
			local sums = value_sums[kind.index]
			sums[1], sums[2], sums[3], sums[4] = 0, 0, 0, 0
			kind_first[kind.index] = site_count

			if kind.Site then
				for i = 1, #active do
					if site_count >= surface_conditions.MAX_SITES then break end

					local cell = active[i]
					local a, b, c, d = kind.Site(cell)

					if a > 0 or b > 0 or c > 0 or d > 0 then
						local site = sites[site_count]
						site.position[0], site.position[1], site.position[2] = cell.px, cell.py, cell.pz
						site.normal[0], site.normal[1], site.normal[2] = cell.nx, cell.ny, cell.nz
						site.kind_seed = site_seed(cell.x, cell.y, cell.z, kind)
						site.values[0], site.values[1], site.values[2], site.values[3] = a, b, c, d
						sums[1], sums[2], sums[3], sums[4] = sums[1] + a, sums[2] + b, sums[3] + c, sums[4] + d
						site_count = site_count + 1
					end
				end
			end

			kind_count[kind.index] = site_count - kind_first[kind.index]
		end
	end

	function surface_conditions.GetSiteCount()
		return site_count
	end

	function surface_conditions.GetKindSites(kind)
		return kind_first[kind.index] or 0,
		kind_count[kind.index] or 0,
		value_sums[kind.index]
	end

	function surface_conditions.GetSitesAddress()
		return current_buffer and current_buffer:GetDeviceAddress() or 0
	end

	function surface_conditions.UploadSites()
		if site_count == 0 then
			current_buffer = nil
			return
		end

		local index = (render.frame_serial or 0) % 3
		local buffer = buffers[index]

		if not buffer then
			buffer = render.CreateBuffer{
				byte_size = surface_conditions.MAX_SITES * SITE_BYTES,
				buffer_usage = {"storage_buffer", "shader_device_address"},
				memory_property = {"host_visible", "host_coherent"},
				label = "surface_condition_sites",
			}
			buffers[index] = buffer
		end

		ffi.copy(buffer:Map(), sites, site_count * SITE_BYTES)
		current_buffer = buffer
	end

	function surface_conditions.GetSitesGLSL()
		return [[
			struct SurfaceConditionSite {
				vec3 position;
				uint kind_seed;
				vec3 normal;
				float spare0;
				vec4 values;
			};

			layout(buffer_reference, scalar) readonly buffer SurfaceConditionSites { SurfaceConditionSite s[]; };
		]]
	end
end

do
	local HashSlot = ffi.typeof("struct { int32_t x, y, z, brick; }")
	local BrickRow = ffi.typeof("struct { uint32_t cells[$]; }", BRICK_CELLS * 3)
	local hash_table
	local brick_table
	local hash_size = 0
	local bricks = {}
	local brick_count = 0
	local noise_texture

	local function hash_brick(x, y, z, mask)
		return bit.band(
			bit.bxor(bit.tobit(x * 73856093), bit.tobit(y * 19349663), bit.tobit(z * 83492791)),
			mask
		)
	end

	local function insert_brick(brick)
		local mask = hash_size - 1
		local slot = hash_brick(brick.x, brick.y, brick.z, mask)
		local ptr = hash_table.ptr

		while ptr[slot].brick ~= 0 do
			slot = bit.band(slot + 1, mask)
		end

		ptr[slot].x, ptr[slot].y, ptr[slot].z, ptr[slot].brick = brick.x, brick.y, brick.z, brick.row + 1
		hash_table:Touch(slot)
	end

	local function rebuild_hash(size)
		hash_size = size
		hash_table:Reserve(size)
		ffi.fill(hash_table.ptr, hash_table.capacity * hash_table.row_size)
		hash_table:TouchRange(0, hash_table.capacity)

		for _, brick in pairs(bricks) do
			insert_brick(brick)
		end
	end

	local function get_brick(cell)
		local bx, by, bz = math.floor(cell.x / BRICK), math.floor(cell.y / BRICK), math.floor(cell.z / BRICK)
		local key = cell_key(bx, by, bz)
		local brick = bricks[key]

		if not brick then
			brick = {x = bx, y = by, z = bz, row = brick_count}
			brick_count = brick_count + 1
			bricks[key] = brick
			brick_table:Reserve(brick_count)
			ffi.fill(brick_table.ptr + brick.row, ffi.sizeof(BrickRow))
			brick_table:Touch(brick.row)

			if brick_count * 2 > hash_size then
				rebuild_hash(math.max(256, hash_size * 2))
			else
				insert_brick(brick)
			end
		end

		cell.brick = brick
		cell.slot = (
				cell.x - bx * BRICK
			) + (
				cell.y - by * BRICK
			) * BRICK + (
				cell.z - bz * BRICK
			) * BRICK * BRICK
		return brick
	end

	local function quantize(v)
		if v <= 0 then return 0 end

		if v >= 1 then return 255 end

		return math.floor(v * 255 + 0.5)
	end

	local function pack(cell, first)
		local a = channels[first + 1]
		local b = channels[first + 2]
		local c = channels[first + 3]
		local d = channels[first + 4]
		return (
				a and
				quantize(cell[a]) or
				0
			) + (
				b and
				quantize(cell[b]) or
				0
			) * 256 + (
				c and
				quantize(cell[c]) or
				0
			) * 65536 + (
				d and
				quantize(cell[d]) or
				0
			) * 16777216
	end

	local function pack_normal(cell)
		if cell.omni then return 1 end

		local x, y, z = cell.nx, cell.ny, cell.nz
		local l1 = math.abs(x) + math.abs(y) + math.abs(z)
		x, y, z = x / l1, y / l1, z / l1

		if z < 0 then
			x, y = (1 - math.abs(y)) * (x >= 0 and 1 or -1), (1 - math.abs(x)) * (y >= 0 and 1 or -1)
		end

		return 3 + math.floor((x * 0.5 + 0.5) * 32767 + 0.5) * 4 + math.floor((y * 0.5 + 0.5) * 32767 + 0.5) * 131072
	end

	function surface_conditions.ResetGPU()
		bricks = {}
		brick_count = 0

		if hash_table then rebuild_hash(256) end
	end

	function surface_conditions.FlushGPU(cmd)
		if not hash_table then
			hash_table = store.CreateTable{
				name = "surface_condition_hash",
				ctype = HashSlot,
				capacity = 256,
				staged = true,
			}
			brick_table = store.CreateTable{
				name = "surface_condition_bricks",
				ctype = BrickRow,
				capacity = 256,
				staged = true,
			}
			rebuild_hash(256)

			for _, cell in pairs(cells) do
				cell.brick = false
				surface_conditions.Touch(cell)
			end
		end

		if dirty[1] then
			for i = 1, #dirty do
				local cell = dirty[i]
				dirty[i] = nil
				cell.dirty = false
				local brick = cell.brick or get_brick(cell)
				local word0, word1, word2 = pack(cell, 0), pack(cell, 4), pack_normal(cell)

				if word0 ~= cell.word0 or word1 ~= cell.word1 or word2 ~= cell.word2 then
					cell.word0, cell.word1, cell.word2 = word0, word1, word2
					local words = brick_table.ptr[brick.row].cells
					local base = cell.slot * 3
					words[base], words[base + 1], words[base + 2] = word0, word1, word2
					brick_table:Touch(brick.row)
				end
			end
		end

		store.FlushStaged(cmd)
	end

	function surface_conditions.GetNoiseTexture()
		if noise_texture then return noise_texture end

		noise_texture = Texture.New{
			width = 512,
			height = 512,
			format = "r8g8b8a8_unorm",
			mip_map_levels = "auto",
			image = {
				usage = {"sampled", "transfer_dst", "transfer_src", "color_attachment"},
			},
			sampler = {
				min_filter = "linear",
				mag_filter = "linear",
				mipmap_mode = "linear",
				wrap_s = "repeat",
				wrap_t = "repeat",
			},
		}
		noise_texture:Shade(
			glsl_common.GetHashGLSL() .. [[
			vec2 noise_gradient(ivec2 c, int period, uint seed) {
				c = ((c % period) + period) % period;
				float a = pcg_unorm(pcg3d(uvec3(uvec2(c), seed)).x) * 6.2831853;
				return vec2(cos(a), sin(a));
			}

			float gradient_noise(vec2 p, int period, uint seed) {
				ivec2 i = ivec2(floor(p));
				vec2 f = fract(p);
				vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
				float a = dot(noise_gradient(i, period, seed), f);
				float b = dot(noise_gradient(i + ivec2(1, 0), period, seed), f - vec2(1.0, 0.0));
				float c = dot(noise_gradient(i + ivec2(0, 1), period, seed), f - vec2(0.0, 1.0));
				float d = dot(noise_gradient(i + ivec2(1, 1), period, seed), f - vec2(1.0, 1.0));
				return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
			}

			float fbm(vec2 uv, int period, int octaves, uint seed) {
				float sum = 0.0;
				float amplitude = 0.5;
				float norm = 0.0;

				for (int i = 0; i < octaves; i++) {
					sum += gradient_noise(uv * float(period), period, seed + uint(i) * 17u) * amplitude;
					norm += amplitude;
					amplitude *= 0.5;
					period *= 2;
				}

				return clamp(sum / norm * 1.6 + 0.5, 0.0, 1.0);
			}

			vec2 cell_point(ivec2 c, int period) {
				c = ((c % period) + period) % period;
				return pcg3d_unorm(uvec3(uvec2(c), 913u)).xy;
			}

			vec2 voronoi(vec2 uv, int period) {
				vec2 p = uv * float(period);
				ivec2 i = ivec2(floor(p));
				vec2 f = fract(p);
				vec2 nearest_offset = vec2(0.0);
				ivec2 nearest_cell = i;
				float nearest = 8.0;

				for (int y = -1; y <= 1; y++) {
					for (int x = -1; x <= 1; x++) {
						ivec2 g = ivec2(x, y);
						vec2 r = vec2(g) + cell_point(i + g, period) - f;
						float d = dot(r, r);

						if (d < nearest) {
							nearest = d;
							nearest_offset = r;
							nearest_cell = i + g;
						}
					}
				}

				float edge = 8.0;

				for (int y = -2; y <= 2; y++) {
					for (int x = -2; x <= 2; x++) {
						ivec2 g = ivec2(floor(nearest_offset + f)) + ivec2(x, y);
						vec2 r = vec2(g) + cell_point(i + g, period) - f;
						vec2 delta = r - nearest_offset;

						if (dot(delta, delta) > 1e-5) edge = min(edge, dot(0.5 * (nearest_offset + r), normalize(delta)));
					}
				}

				ivec2 wrapped = ((nearest_cell % period) + period) % period;
				return vec2(edge, pcg_unorm(pcg3d(uvec3(uvec2(wrapped), 77u)).x));
			}

			vec4 shade(vec2 uv, vec3 _cube_dir) {
				vec2 cracks = voronoi(uv, 12);
				return vec4(fbm(uv, 4, 5, 3u), fbm(uv, 16, 4, 101u), clamp(cracks.x * 2.0, 0.0, 1.0), cracks.y);
			}
		]]
		)
		return noise_texture
	end

	surface_conditions.block = {
		{"effect_hash", "uint64_t"},
		{"effect_bricks", "uint64_t"},
		{"effect_hash_mask", "int"},
		{"effect_noise_tex", "int"},
		{"effect_time", "float"},
		{"effect_min", "vec3"},
		{"effect_max", "vec3"},
	}

	function surface_conditions.IsFieldActive()
		return brick_count > 0 and hash_table ~= nil and noise_texture ~= nil
	end

	function surface_conditions.WriteBlock(self, block)
		if not surface_conditions.IsFieldActive() then
			block.effect_hash_mask = -1
			return block
		end

		block.effect_hash = hash_table.buffer:GetDeviceAddress()
		block.effect_bricks = brick_table.buffer:GetDeviceAddress()
		block.effect_hash_mask = hash_size - 1
		block.effect_noise_tex = self:GetTextureIndex(noise_texture)
		block.effect_time = surface_conditions.GetTime()
		block.effect_min[0], block.effect_min[1], block.effect_min[2] = bounds_min.x - CELL, bounds_min.y - CELL, bounds_min.z - CELL
		block.effect_max[0], block.effect_max[1], block.effect_max[2] = bounds_max.x + CELL, bounds_max.y + CELL, bounds_max.z + CELL
		return block
	end

	function surface_conditions.GetBrickCount()
		return brick_count
	end
end

function surface_conditions.GetTime()
	return system.GetElapsedTime() % 3600
end

function surface_conditions.GetBlackbodyGLSL()
	return [[
		#ifndef GOLUWA_EFFECT_BLACKBODY
		#define GOLUWA_EFFECT_BLACKBODY
		vec3 effect_blackbody(float kelvin) {
			float t = kelvin / 100.0;
			vec3 c;
			c.r = t <= 66.0 ? 1.0 : clamp(1.29293618606 * pow(t - 60.0, -0.1332047592), 0.0, 1.0);
			c.g = t <= 66.0 ? clamp(0.39008157876 * log(t) - 0.63184144378, 0.0, 1.0) : clamp(1.12989086089 * pow(t - 60.0, -0.0755148492), 0.0, 1.0);
			c.b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : clamp(0.54320678911 * log(t - 10.0) - 1.19625408914, 0.0, 1.0));
			c = pow(c, vec3(2.2));
			return c / max(dot(c, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
		}
		#endif
	]]
end

function surface_conditions.GetCommonGLSL(block_name)
	local out = {}

	for _, kind in ipairs(kinds) do
		if kind.glsl and kind.glsl.common then out[#out + 1] = kind.glsl.common end
	end

	local glsl = (
		glsl_common.GetHashGLSL() .. glsl_common.GetOctahedralGLSL() .. surface_conditions.GetBlackbodyGLSL() .. [[
		#ifndef GOLUWA_SURFACE_EFFECTS_COMMON
		#define GOLUWA_SURFACE_EFFECTS_COMMON
		vec4 effect_noise(vec3 P, vec3 N, float scale) {
			vec3 w = N * N;
			w *= w;
			w /= dot(w, vec3(1.0));
			return texture(TEXTURE(BLOCK.effect_noise_tex), P.zy * scale) * w.x + texture(TEXTURE(BLOCK.effect_noise_tex), P.xz * scale) * w.y + texture(TEXTURE(BLOCK.effect_noise_tex), P.xy * scale) * w.z;
		}
		]] .. table.concat(out, "\n") .. [[
		#endif
	]]
	):gsub("BLOCK%.", block_name .. ".")
	return glsl
end

function surface_conditions.GetGLSL(block_name)
	local members = {}
	local defaults = {}
	local unpack_lines = {}
	local weather_snippets = {}
	local surface_snippets = {}

	for i, name in ipairs(channels) do
		local component = ("xyzw"):sub((i - 1) % 4 + 1, (i - 1) % 4 + 1)
		members[#members + 1] = "float " .. name .. ";"
		defaults[#defaults + 1] = "e." .. name .. " = 0.0;"
		unpack_lines[#unpack_lines + 1] = string.format("e.%s = %s.%s;", name, i <= 4 and "a" or "b", component)
	end

	for _, kind in ipairs(kinds) do
		if kind.glsl and kind.glsl.weather then
			weather_snippets[#weather_snippets + 1] = "{\n" .. kind.glsl.weather .. "\n}"
		end

		if kind.glsl and kind.glsl.surface then
			surface_snippets[#surface_snippets + 1] = "{\n" .. kind.glsl.surface .. "\n}"
		end
	end

	local glsl = (
		surface_conditions.GetCommonGLSL(block_name) .. [[
		]] .. shader_features.GetDefaultGLSL("conditions") .. [[
		layout(buffer_reference, scalar) readonly buffer SurfaceConditionHash { ivec4 slots[]; };
		layout(buffer_reference, scalar) readonly buffer SurfaceConditionBricks { uvec3 cells[]; };

		struct SurfaceConditions {
			]] .. table.concat(members, "\n") .. [[
			vec3 P;
			vec3 N;
		};

		int surface_condition_brick(ivec3 b) {
			uint mask = uint(BLOCK.effect_hash_mask);
			uint h = (uint(b.x) * 73856093u) ^ (uint(b.y) * 19349663u) ^ (uint(b.z) * 83492791u);

			for (uint i = 0u; i < 64u; i++) {
				ivec4 slot = SurfaceConditionHash(BLOCK.effect_hash).slots[(h + i) & mask];

				if (slot.w == 0) return -1;

				if (slot.xyz == b) return slot.w - 1;
			}

			return -1;
		}

		bool sample_surface_condition_field(vec3 P, vec3 N, inout SurfaceConditions e) {
			vec3 T = normalize(cross(N, abs(N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
			vec4 warp = effect_noise(P, N, ]] .. string.format("%.4f", surface_conditions.WARP_SCALE) .. [[);
			P += (T * (warp.r - 0.5) + cross(N, T) * (warp.g - 0.5)) * ]] .. string.format("%.4f", surface_conditions.WARP_DISTANCE) .. [[;
			vec3 g = P * ]] .. string.format("%.6f", INV_CELL) .. [[ - 0.5;
			ivec3 base = ivec3(floor(g));
			vec3 f = g - vec3(base);
			vec4 a = vec4(0.0);
			vec4 b = vec4(0.0);
			float weight_sum = 0.0;
			ivec3 cached_coord = ivec3(2147483647);
			int brick = -1;

			for (int corner = 0; corner < 8; corner++) {
				ivec3 o = ivec3(corner & 1, (corner >> 1) & 1, corner >> 2);
				ivec3 c = base + o;
				ivec3 brick_coord = c >> 2;

				if (brick_coord != cached_coord) {
					cached_coord = brick_coord;
					brick = surface_condition_brick(brick_coord);
				}

				if (brick < 0) continue;

				ivec3 l = c & 3;
				uvec3 cell = SurfaceConditionBricks(BLOCK.effect_bricks).cells[brick * 64 + l.x + l.y * 4 + l.z * 16];

				if ((cell.z & 1u) == 0u) continue;

				vec3 t = mix(1.0 - f, f, vec3(o));
				float w = t.x * t.y * t.z;

				if ((cell.z & 2u) != 0u) {
					vec2 octa = vec2(float((cell.z >> 2u) & 32767u), float(cell.z >> 17u)) / 32767.0 * 2.0 - 1.0;
					w *= smoothstep(-0.35, 0.1, dot(N, oct_decode(octa)));
				}

				a += unpackUnorm4x8(cell.x) * w;
				b += unpackUnorm4x8(cell.y) * w;
				weight_sum += w;
			}

			if (weight_sum < 1e-3) return false;

			float coverage = smoothstep(0.03, 0.25, weight_sum) / weight_sum;
			a *= coverage;
			b *= coverage;
			]] .. table.concat(unpack_lines, "\n") .. [[
			return true;
		}

		bool sample_surface_conditions(vec3 P, vec3 N, float dynamic, vec3 noise_P, vec3 noise_N, out SurfaceConditions e) {
			]] .. table.concat(defaults, "\n") .. [[
			e.P = noise_P;
			e.N = normalize(noise_N);
			bool found = false;

			if (SURFACE_CONDITIONS != 0 && dynamic < 0.5 && BLOCK.effect_hash_mask >= 0 && all(greaterThanEqual(P, BLOCK.effect_min)) && all(lessThanEqual(P, BLOCK.effect_max))) {
				found = sample_surface_condition_field(P, N, e);
			}

			return found;
		}

		void weather_surface_conditions(SurfaceConditions e, inout SurfaceWeather w) {
			]] .. table.concat(weather_snippets, "\n") .. [[
		}

		float apply_surface_conditions(inout Surface s, inout SurfaceWeather w, SurfaceConditions e) {
			float consumed = 0.0;
			]] .. table.concat(surface_snippets, "\n") .. [[
			return consumed;
		}
	]]
	):gsub("BLOCK%.", block_name .. ".")
	return glsl
end

do
	local slots = {}
	local clusters = {}
	local cluster_list = {}

	local function create_slot(i, x, y, z)
		local entity = Entity.New{
			Name = "surface_condition_light",
			transform = {Position = Vec3(x, y, z)},
			light_point = {Lumen = 0},
		}
		entity:SetTransient(true)
		local slot = {
			entity = entity,
			x = x,
			y = y,
			z = z,
			lumen = 0,
			target_x = x,
			target_y = y,
			target_z = z,
			target_lumen = 0,
			color = false,
			flicker = 0,
			phase = math.random() * 100,
			height = 0,
		}
		slots[i] = slot
		return slot
	end

	local function remove_slot(i)
		slots[i].entity:Remove()
		slots[i] = nil
	end

	local function by_score(a, b)
		return a.score > b.score
	end

	local used = {}

	function update_light_targets()
		table.clear(clusters)
		table.clear(cluster_list)
		table.clear(used)
		local size = surface_conditions.LIGHT_CLUSTER_SIZE
		local camera = render3d.GetCamera():GetPosition()

		for _, kind in ipairs(kinds) do
			local light = kind.light

			if light then
				for i = 1, #active do
					local cell = active[i]
					local power = kind.LightPower(cell)

					if power > 0 then
						local key = cell_key(
							math.floor(cell.px / size),
							math.floor(cell.py / size),
							math.floor(cell.pz / size) * 4 + kind.index
						)
						local cluster = clusters[key]

						if not cluster then
							cluster = {
								x = 0,
								y = 0,
								z = 0,
								power = 0,
								kind = kind,
								score = 0,
							}
							clusters[key] = cluster
							cluster_list[#cluster_list + 1] = cluster
						end

						cluster.x = cluster.x + cell.px * power
						cluster.y = cluster.y + (cell.py + cell.ny * 0.3 + light.height) * power
						cluster.z = cluster.z + cell.pz * power
						cluster.power = cluster.power + power
					end
				end
			end
		end

		for _, cluster in ipairs(cluster_list) do
			cluster.x, cluster.y, cluster.z = cluster.x / cluster.power, cluster.y / cluster.power, cluster.z / cluster.power
			local d2 = (cluster.x - camera.x) ^ 2 + (cluster.y - camera.y) ^ 2 + (cluster.z - camera.z) ^ 2
			cluster.score = cluster.power / (1 + d2 / 400)
		end

		table.sort(cluster_list, by_score)
		local jump = (size * 2) ^ 2

		for i = 1, math.min(#cluster_list, surface_conditions.LIGHT_COUNT) do
			local cluster = cluster_list[i]
			local best, best_d2

			for s, slot in pairs(slots) do
				if not used[s] then
					local d2 = (slot.x - cluster.x) ^ 2 + (slot.y - cluster.y) ^ 2 + (slot.z - cluster.z) ^ 2

					if not best_d2 or d2 < best_d2 then best, best_d2 = s, d2 end
				end
			end

			if not best or best_d2 > jump then
				for s = 1, surface_conditions.LIGHT_COUNT do
					if not slots[s] then
						best = s
						create_slot(s, cluster.x, cluster.y, cluster.z)

						break
					end
				end
			end

			used[best] = true
			local slot = slots[best]
			local light = cluster.kind.light

			if best_d2 and best_d2 > jump then
				slot.x, slot.y, slot.z = cluster.x, cluster.y, cluster.z
			end

			slot.target_x, slot.target_y, slot.target_z = cluster.x, cluster.y, cluster.z
			slot.target_lumen = cluster.power * light.lumen
			slot.flicker = light.flicker
			slot.height = light.height

			if slot.color ~= light.color then
				slot.color = light.color
				slot.entity.light_point:SetColor(light.color)
			end
		end

		for s, slot in pairs(slots) do
			if not used[s] then slot.target_lumen = 0 end
		end
	end

	function surface_conditions.UpdateLights(dt)
		local t = surface_conditions.GetTime()
		local follow = 1 - math.exp(-dt * 3)

		for i = 1, surface_conditions.LIGHT_COUNT do
			local slot = slots[i]

			if slot then
				slot.x = slot.x + (slot.target_x - slot.x) * follow
				slot.y = slot.y + (slot.target_y - slot.y) * follow
				slot.z = slot.z + (slot.target_z - slot.z) * follow
				slot.lumen = slot.lumen + (slot.target_lumen - slot.lumen) * follow

				if slot.lumen < 1 and slot.target_lumen == 0 then
					remove_slot(i)
				else
					local phase = slot.phase + t
					local flicker = 1 + slot.flicker * (
							math.sin(phase * 11.3) * 0.35 + math.sin(phase * 23.7 + 1.3) * 0.25 + math.sin(phase * 5.1 + 0.7) * 0.4
						)
					slot.entity.transform:SetPosition(Vec3(slot.x, slot.y, slot.z))
					slot.entity.light_point:SetLumen(slot.lumen * flicker)
				end
			end
		end
	end

	function surface_conditions.RemoveLights()
		for i = 1, surface_conditions.LIGHT_COUNT do
			if slots[i] then remove_slot(i) end
		end
	end

	function surface_conditions.GetLights()
		return slots
	end
end

do
	local accumulator = 0

	event.AddListener("Update", "surface_conditions", function(dt)
		if surface_conditions.HasContent() then
			accumulator = accumulator + dt
			local steps = 0

			while accumulator >= surface_conditions.TICK and steps < 2 do
				accumulator = accumulator - surface_conditions.TICK
				surface_conditions.Step(surface_conditions.TICK)
				steps = steps + 1
			end

			if accumulator > surface_conditions.TICK then accumulator = 0 end
		end
	end)

	local last_light_time = system.GetElapsedTime()

	event.AddListener(
		"PreRenderPass",
		"surface_conditions",
		function()
			local now = system.GetElapsedTime()
			surface_conditions.UpdateLights(now - last_light_time)
			last_light_time = now

			if not surface_conditions.HasContent() then return end

			surface_conditions.GetNoiseTexture()
			surface_conditions.FlushGPU(render.GetCommandBuffer())
			surface_conditions.UploadSites()
		end,
		{priority = 1}
	)
end

commands.Add("surface_condition=string,number[1.5],number[1]", function(kind, radius, amount)
	local hit = raycast.CastClosestFromCamera(render3d.GetCamera())

	if hit then
		surface_conditions.Apply(kind, hit.position, radius, amount, hit.normal)
	end
end)

commands.Add("surface_condition_clear", function()
	surface_conditions.Clear()
end)

return surface_conditions
