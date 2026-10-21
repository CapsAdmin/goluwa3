-- the temporal noise of each probe of one cascade around a point: after PRB_WARM frames the irradiance of every probe (mean over its
-- texels) is read PRB_SAMPLES (24) times, PRB_GAP (2) frames apart, and the relative standard deviation of each is printed, the worst first.
-- env as probes.lua (PRB_POS, PRB_RADIUS cells, PRB_CASCADE, PRB_PV, GIR_SCENE), PRB_TOP (rows printed, 14)
local pvars = import("goluwa/cli/pvars.lua")
local Event = import("goluwa/event.lua")
local System = import("goluwa/system.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local ddgi = import("goluwa/render3d/ddgi.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local Ang3 = import("goluwa/structs/ang3.lua")
local View = import("goluwa/render3d/view.lua")
local weather = import("goluwa/render3d/weather.lua")
pvars.SetSession("r_aa", "none")

for k, v in (os.getenv("PRB_PV") or ""):gmatch("(%S+)=(%S+)") do
	local value = tonumber(v)

	if v == "true" then value = true elseif v == "false" then value = false elseif value == nil then value = v end

	pvars.SetSession(k, value)
end

local x, y, z = (os.getenv("PRB_POS") or "120,2,-100"):match("([^,]+),([^,]+),([^,]+)")
x, y, z = tonumber(x), tonumber(y), tonumber(z)
local radius = tonumber(os.getenv("PRB_RADIUS") or "") or 8
local cascade_index = tonumber(os.getenv("PRB_CASCADE") or "") or 0
local warm = tonumber(os.getenv("PRB_WARM") or "") or 1200
local samples = tonumber(os.getenv("PRB_SAMPLES") or "") or 24
local gap = tonumber(os.getenv("PRB_GAP") or "") or 2
if os.getenv("GIR_LUA") then assert(loadstring(os.getenv("GIR_LUA")))() end
import(os.getenv("GIR_SCENE") or "addons/examples/lua/examples/render3d/gi_reflections.lua")
Event.RemoveListener("Update", "gi_reflections_moving_emitter")
Event.RemoveListener("Update", "gi_reflections_spot_mover")
weather.SetSunRotation(Quat(-0.480592, 0.157274, -0.157274, 0.848269))
View.New{Priority = 100, HideAvatars = true, Position = Vec3(x, y, z), Rotation = Quat():SetAngles(Ang3(0, 0, 0)), FOV = 1.5, ExposureLock = 9}:Activate()
local frame = 0
local series = {}
local events

local function wrap(v, n) return ((v % n) + n) % n end

Event.AddListener("Update", "prb_noise", function()
	frame = frame + 1

	if frame < warm or (frame - warm) % gap ~= 0 then return end

	local state = ddgi.GetFrameState()
	local c = state.cascades[cascade_index + 1]
	local data = render3d.pipelines.ddgi_probe_data:GetFramebuffer(1):GetAttachment(1):Download()
	local irr = render3d.pipelines.ddgi_irradiance:GetFramebuffer(1):GetAttachment(1):Download()
	local P = ddgi.PROBES_PER_AXIS
	local sample = {}

	for wy = math.floor(y / c.spacing) - radius, math.floor(y / c.spacing) + radius do
		for wz = math.floor(z / c.spacing) - radius, math.floor(z / c.spacing) + radius do
			for wx = math.floor(x / c.spacing) - radius, math.floor(x / c.spacing) + radius do
				local sx, sy, sz = wrap(wx, c.size.x), wrap(wy, c.size.y), wrap(wz, c.size.z)
				local index = sx + c.size.x * (sy + c.size.y * sz)
				local tx, ty = index % (P * P), math.floor(index / (P * P)) + P * cascade_index
				local r, g, b, w = data:GetPixelFloat(tx, ty)
				local flags = math.floor((w - 1) * 0.5)

				if flags < 2 and w >= 1 then
					local sum = 0

					for j = 1, 6 do
						for i = 1, 6 do
							local ir, ig, ib = irr:GetPixelFloat(tx * 8 + i, ty * 8 + j)
							sum = sum + (ir + ig + ib) / 3
						end
					end

					sample[wx .. "," .. wy .. "," .. wz] = sum / 36
				end
			end
		end
	end

	series[#series + 1] = sample

	if os.getenv("PRB_EVENTS") then
		-- every probe's texel total each frame, an event is a jump of more than 2.5 times between two reads
		events = events or {count = 0, probes = 0, last = {}, list = {}}

		for key, probe_total in pairs(sample) do
			local previous = events.last[key]

			if previous and probe_total > previous * 2.5 and probe_total > 5 then
				events.count = events.count + 1
				events.list[#events.list + 1] = {key = key, from = previous, to = probe_total, frame = frame}
			end

			events.last[key] = probe_total
		end

		events.probes = events.probes + 1
	end
	if os.getenv("PRB_STATE") then
		local px, py, pz = os.getenv("PRB_STATE"):match("([^,]+),([^,]+),([^,]+)")
		local wx, wy, wz = math.floor(tonumber(px) / c.spacing + 0.5), math.floor(tonumber(py) / c.spacing + 0.5), math.floor(tonumber(pz) / c.spacing + 0.5)
		local sx, sy, sz = wrap(wx, c.size.x), wrap(wy, c.size.y), wrap(wz, c.size.z)
		local index = sx + c.size.x * (sy + c.size.y * sz)
		local tx, ty = index % (P * P), math.floor(index / (P * P)) + P * cascade_index
		local r, g, b, w = data:GetPixelFloat(tx, ty)
		local flags = math.floor((w - 1) * 0.5)
		print(string.format("STATE frame %d offset %+.3f %+.3f %+.3f flags %d (%s%s) backface %.3f", frame, (r - wx) * c.spacing, (g - wy) * c.spacing, (b - wz) * c.spacing, flags, flags % 2 == 1 and "moved " or "", flags >= 2 and "disabled" or "", w - 1 - 2 * flags))
	end

	if os.getenv("PRB_RAYS") then
		local px, py, pz = os.getenv("PRB_RAYS"):match("([^,]+),([^,]+),([^,]+)")
		local wx, wy, wz = math.floor(tonumber(px) / c.spacing + 0.5), math.floor(tonumber(py) / c.spacing + 0.5), math.floor(tonumber(pz) / c.spacing + 0.5)
		local sx, sy, sz = wrap(wx, c.size.x), wrap(wy, c.size.y), wrap(wz, c.size.z)
		local index = sx + c.size.x * (sy + c.size.y * sz)
		local rays = render3d.pipelines.ddgi_shade:GetFramebuffer(1):GetAttachment(1):Download()
		local stride = ddgi.RAYS_PER_PROBE + ddgi.EMITTER_SAMPLES
		local list = {}

		for r = 0, ddgi.RAYS_PER_PROBE - 1 do
			local rr, rg, rb, ra = rays:GetPixelFloat(r + stride * cascade_index, index)
			list[#list + 1] = {r = r, luma = (rr + rg + rb) / 3, a = ra}
		end

		table.sort(list, function(a, b) return a.luma > b.luma end)
		local total = 0

		for _, e in ipairs(list) do total = total + e.luma end

		print(string.format("RAYS frame %d total luma %.1f uniform_rays %d  top: %s", frame, total, ddgi.GetUniformRays(), (function()
			local out = {}
			for i = 1, 4 do out[#out + 1] = string.format("[%d %s luma %.0f a %.0f]", list[i].r, list[i].r < ddgi.GetUniformRays() and "uni" or "gui", list[i].luma, list[i].a) end
			return table.concat(out, " ")
		end)()))
	end

	if events and events.probes == samples then
		local n = 0

		for _ in pairs(events.last) do n = n + 1 end

		print(string.format("EVENTS %d jumps over 2.5x in %d reads of %d probes (%.4f per probe per read)", events.count, samples, n, events.count / (samples * n)))

		for i = 1, math.min(#events.list, 8) do
			local e = events.list[i]
			print(string.format("EVENTS  frame %d probe %s %.1f -> %.1f", e.frame, e.key, e.from, e.to))
		end

		System.ShutDown(0)
	end

	if #series == samples then
		local rows = {}

		for key in pairs(series[1]) do
			local values = {}

			for _, s in ipairs(series) do
				if s[key] then values[#values + 1] = s[key] end
			end

			if #values == samples then
				local mean = 0

				for _, v in ipairs(values) do mean = mean + v end

				mean = mean / #values
				local var = 0

				for _, v in ipairs(values) do var = var + (v - mean) ^ 2 end

				rows[#rows + 1] = {key = key, mean = mean, rel = mean > 1e-3 and math.sqrt(var / #values) / mean or 0}
			end
		end

		if os.getenv("PRB_SERIES") then
			local px, py, pz = os.getenv("PRB_SERIES"):match("([^,]+),([^,]+),([^,]+)")
			local key = math.floor(tonumber(px) / c.spacing + 0.5) .. "," .. math.floor(tonumber(py) / c.spacing + 0.5) .. "," .. math.floor(tonumber(pz) / c.spacing + 0.5)
			local out = {}

			for _, sample in ipairs(series) do out[#out + 1] = string.format("%.1f", sample[key] or -1) end

			print("NOISE series " .. key .. ": " .. table.concat(out, " "))
		end

		table.sort(rows, function(a, b) return a.rel > b.rel end)
		local total, count, weighted, wsum = 0, 0, 0, 0

		for _, row in ipairs(rows) do
			total = total + row.rel
			count = count + 1
			weighted = weighted + row.rel * row.mean
			wsum = wsum + row.mean
		end

		print(string.format("NOISE cascade %d spacing %.2f probes %d mean relative std %.3f (brightness weighted %.3f)", cascade_index, c.spacing, count, total / count, weighted / wsum))

		for i = 1, math.min(#rows, tonumber(os.getenv("PRB_TOP") or "") or 14) do
			local p = rows[i].key:match("(.+)")
			local wx, wy, wz = p:match("(-?%d+),(-?%d+),(-?%d+)")
			print(string.format("NOISE  probe %6.2f %6.2f %6.2f  mean %9.2f  rel std %.3f", wx * c.spacing, wy * c.spacing, wz * c.spacing, rows[i].mean, rows[i].rel))
		end

		System.ShutDown(0)
	end
end)
