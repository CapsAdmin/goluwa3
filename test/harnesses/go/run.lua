-- GPU pass measurement + screenshot harness.
-- env: GO_MAP=esther|quarry|gmc  GO_MODES="base|r_a=1,r_b=2|base"  GO_FRAMES=120 GO_WARM=40 GO_TAG=name GO_EV=15
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local commands = import("goluwa/cli/commands.lua")
local scene_bvh = import("goluwa/render3d/scene_bvh.lua")
local scene_loading = import("goluwa/render3d/scene_loading.lua")
local pvars = import("goluwa/cli/pvars.lua")
local MAPS = {
	esther = {
		cmd = "map esther",
		pos = Vec3(49.017979, -15.184834, -16.257526),
		ang = Ang3(0.141371, 1.104045, 0),
		fov = 1.5707963267949,
		sun = Quat(-0.412015, 0.356625, 0.179392, 0.819073),
	},
	quarry = {
		cmd = "crymap IA/Quarry",
		pos = Vec3(1484.279419, 172.515839, -1118.615967),
		ang = Ang3(-0.491435, 1.164634, 0),
		fov = 1.5707963267949,
	},
	gmc = {
		cmd = "map gm_construct",
		pos = function()
			local raycast = import("goluwa/render3d/raycast.lua")
			local hit = raycast.CastClosest(Vec3(0, 60, 0), Vec3(0, -1, 0), 200)
			return Vec3(0, (hit and hit.position.y or 0) + 1.7, 0)
		end,
		ang = Ang3(-0.087, 0, 0),
		fov = 1.3,
	},
}
local map_name = os.getenv("GO_MAP") or "esther"
local map = MAPS[map_name]

if os.getenv("GO_VIEW") then
	local v = {}

	for n in os.getenv("GO_VIEW"):gmatch("[^,]+") do
		v[#v + 1] = tonumber(n)
	end

	map = table.copy(map)
	map.pos = Vec3(v[1], v[2], v[3])
	map.ang = Ang3(v[4], v[5], v[6])
	map.fov = v[7] or map.fov
	map.sun = nil

	if os.getenv("GO_SUN") then
		local q = {}

		for n in os.getenv("GO_SUN"):gmatch("[^,]+") do
			q[#q + 1] = tonumber(n)
		end

		map.sun = Quat(q[1], q[2], q[3], q[4])
	end
end
local FRAMES = tonumber(os.getenv("GO_FRAMES") or "120")
local WARM = tonumber(os.getenv("GO_WARM") or "40")
local TAG = os.getenv("GO_TAG") or "run"
local EV = tonumber(os.getenv("GO_EV") or "")
local SHOT = os.getenv("GO_SHOT") ~= "0"
local modes = {}

for spec in (os.getenv("GO_MODES") or "base"):gmatch("[^|]+") do
	local mode = {name = spec, set = {}}

	if spec ~= "base" then
		for kv in spec:gmatch("[^,]+") do
			local k, v = kv:match("^([%w_]+)=(.+)$")
			mode.set[#mode.set + 1] = {k, v}
		end
	end

	modes[#modes + 1] = mode
end

commands.RunString(map.cmd)
local ready_at, settled_at, view
event.AddListener("BVHSceneReady", "go_ready", function()
	ready_at = system.GetTime()
end)
local original = {}

local function apply(mode)
	_G.GO_MODE = 0

	for k, v in pairs(original) do
		pvars.GetObject(k):SetSession(v)
	end

	for _, kv in ipairs(mode.set) do
		if kv[1] == "go" then
			_G.GO_MODE = tonumber(kv[2])
			goto continue
		end

		local obj = pvars.GetObject(kv[1])

		if original[kv[1]] == nil then original[kv[1]] = obj:Get() end

		local value = kv[2]

		if obj:GetType() == "number" then
			value = tonumber(value)
		elseif obj:GetType() == "boolean" then
			value = value == "1" or value == "true"
		end

		obj:SetSession(value)
		::continue::
	end
end

local raw = select(2, debug.getupvalue(gpu_timing.GetRawMilliseconds, 1))
local last_time, good = system.GetTime(), 0
local HOLD = tonumber(os.getenv("GO_HOLD") or "400")
local sim_frame = 0
local mode_index, state, frame_in_mode = 1, "settle", 0
local previous, updates, sums, results = {}, {}, {}, {}
local mode_start

local function begin_mode()
	sim_frame = HOLD
	apply(modes[mode_index])
	state = "warm"
	frame_in_mode = 0
	previous, updates, sums = {}, {}, {}
end

local function finish_mode()
	local names = gpu_timing.GetScopeNames()
	local lines = {}

	for i = 1, #names do
		local name = names[i]

		if sums[name] then
			lines[#lines + 1] = {
				name = name,
				ms = sums[name] / FRAMES,
				per_update = sums[name] / updates[name],
				rate = updates[name] / FRAMES,
			}
		end
	end

	table.sort(lines, function(a, b)
		return a.ms > b.ms
	end)

	local mode = modes[mode_index]
	print(string.format("[GO] mode %d <%s>", mode_index, mode.name))

	for _, l in ipairs(lines) do
		print(string.format("[GO]   %-34s %8.3f ms/frame  %8.3f per update  %.2f upd/frame", l.name, l.ms, l.per_update, l.rate))
	end

	results[mode_index] = lines
end

event.AddListener("Update", "go_cycle", function()
	local now = system.GetTime()
	local dt = now - last_time
	last_time = now

	if dt < 0.15 then good = good + 1 else good = 0 end

	if state == "done" then return end

	if state == "settle" then
		if ready_at and not scene_loading.IsLoading() and good > 90 and now - ready_at > 4 then
			if map.sun then weather.SetSunRotation(map.sun) end

			view = View.New{
				Priority = 100,
				Position = type(map.pos) == "function" and map.pos() or map.pos,
				Rotation = Quat():SetAngles(map.ang),
				FOV = map.fov,
				ExposureLock = EV or false,
			}
			view:Activate()

			settled_at = now
			state = "hold"
			frame_in_mode = 0
		end

		return
	end

	if state == "hold" then
		frame_in_mode = frame_in_mode + 1
		system.SetElapsedTime(1000 + frame_in_mode / 60)

		if frame_in_mode >= HOLD then
			commands.RunString("r_exposure_info") print("[GO] lights", #import("goluwa/render3d/render3d.lua").GetLights())
			begin_mode()
			frame_in_mode = 0
			sim_frame = HOLD
		end

		return
	end

	sim_frame = sim_frame + 1
	frame_in_mode = frame_in_mode + 1
	system.SetElapsedTime(1000 + sim_frame / 60)

	if state == "warm" then
		if frame_in_mode >= WARM then
			state = "measure"
			frame_in_mode = 0
			previous, updates, sums = {}, {}, {}
		end

		return
	end

	if state == "measure" then
		local names = gpu_timing.GetScopeNames()

		for i = 1, #names do
			local name = names[i]
			local ms = gpu_timing.GetRawMilliseconds(name)

			if previous[name] ~= ms then
				previous[name] = ms
				updates[name] = (updates[name] or 0) + 1
				sums[name] = (sums[name] or 0) + ms
			end
		end

		if frame_in_mode >= FRAMES then
			finish_mode()

			if SHOT then
				state = "shot"
				local index = mode_index
				Screenshot(function(texture)
					print(texture:SaveWithoutAlpha("test/harnesses/go/out/" .. TAG .. "_" .. index .. ".png"))
					state = "next"
				end)
			else
				state = "next"
			end
		end

		return
	end

	if state == "next" then
		mode_index = mode_index + 1

		if not modes[mode_index] then
			local wanted = {}

			for name in (os.getenv("GO_SCOPES") or "gpu_frame"):gmatch("[^,]+") do
				wanted[#wanted + 1] = name
			end

			local header = string.format("[GO] %-28s", "scope")

			for i, mode in ipairs(modes) do
				header = header .. string.format(" %9s", i .. ":" .. mode.name:sub(1, 7))
			end

			print(header)

			for _, name in ipairs(wanted) do
				local row = string.format("[GO] %-28s", name)

				for i = 1, #modes do
					local value = 0

					for _, l in ipairs(results[i]) do
						if l.name == name then value = l.ms end
					end

					row = row .. string.format(" %9.3f", value)
				end

				print(row)
			end

			print("[GO] done")
			state = "done"
			os.exit(0)

			return
		end

		begin_mode()
	end
end, {priority = 1000})
