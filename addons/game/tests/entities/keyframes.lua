local T = import("test/environment.lua")
local keyframes = import("lua/keyframes.lua")
local animations = import("lua/animations.lua")
local POSES = {
	windup = {aim = {-0.7, 0.1}, torso = 0.2, head = {0.1}},
	strike = {base = "windup", aim = {0.8, -0.3}, torso = -0.25},
}

T.Test("keyframes compile named poses into tracks that start and end at rest", function()
	local def = keyframes.Compile(
		{
			Keys = {
				{0.3, "windup", ease = "out", hold = 0.1},
				{0.6, "strike", ease = "in"},
			},
		},
		POSES
	)
	T(def.Kind)["=="]("action")
	T(#def.AimKeys)["=="](5)
	T(def.AimKeys[1][1])["=="](0)
	T(def.AimKeys[2][2])["=="](-0.7)
	T(def.AimKeys[2].ease)["=="]("out")
	T(def.AimKeys[3][1])["~"](0.4, 1e-9)
	T(def.AimKeys[3][2])["=="](-0.7)
	T(def.AimKeys[4][2])["=="](0.8)
	T(def.AimKeys[5][1])["=="](1)
	T(def.AimKeys[5][2])["=="](0)
	T(def.HeadKeys[1][2])["=="](1)
	T(def.HeadKeys[4][2])["=="](0.1)
	T(def.HandKeys)["=="](nil)
	T(def.Body)["=="](nil)
	local out = {0, 0}
	animations.SampleKeys(def.AimKeys, 0.35, out, 2)
	T(out[1])["=="](-0.7)
end)

T.Test("a lifted or flipped body turns the leg ik off and gets a body hook", function()
	local def = keyframes.Compile{Keys = {{0.5, body = {0, 0.6, 0}}}}
	T(def.Legs)["=="](false)
	T(def.Body)["=="](keyframes.ApplyBody)
	local spin = keyframes.Compile{Keys = {{0.5, body = {0, 0, 0, math.pi}}}}
	T(spin.Legs)["=="](nil)
	T(keyframes.Compile{Face = true}.Body)["=="](keyframes.ApplyBody)
end)

T.Test("keyframes out of order are an error", function()
	local ok = pcall(keyframes.Compile, {Keys = {{0.5, torso = 1}, {0.4, torso = 0}}})
	T(ok)["=="](false)
end)
