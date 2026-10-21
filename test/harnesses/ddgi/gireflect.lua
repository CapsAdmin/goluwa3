-- the gi_reflections example scene seen from the user reported views (leaks, fireflies), run through gireflect_run.sh
-- GIR_VIEW  1 fireflies room, 2 see through box room, 3 leaking room, 4 leaking spot (or a name: firefly, plane, leak, outside)
-- GIR_GI    1 (default) gi only view, 0 the lit frame
-- GIR_EV    locked EV100, default auto exposure when GIR_GI is 0 and 9 for the gi only view
-- GIR_WARM  frames to wait (default 600), GIR_FRAMES frames to save (default 1), GIR_GAP frames between saved frames (1), GIR_OUT output directory, GIR_PV "pvar=value ..."
-- GIR_STATIC stops the moving emitter and the spot mover of the scene
-- GIR_POS / GIR_ANG (radians) override the view, GIR_GPU seconds measures the gpu time of that view instead (GIR_TOP scopes printed, 9)
local pvars = import("goluwa/cli/pvars.lua")
local out_dir = os.getenv("GIR_OUT") or "tmp/gir/out"
local warm = tonumber(os.getenv("GIR_WARM") or "") or 600
local count = tonumber(os.getenv("GIR_FRAMES") or "") or 1
local gap = tonumber(os.getenv("GIR_GAP") or "") or 1
local gi_only = os.getenv("GIR_GI") ~= "0"
pvars.SetSession("r_aa", "none")
pvars.SetSession("r_motion_blur", false)
pvars.SetSession("ddgi_debug_gi", gi_only)

for k, v in (os.getenv("GIR_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
local VIEWS = {
	firefly = {Vec3(123.677032, 2.616801, -102.166054), Ang3(-0.085049, 2.258063, 0)},
	plane = {Vec3(-38.184971, 2.190831, -101.912392), Ang3(0.042859, 2.587931, 0)},
	leak = {Vec3(121.826492, 1.622665, -1.325743), Ang3(0.201959, 2.704012, 0)},
	outside = {Vec3(46.502457, 19.051132, 91.954460), Ang3(0.296207, -3.112422, 0)},
}
local ORDER = {"firefly", "plane", "leak", "outside"}
-- every room of the scene from a corner of its entrance, {position, target}
local ROOMS = {
	cornell = {Vec3(-40, 3.5, 5.5), Vec3(-40, 2.5, -2)},
	tunnel = {Vec3(0, 2, 6.5), Vec3(0, 1.5, -3)},
	stage = {Vec3(40, 3, 5.5), Vec3(40, 1.5, 0)},
	bleed = {Vec3(80, 3, 3.5), Vec3(80, 2, -2)},
	partition = {Vec3(122, 2.5, 3.5), Vec3(122, 1.5, -2)},
	partition_lit = {Vec3(118, 2.5, 3.5), Vec3(118, 1.5, -2)},
	hall = {Vec3(160, 2, 10), Vec3(160, 2, -8)},
	tower = {Vec3(200, 2.5, 3.2), Vec3(200, 2, -2)},
	lamp = {Vec3(-43, 3, -56.5), Vec3(-40, 1, -61)},
	spot = {Vec3(-3, 3.5, -56.5), Vec3(2, 1.5, -62)},
	neighbours = {Vec3(37, 3, -57), Vec3(43, 1.5, -61)},
	corridor = {Vec3(66, 2, -60), Vec3(90, 1.5, -60)},
	desk = {Vec3(121, 3, -57), Vec3(127, 1, -62)},
	emitter = {Vec3(0, 3, -94.5), Vec3(0, 2.5, -103)},
	cornell_room = {Vec3(40, 3.2, -95.5), Vec3(40, 3, -103)},
	tiny_emitter = {Vec3(83.5, 3, -96), Vec3(78, 2, -103)},
	moving = {Vec3(164, 3, -95), Vec3(160, 2.5, -103)},
	spot_mover = {Vec3(203.5, 3, -95.5), Vec3(198, 2, -103)},
	cave = {Vec3(0, 14, 108), Vec3(0, 20, 100)},
}
local which = os.getenv("GIR_VIEW") or "1"
local view = VIEWS[ORDER[tonumber(which)] or which]
local pos, ang

if view then
	pos, ang = view[1], view[2]
else
	local room = assert(ROOMS[which], "unknown view " .. which)
	pos = room[1]
	local d = room[2] - room[1]
	ang = Ang3(math.atan2(d.y, math.sqrt(d.x * d.x + d.z * d.z)), math.atan2(-d.x, -d.z), 0)
end

if os.getenv("GIR_POS") then
	pos = Vec3(os.getenv("GIR_POS"):match("([^,]+),([^,]+),([^,]+)"))
	pos = Vec3(tonumber(pos.x), tonumber(pos.y), tonumber(pos.z))
end

if os.getenv("GIR_ANG") then
	local a, b, c = os.getenv("GIR_ANG"):match("([^,]+),([^,]+),([^,]+)")
	ang = Ang3(tonumber(a), tonumber(b), tonumber(c))
end

if os.getenv("GIR_LUA") then assert(loadstring(os.getenv("GIR_LUA")))() end
import(os.getenv("GIR_SCENE") or "addons/examples/lua/examples/render3d/gi_reflections.lua")
weather.SetSunRotation(Quat(-0.480592, 0.157274, -0.157274, 0.848269))

if os.getenv("GIR_STATIC") then
	Event.RemoveListener("Update", "gi_reflections_moving_emitter")
	Event.RemoveListener("Update", "gi_reflections_spot_mover")
	weather.SetWindTimeScale(0)
end

if os.getenv("GIR_NO_CLOUDS") then weather.SetCloudLayers({}) end

View.New{
	Priority = 100,
	HideAvatars = true,
	Position = pos,
	Rotation = Quat():SetAngles(ang),
	FOV = 1.5707963267949,
	ExposureLock = tonumber(os.getenv("GIR_EV") or "") or (gi_only and 9 or nil),
}:Activate()
os.execute("mkdir -p " .. out_dir)
local frame = 0
local saved = 0
local trace_frames = tonumber(os.getenv("GIR_TRACE") or "")

-- GIR_TRACE frames: prints the mean of the gi texture every GIR_GAP (20) frames, to see slow drifts (a * marks the sun change fast mode)
if trace_frames then
	local ddgi = import("goluwa/render3d/ddgi.lua")
	local values = {}
	local last_count, last_sizes
	Event.AddListener("Update", "gir_trace", function()
		frame = frame + 1
		local state = ddgi.GetFrameState()
		local sizes = {}

		for i = 1, state.cascade_count do
			local c = state.cascades[i]
			sizes[#sizes + 1] = string.format("%dx%dx%d@%d,%d,%d", c.size.x, c.size.y, c.size.z, c.x, c.y, c.z)
		end

		sizes = table.concat(sizes, " ")

		if bit.band(state.reset_mask, bit.lshift(1, state.cascade_count) - 1) ~= 0 or state.cascade_count ~= last_count or (last_sizes and sizes ~= last_sizes) then
			print(string.format("TRACE event frame %d reset_mask %x count %d cascades %s", frame, state.reset_mask, state.cascade_count, sizes))
		end

		last_count, last_sizes = state.cascade_count, sizes

		if frame % (gap == 1 and 20 or gap) == 0 then
			local downloaded = ddgi.GetScreenTexture():Download()
			local sum, count = 0, 0

			for y = 0, downloaded.height - 1, 8 do
				for x = 0, downloaded.width - 1, 8 do
					local r, g, b = downloaded:GetPixelFloat(x, y)
					sum = sum + (r + g + b) / 3
					count = count + 1
				end
			end

			local state = ddgi.GetFrameState()
			values[#values + 1] = string.format("%.1f%s", sum / count, (state.sun_fast_until or 0) > state.frame and "*" or "")
		end

		if frame >= trace_frames then
			print("TRACE " .. table.concat(values, " "))
			System.ShutDown(0)
		end
	end)

	return
end

local gpu_seconds = tonumber(os.getenv("GIR_GPU") or "")
local gpu_start

if gpu_seconds then
	local gpu_timing = import("goluwa/render/gpu_timing.lua")
	local started
	Event.AddListener("Update", "gir_gpu", function()
		frame = frame + 1

		if frame == warm then
			gpu_timing.BeginCapture()
			started = System.GetTime()
		end

		if started and System.GetTime() - started > gpu_seconds then
			local r = gpu_timing.EndCapture()
			print(string.format("GPU frame %.2f ms (%d frames)", r.frame_ms, r.frames))

			for i = 1, math.min(#r.groups, 6) do
				print(string.format("GPU group %-22s %6.2f ms %5.1f%%", r.groups[i].label, r.groups[i].ms, r.groups[i].share * 100))
			end

			for i = 1, math.min(#r.scopes, tonumber(os.getenv("GIR_TOP") or "") or 9) do
				local e = r.scopes[i]
				local info = {}

				for k, v in pairs(e.info or {}) do
					info[#info + 1] = k .. "=" .. (v == math.floor(v) and string.format("%d", v) or string.format("%.2f", v))
				end

				table.sort(info)
				print(string.format("GPU %-30s %6.2f ms %5.1f%%  %s", e.name, e.ms, e.share * 100, table.concat(info, " ")))
			end

			System.ShutDown(0)
		end
	end)

	return
end

Event.AddListener("Update", "gir", function()
	frame = frame + 1

	if frame > warm and (frame - warm) % gap == 0 and saved < count then
		local index = saved
		saved = saved + 1
		Screenshot(function(texture)
			texture:SaveWithoutAlpha(string.format("%s/f%03d.png", out_dir, index))

			if index == count - 1 then
				logf("[gir] saved %d frames to %s\n", count, out_dir)
				System.ShutDown(0)
			end
		end, {update_events = 0})
	end
end)
