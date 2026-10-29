local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")
local audio = import("goluwa/audio.lua")
local acoustics = import("goluwa/audio/acoustics.lua")
local event = import("goluwa/event.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local debug_draw = import("goluwa/debug_draw.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local FLOOR = -1.7
local WALL = 0.2
local DOOR_WIDTH = 1.2
local DOOR_HEIGHT = 2.2
local ROW_FRONT = {-6, -34, -54}
local ROW_GAP = 6
local LABEL_DISTANCE = 30
local MATERIALS = {
	concrete = {absorption = {0.01, 0.02, 0.02}, color = Color(0.55, 0.55, 0.55, 1)},
	plaster = {absorption = {0.10, 0.04, 0.05}, color = Color(0.86, 0.84, 0.79, 1)},
	brick = {absorption = {0.03, 0.04, 0.07}, color = Color(0.55, 0.3, 0.22, 1)},
	wood = {absorption = {0.15, 0.10, 0.07}, color = Color(0.5, 0.35, 0.2, 1)},
	carpet = {absorption = {0.05, 0.35, 0.65}, color = Color(0.45, 0.14, 0.14, 1)},
	cloth = {absorption = {0.15, 0.55, 0.70}, color = Color(0.16, 0.4, 0.45, 1)},
	upholstery = {absorption = {0.20, 0.60, 0.70}, color = Color(0.36, 0.22, 0.46, 1)},
	mattress = {absorption = {0.25, 0.65, 0.70}, color = Color(0.62, 0.66, 0.76, 1)},
	grass = {absorption = {0.11, 0.40, 0.60}, color = Color(0.26, 0.42, 0.16, 1)},
}
local FACES = {
	x0 = {axis = 1, side = 0, u = 2, v = 3},
	x1 = {axis = 1, side = 1, u = 2, v = 3},
	y0 = {axis = 2, side = 0, u = 1, v = 3},
	y1 = {axis = 2, side = 1, u = 1, v = 3},
	z0 = {axis = 3, side = 0, u = 1, v = 2},
	z1 = {axis = 3, side = 1, u = 1, v = 2},
}
local FACE_ORDER = {"x0", "x1", "y0", "y1", "z0", "z1"}
local ROOMS = {
	{row = 1, name = "small concrete", size = Vec3(4, 2.7, 5), material = "concrete"},
	{row = 1, name = "small plaster", size = Vec3(4, 2.7, 5), material = "plaster"},
	{
		row = 1,
		name = "small furnished",
		size = Vec3(4, 2.7, 5),
		material = "plaster",
		faces = {y0 = {material = "carpet"}},
		furniture = {count = 6, soft = 0.4},
	},
	{
		row = 1,
		name = "small curtained",
		size = Vec3(4, 2.7, 5),
		material = "cloth",
		faces = {y0 = {material = "carpet"}, y1 = {material = "plaster"}},
	},
	{row = 1, name = "mattress booth", size = Vec3(2, 2.3, 2), material = "mattress"},
	{
		row = 1,
		name = "corridor closed",
		size = Vec3(2, 2.7, 20),
		material = "concrete",
	},
	{
		row = 1,
		name = "corridor open ends",
		size = Vec3(2, 2.7, 20),
		material = "concrete",
		faces = {z0 = {open = true}, z1 = {open = true}},
	},
	{
		row = 2,
		name = "medium concrete",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
	},
	{
		row = 2,
		name = "medium window 10%",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
		faces = {x1 = {window = 0.1}},
	},
	{
		row = 2,
		name = "medium wall 50% open",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
		faces = {x1 = {open = 0.5}},
	},
	{
		row = 2,
		name = "medium wall open",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
		faces = {x1 = {open = true}},
	},
	{
		row = 2,
		name = "medium roof open",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
		faces = {y1 = {open = true}},
	},
	{
		row = 2,
		name = "medium 30 furniture",
		size = Vec3(10, 3.5, 12),
		material = "concrete",
		furniture = {count = 30, soft = 0.3},
	},
	{
		row = 2,
		name = "medium curtained",
		size = Vec3(10, 3.5, 12),
		material = "cloth",
		faces = {y0 = {material = "carpet"}, y1 = {material = "plaster"}},
	},
	{
		row = 3,
		name = "large concrete",
		size = Vec3(25, 10, 30),
		material = "concrete",
	},
	{
		row = 3,
		name = "large 80 furniture",
		size = Vec3(25, 10, 30),
		material = "concrete",
		furniture = {count = 80, soft = 0.3},
	},
	{
		row = 3,
		name = "courtyard",
		size = Vec3(20, 10, 20),
		material = "brick",
		faces = {y1 = {open = true}, y0 = {material = "grass"}},
	},
}
local audio_rooms = _G.audio_rooms

if audio_rooms then
	event.RemoveListener("Update", "audio_rooms")
	event.RemoveListener("Draw2D", "audio_rooms")

	for _, ent in ipairs(audio_rooms.entities) do
		if ent:IsValid() then ent:Remove() end
	end
end

audio_rooms = {entities = {}, rooms = {}}
_G.audio_rooms = audio_rooms
local render_materials = {}

for name, info in pairs(MATERIALS) do
	local a = info.absorption
	render_materials[name] = shapes.Material{
		Color = info.color,
		Roughness = 0.9,
		Metallic = 0,
		AcousticAbsorption = Vec3(a[1], a[2], a[3]),
	}
end

local function get(v, axis)
	return axis == 1 and v.x or axis == 2 and v.y or v.z
end

local function add_box(name, min, max, material)
	local ent = shapes.Box{
		Name = name,
		Position = (min + max) * 0.5,
		Size = max - min,
		Material = render_materials[material],
		RigidBody = {MotionType = "static"},
	}
	audio_rooms.entities[#audio_rooms.entities + 1] = ent
	return ent
end

local function face_holes(room, face_name, w, h)
	local face = FACES[face_name]
	local spec = room.faces and room.faces[face_name] or {}

	if spec.open == true then return nil end

	if type(spec.open) == "number" then
		local f = spec.open

		if face.axis == 2 then
			local k = math.sqrt(f)
			return {w * (1 - k) / 2, h * (1 - k) / 2, w * (1 + k) / 2, h * (1 + k) / 2}
		elseif face.u == 2 then
			return {0, h * (1 - f) / 2, w, h * (1 + f) / 2}
		end

		return {w * (1 - f) / 2, 0, w * (1 + f) / 2, h}
	end

	if spec.window then
		local k = math.sqrt(spec.window)
		return {w * (1 - k) / 2, h * (1 - k) / 2, w * (1 + k) / 2, h * (1 + k) / 2}
	end

	if face_name == "z1" then
		local width = math.min(DOOR_WIDTH, w - 0.4)
		return {
			w / 2 - width / 2,
			0,
			w / 2 + width / 2,
			math.min(DOOR_HEIGHT, h - 0.2),
		}
	end

	return false
end

local function build_face(room, face_name)
	local face = FACES[face_name]
	local spec = room.faces and room.faces[face_name] or {}
	local material = spec.material or room.material
	local dims = {room.size.x, room.size.y, room.size.z}
	local w, h = dims[face.u], dims[face.v]
	local hole = face_holes(room, face_name, w, h)
	local area = w * h

	if hole == nil then return area, area, material end

	local pieces

	if hole then
		pieces = {
			{0, 0, hole[1], h},
			{hole[3], 0, w, h},
			{hole[1], 0, hole[3], hole[2]},
			{hole[1], hole[4], hole[3], h},
		}
	else
		pieces = {{0, 0, w, h}}
	end

	for _, piece in ipairs(pieces) do
		if piece[3] - piece[1] > 0.001 and piece[4] - piece[2] > 0.001 then
			local min, max = {0, 0, 0}, {0, 0, 0}
			local coordinate = face.side == 1 and dims[face.axis] or 0
			min[face.axis] = face.side == 1 and coordinate or coordinate - WALL
			max[face.axis] = face.side == 1 and coordinate + WALL or coordinate
			min[face.u] = piece[1] - (piece[1] <= 0 and WALL or 0)
			max[face.u] = piece[3] + (piece[3] >= w and WALL or 0)
			min[face.v] = piece[2] - (piece[2] <= 0 and WALL or 0)
			max[face.v] = piece[4] + (piece[4] >= h and WALL or 0)
			add_box(
				room.name .. " " .. face_name,
				room.origin + Vec3(min[1], min[2], min[3]),
				room.origin + Vec3(max[1], max[2], max[3]),
				material
			)
		end
	end

	return area, hole and (hole[3] - hole[1]) * (hole[4] - hole[2]) or 0, material
end

local function build_furniture(room)
	local furniture = room.furniture
	local seed = 1

	local function random()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end

	local size = room.size
	local keep = {Vec3(size.x / 2, 0, size.z), Vec3(size.x / 2, 0, size.z / 2)}
	local tries = 0
	room.boxes = {}

	while #room.boxes < furniture.count and tries < furniture.count * 50 do
		tries = tries + 1
		local sx = 0.4 + random() * 1.4
		local sz = 0.4 + random() * 1.4
		local sy = random() < 0.25 and 1.6 + random() * 0.6 or 0.4 + random() * 0.6
		local x = random() * (size.x - sx)
		local z = random() * (size.z - sz)
		local ok = sy < size.y - 0.2

		for _, p in ipairs(keep) do
			local cx = math.clamp(p.x, x, x + sx)
			local cz = math.clamp(p.z, z, z + sz)

			if (cx - p.x) ^ 2 + (cz - p.z) ^ 2 < 1.5 then ok = false end
		end

		if ok then
			local material = random() < furniture.soft and "upholstery" or "wood"
			add_box(
				room.name .. " furniture",
				room.origin + Vec3(x, 0, z),
				room.origin + Vec3(x + sx, sy, z + sz),
				material
			)
			room.boxes[#room.boxes + 1] = {
				absorption = MATERIALS[material].absorption,
				area = 2 * (sx * sy + sx * sz + sy * sz) - sx * sz,
				volume = sx * sy * sz,
			}
		end
	end
end

local function eyring(room)
	local size = room.size
	local volume = size.x * size.y * size.z
	local area = 0
	local absorbed = {0, 0, 0}

	for _, face in ipairs(room.face_areas) do
		area = area + face.area

		for b = 1, 3 do
			absorbed[b] = absorbed[b] + (
					face.area - face.open
				) * MATERIALS[face.material].absorption[b] + face.open
		end
	end

	for _, box in ipairs(room.boxes or {}) do
		volume = volume - box.volume
		area = area + box.area

		for b = 1, 3 do
			absorbed[b] = absorbed[b] + box.area * box.absorption[b]
		end
	end

	local t60 = {}

	for b = 1, 3 do
		t60[b] = 0.161 * volume / (
				-area * math.log(1 - absorbed[b] / area) + 4 * acoustics.AirEnergyPerMeter(b) * volume
			)
	end

	return t60, volume
end

local ground = shapes.Box{
	Name = "audio_rooms ground",
	Position = Vec3(0, FLOOR - 0.51, -40),
	Size = Vec3(160, 1, 140),
	Material = render_materials.grass,
	RigidBody = {MotionType = "static"},
}
audio_rooms.entities[#audio_rooms.entities + 1] = ground

for row, front in ipairs(ROW_FRONT) do
	local width = -ROW_GAP

	for _, room in ipairs(ROOMS) do
		if room.row == row then width = width + room.size.x + ROW_GAP end
	end

	local x = -width / 2

	for _, room in ipairs(ROOMS) do
		if room.row == row then
			room.origin = Vec3(x, FLOOR, front - room.size.z)
			room.face_areas = {}

			for _, face_name in ipairs(FACE_ORDER) do
				local area, open, material = build_face(room, face_name)
				room.face_areas[#room.face_areas + 1] = {area = area, open = open, material = material}
			end

			if room.furniture then build_furniture(room) end

			room.eyring, room.volume = eyring(room)
			room.door = room.origin + Vec3(room.size.x / 2, 0, room.size.z)
			audio_rooms.rooms[#audio_rooms.rooms + 1] = room
			x = x + room.size.x + ROW_GAP
		end
	end
end

function audio_rooms.Goto(name)
	for _, room in ipairs(audio_rooms.rooms) do
		if room.name:find(name, 1, true) then
			_G.PLAYER_RIG.character_movement:TeleportTo(room.origin + Vec3(room.size.x / 2, 0.05, room.size.z / 2))
			return room
		end
	end
end

local function find_room(position)
	for _, room in ipairs(audio_rooms.rooms) do
		local local_position = position - room.origin

		if
			local_position.x >= 0 and
			local_position.x <= room.size.x and
			local_position.y >= 0 and
			local_position.y <= room.size.y + 1 and
			local_position.z >= 0 and
			local_position.z <= room.size.z
		then
			return room
		end
	end
end

event.AddListener("Update", "audio_rooms", function()
	local listener = audio.GetListenerPosition()

	if find_room(listener) then return end

	for _, room in ipairs(audio_rooms.rooms) do
		if (room.door - listener):GetLength() < LABEL_DISTANCE then
			debug_draw.DrawText{
				id = "audio_rooms " .. room.name,
				position = room.door + Vec3(0, math.min(DOOR_HEIGHT, room.size.y) + 0.4, 0.3),
				lines = {
					room.name,
					string.format("Eyring T60 %.2f s", room.eyring[2]),
				},
				time = 0.2,
				padding = 6,
				line_gap = 2,
				background_alpha = 0.66,
				title_color = Color(0.7, 0.9, 1, 1),
				text_color = Color(0.9, 0.9, 0.94, 1),
			}
		end
	end
end)

event.AddListener("Draw2D", "audio_rooms", function()
	local room = find_room(audio.GetListenerPosition())
	local lines = {}

	if room then
		local materials = {room.material}

		for face_name, spec in pairs(room.faces or {}) do
			if spec.material then
				materials[#materials + 1] = face_name .. " " .. spec.material
			end

			if spec.open then
				materials[#materials + 1] = face_name .. (
						spec.open == true and
						" open" or
						string.format(" %.0f%% open", spec.open * 100)
					)
			end

			if spec.window then
				materials[#materials + 1] = string.format("%s %.0f%% window", face_name, spec.window * 100)
			end
		end

		if room.boxes then
			materials[#materials + 1] = #room.boxes .. " furniture"
		end

		lines[#lines + 1] = room.name
		lines[#lines + 1] = string.format(
			"%g x %g x %g m, %.0f m3, %s",
			room.size.x,
			room.size.y,
			room.size.z,
			room.volume,
			table.concat(materials, ", ")
		)
		lines[#lines + 1] = string.format(
			"Eyring T60   %.2f / %.2f / %.2f s",
			room.eyring[1],
			room.eyring[2],
			room.eyring[3]
		)
	else
		lines[#lines + 1] = "outside, walk into a room"
	end

	local tracer = audio.acoustics

	if tracer then
		local profile = tracer.profile
		local bus = audio.state.buses[0]
		lines[#lines + 1] = string.format(
			"traced T60   %.2f / %.2f / %.2f s (bus %.2f / %.2f / %.2f s)",
			profile.t60[1],
			profile.t60[2],
			profile.t60[3],
			bus.t60[0],
			bus.t60[1],
			bus.t60[2]
		)
		lines[#lines + 1] = string.format(
			"escaping %.0f%%, mean free path %.1f m",
			profile.openness * 100,
			profile.mean_free_path
		)
	else
		lines[#lines + 1] = "acoustics are off (audio_acoustics)"
	end

	lines[#lines + 1] = "clap and boom: Sound test weapon (slot 9), audio_rooms.Goto(name) teleports"
	local width = render2d.GetSize()
	debug_draw.DrawTextBlock(
		lines,
		width - 460,
		16,
		{
			padding = 8,
			line_gap = 3,
			background_alpha = 0.7,
			title_color = Color(0.7, 0.9, 1, 1),
			text_color = Color(0.9, 0.9, 0.94, 1),
		}
	)
end)

logn(
	"audio_rooms: ",
	#audio_rooms.rooms,
	" rooms with ",
	#audio_rooms.entities,
	" boxes"
)
