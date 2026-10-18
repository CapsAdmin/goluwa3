local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local commands = import("goluwa/cli/commands.lua")
commands.RunString("crymap IA/Quarry")
local raw = select(2, debug.getupvalue(gpu_timing.GetRawMilliseconds, 1))
local WAIT = tonumber(os.getenv("QP_WAIT") or "15")
local FRAMES = tonumber(os.getenv("QP_FRAMES") or "60")
local WARM = tonumber(os.getenv("QP_WARM") or "30")
local ROUNDS = tonumber(os.getenv("QP_ROUNDS") or "2")
local SCOPES = {}

for name in (
	os.getenv("QP_SCOPES") or
	"gpu_frame,ddgi_shade,ddgi_resolve,gbuffer"
):gmatch("[^,]+") do
	SCOPES[#SCOPES + 1] = name
end

local modes = {}

for m in (os.getenv("QP_MODES") or "0"):gmatch("[^,]+") do
	modes[#modes + 1] = tonumber(m)
end

local schedule = {}

for r = 1, ROUNDS do
	for _, m in ipairs(modes) do
		if m ~= 0 then schedule[#schedule + 1] = 0 end

		schedule[#schedule + 1] = m
	end
end

local ready_at, settled_at, view

event.AddListener("RTSceneReady", "qp_ready", function()
	ready_at = system.GetTime()
end)

local start, last, good = system.GetTime(), system.GetTime(), 0
local idx, frame_in_mode = 1, 0
local acc = {}
local results = {}
local cam_pos = Vec3(1484.279419, 172.515839, -1118.615967)
local ddgi = import("goluwa/render3d/ddgi.lua")
local INTERVALS = {[0] = {1, 1, 1, 1}, [1] = {1, 2, 4, 8}, [2] = {1, 1, 2, 4}, [3] = {1, 2, 4, 4}}

local function apply(mode)
	local t = INTERVALS[mode]

	if t then for i = 1, 4 do
		ddgi.UPDATE_INTERVALS[i] = t[i]
	end end
end

_G.QP_MODE = schedule[1]
apply(schedule[1])

event.AddListener("Update", "qp_cycle", function()
	local now = system.GetTime()
	local fdt = now - last
	last = now

	if fdt < 0.1 then good = good + 1 else good = 0 end

	if not settled_at then
		if ready_at and good > 60 then
			settled_at = now
			view = View.New{
				Priority = 100,
				Position = cam_pos,
				Rotation = Quat():SetAngles(Ang3(-0.491435, 1.164634, 0)),
				FOV = 1.5707963267949,
			}
			view:Activate()
			weather.SetSunRotation(Quat(-0.319946, -0.058354, -0.019748, 0.945431))
		end

		return
	end

	if now - settled_at < WAIT then return end

	frame_in_mode = frame_in_mode + 1

	if frame_in_mode > WARM then
		for _, k in ipairs(SCOPES) do
			acc[k] = (acc[k] or 0) + (raw[k] or 0)
		end
	end

	if frame_in_mode >= WARM + FRAMES then
		local m = schedule[idx]
		local row = results[m] or {}
		results[m] = row
		row[#row + 1] = {}

		for _, k in ipairs(SCOPES) do
			row[#row][k] = acc[k] / FRAMES
		end

		acc = {}
		frame_in_mode = 0
		idx = idx + 1

		if idx > #schedule then
			local order = {}

			for m2 in pairs(results) do
				order[#order + 1] = m2
			end

			table.sort(order)

			for _, m2 in ipairs(order) do
				local parts = {}

				for _, k in ipairs(SCOPES) do
					local vals = {}

					for _, r in ipairs(results[m2]) do
						vals[#vals + 1] = r[k]
					end

					table.sort(vals)
					parts[#parts + 1] = string.format("%s=%.2f (%.2f..%.2f)", k, vals[math.ceil(#vals / 2)], vals[1], vals[#vals])
				end

				print(string.format("RESULT mode %2d: %s", m2, table.concat(parts, "  ")))
			end

			print("RESULT scene_tris", import("goluwa/render3d/scene/meshes.lua").GetTriangleCount())
			os.exit(0)
		end

		_G.QP_MODE = schedule[idx]
		apply(schedule[idx])
	end
end)
