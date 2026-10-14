local system = import("goluwa/system.lua")
local event = import("goluwa/event.lua")
local gpu_timing = import("goluwa/render/gpu_timing.lua")
local View = import("goluwa/render3d/view.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local frames = tonumber(os.getenv("FRAMES") or "120")
local warm = 30
local views = {}

for v in (os.getenv("VIEWS") or "0,2,0,10,0"):gmatch("[^;]+") do
	local x, y, z, p, yw = v:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
	views[#views + 1] = View.New{Position = Vec3(tonumber(x), tonumber(y), tonumber(z)), Rotation = QuatDeg3(tonumber(p), tonumber(yw), 0), Priority = 100 + #views}
end

local current = 0
local n, sum, last = 0, {}, {}
local per_view = warm + frames
local frame = 0
event.AddListener("Update", "clouds_gpu_time", function()
	local vi = math.floor(frame / per_view) + 1

	if vi > #views then
		system.ShutDown(0)
		return
	end

	if vi ~= current then
		current = vi
		views[vi]:Activate()
		n, sum, last = 0, {}, {}
	end

	local k = frame % per_view
	frame = frame + 1

	if k < warm then return end

	local names = gpu_timing.GetScopeNames()

	for i = 1, #names do
		local ms = gpu_timing.GetRawMilliseconds(names[i])

		if last[names[i]] ~= ms then
			last[names[i]] = ms
			sum[names[i]] = (sum[names[i]] or 0) + ms
		end
	end

	n = n + 1

	if k == per_view - 1 then
		local parts = {}

		for name, v in pairs(sum) do
			if name:find("cloud") or name == "gpu_frame" then
				parts[#parts + 1] = string.format("%s=%.3f", name, v / n)
			end
		end

		table.sort(parts)
		print("GPU view " .. vi .. ": " .. table.concat(parts, "  "))
	end
end)
