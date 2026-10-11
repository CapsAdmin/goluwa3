local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Shot = import("goluwa/render3d/shot.lua")
import("goluwa/render3d/clouds.lua").SetEnabled(false)
local scene = import("test/harnesses/alpha_scene.lua")
local CAM_H = tonumber(os.getenv("CAM_H") or "12")
local FOV = tonumber(os.getenv("FOV") or "90")
local EV0 = tonumber(os.getenv("EV") or "17")
local out = os.getenv("OUT") or "tmp/alpha_shot.png"
local CAM_X = 6
local steps = {}

for e = -4, 4 do
	steps[#steps + 1] = e * 0.75
end

local samples = {}

local function sample(texture, wx, wz)
	local size = texture:GetSize()
	local f = (size.y / 2) / math.tan(math.rad(FOV) / 2)
	local px = size.x / 2 + (wx - CAM_X) / CAM_H * f
	local py = size.y / 2 + wz / CAM_H * f
	local r, g, b, n = 0, 0, 0, 0
	local win = tonumber(os.getenv("WIN") or "14")

	for dy = -win, win, 2 do
		for dx = -win, win, 2 do
			local pr, pg, pb = texture:GetPixel(math.floor(px + dx), math.floor(py + dy))
			r, g, b, n = r + pr, g + pg, b + pb, n + 1
		end
	end

	return {r / n, g / n, b / n}
end

local function invert(curve, value)
	if value <= curve[1][1] then return curve[1][2] end

	for i = 2, #curve do
		local a, b = curve[i - 1], curve[i]

		if value <= b[1] then
			local t = (value - a[1]) / math.max(b[1] - a[1], 1e-6)
			return a[2] + (b[2] - a[2]) * t
		end
	end

	return curve[#curve][2]
end

local function finish()
	local curves = {{}, {}, {}}

	for i, ev in ipairs(steps) do
		for c = 1, 3 do
			curves[c][#curves[c] + 1] = {samples[i].lit[c], 2 ^ -ev}
		end
	end

	for c = 1, 3 do
		table.sort(curves[c], function(a, b)
			return a[1] < b[1]
		end)
	end

	local base

	for i, ev in ipairs(steps) do
		if ev == 0 then base = samples[i] end
	end

	local function linear(rgb)
		return {invert(curves[1], rgb[1]), invert(curves[2], rgb[2]), invert(curves[3], rgb[3])}
	end

	local lit = linear(base.lit)
	local opaque = linear(base.panels[1])
	print(
		string.format(
			"lit floor %.2f %.2f %.2f, opaque shadow %.3f of lit",
			lit[1],
			lit[2],
			lit[3],
			(opaque[1] + opaque[2] + opaque[3]) / (lit[1] + lit[2] + lit[3])
		)
	)

	for i, p in ipairs(scene.panels) do
		local l = linear(base.panels[i])
		local lum = 0.2126 * l[1] + 0.7152 * l[2] + 0.0722 * l[3]
		local lit_lum = 0.2126 * lit[1] + 0.7152 * lit[2] + 0.0722 * lit[3]
		local op_lum = 0.2126 * opaque[1] + 0.7152 * opaque[2] + 0.0722 * opaque[3]
		print(
			string.format(
				"%-16s sun passed %5.2f (r %.2f g %.2f b %.2f)  expected %4.2f   shadow/lit %.2f",
				p.name,
				(lum - op_lum) / (lit_lum - op_lum),
				(l[1] - opaque[1]) / (lit[1] - opaque[1]),
				(l[2] - opaque[2]) / (lit[2] - opaque[2]),
				(l[3] - opaque[3]) / (lit[3] - opaque[3]),
				p.expect,
				lum / lit_lum
			)
		)
	end

	system.ShutDown(0)
end

local function capture()
	local views = {}

	for i, ev in ipairs(steps) do
		views[i] = {
			Position = Vec3(CAM_X, CAM_H, 0),
			Rotation = QuatDeg3(-90, 0, 0),
			FOV = math.rad(FOV),
			ExposureLock = EV0 + ev,
			LocalExposure = 0,
		}
	end

	Shot.Sequence(
		views,
		function(texture, info, i)
			if steps[i] == 0 then print(texture:SaveWithoutAlpha(out)) end

			local shift_x = scene.height * scene.sun.x / scene.sun.y
			local shift_z = scene.height * scene.sun.z / scene.sun.y
			local s = {lit = sample(texture, 6, 0), panels = {}}

			for j, p in ipairs(scene.panels) do
				s.panels[j] = sample(texture, p.x - shift_x, p.z - shift_z)
			end

			samples[i] = s
		end,
		{settle = 2, settle_frames = 6},
		finish
	)
end

if os.getenv("TOGGLE") then
	local n = 0

	event.AddListener("Update", "alpha_toggle", function()
		n = n + 1

		if n == 90 then
			scene.Toggle()
			capture()
			return false
		end
	end)
else
	capture()
end
