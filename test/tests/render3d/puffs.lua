local T = import("test/environment.lua")
local puffs = import("goluwa/render3d/puffs.lua")
local event = import("goluwa/event.lua")
local vfx = import("goluwa/render3d/vfx.lua")

local function spawn(life, delay)
	puffs.Spawn{
		Flipbook = "smoke",
		X = 0,
		Y = 1,
		Z = 0,
		VX = 0,
		VY = 0,
		VZ = 0,
		Drag = 0,
		Buoyancy = 0,
		Delay = delay,
		Life = life,
		RadiusStart = 0.5,
		RadiusEnd = 1,
		Grow = 1,
		R0 = 1,
		G0 = 1,
		B0 = 1,
		R1 = 1,
		G1 = 1,
		B1 = 1,
		ColorCurve = 1,
		Brightness = 1,
		FadeIn = 0.1,
		FadeStart = 0.5,
		Roll = 0,
		Spin = 0,
		Fps = 12,
		Offset = 0,
	}
end

T.Test3D("Puffs, streamers and streaks live, emit and expire", function()
	puffs.Clear()
	spawn(0.2, 0)
	spawn(0.5, 0)
	spawn(0.2, 0.3)
	T(puffs.GetCount())["=="](3)
	event.Call("Update", 0.05)
	T(puffs.GetCount())["=="](3)

	for _ = 1, 5 do
		event.Call("Update", 0.05)
	end

	T(puffs.GetCount())["=="](2)

	for _ = 1, 6 do
		event.Call("Update", 0.05)
	end

	T(puffs.GetCount())["=="](0)
	puffs.Clear()
	local template = {
		Flipbook = "smoke",
		Drag = 0,
		Buoyancy = 0,
		Life = 5,
		RadiusStart = 0.2,
		RadiusEnd = 0.5,
		Grow = 1,
		R0 = 1,
		G0 = 1,
		B0 = 1,
		R1 = 1,
		G1 = 1,
		B1 = 1,
		ColorCurve = 1,
		Brightness = 1,
		FadeIn = 0.1,
		FadeStart = 0.5,
		Spin = 0,
		Fps = 12,
	}
	puffs.SpawnStreamer{
		X = 0,
		Y = 5,
		Z = 0,
		VX = 1,
		VY = 0,
		VZ = 0,
		Drag = 0,
		Gravity = 0,
		Delay = 0,
		Life = 1,
		Interval = 0.1,
		Jitter = 0.1,
		HeadRadius = 0.3,
		HeadR = 4,
		HeadG = 2,
		HeadB = 1,
		Template = template,
	}
	puffs.SpawnStreak{
		Flipbook = "fire",
		X = 0,
		Y = 1,
		Z = 0,
		DX = 1,
		DY = 0,
		DZ = 0,
		Delay = 0,
		Life = 0.2,
		Reach = 3,
		Grow = 2,
		TailStart = 0.2,
		TailEnd = 0.9,
		Rise = 0,
		WidthStart = 0.3,
		WidthEnd = 0.1,
		R0 = 1,
		G0 = 1,
		B0 = 1,
		R1 = 1,
		G1 = 1,
		B1 = 1,
		ColorCurve = 1,
		Brightness = 1,
		FadeIn = 0.1,
		FadeStart = 0.5,
		Fps = 12,
		Offset = 0,
	}

	for _ = 1, 6 do
		event.Call("Update", 0.05)
	end

	T(puffs.GetCount())[">="](2)
	local emitted = puffs.GetCount()

	for _ = 1, 6 do
		event.Call("Update", 0.05)
	end

	T(puffs.GetCount())[">"](emitted)
	puffs.Clear()
	T(puffs.GetCount())["=="](0)
	event.Call("LateUpdate")
	event.Call("LateUpdate")
	event.Call("LateUpdate")
	vfx.GetFlipbookBatch("smoke").entity:Remove()
	vfx.GetFlipbookBatch("fire").entity:Remove()
end)
