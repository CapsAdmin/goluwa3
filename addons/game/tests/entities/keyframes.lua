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

T.Test("the held victim bones are placed at the reach points and its velocity is sampled from the keys", function()
	local Vec3 = import("goluwa/structs/vec3.lua")
	local Quat = import("goluwa/structs/quat.lua")
	local bones = {
		right = {m30 = 0.2, m31 = 1, m32 = 0},
		left = {m30 = -0.2, m31 = 1, m32 = 0},
	}
	local reach = {0.2, 2, 0, -0.2, 2, 0, 0, 0, 0}
	local def = keyframes.Compile{
		CarryBones = {"right", "left"},
		Keys = {
			{0, body = {0, 0, 0}, carry = reach},
			{1, body = {4, 0, 0}, carry = reach, ease = "linear"},
		},
	}
	local position, rotation = Vec3(), Quat()
	keyframes.EvaluateVictim(def, 0.5, bones, position, rotation)
	T(position.x)["~"](2, 1e-6)
	T(position.y)["~"](1, 1e-6)
	T(position.z)["~"](0, 1e-6)
	T(rotation.w)["~"](1, 1e-6)
	local velocity = keyframes.EvaluateVictimVelocity(def, 0.5, 2, bones, Vec3())
	T(velocity.x)["~"](2, 1e-3)
	T(velocity.y)["~"](0, 1e-6)
	local tilted = keyframes.Compile{
		CarryBones = {"right", "left"},
		Keys = {
			{0, carry = {0.2, 2, 0, -0.2, 2, 0, math.pi / 2, 0, 0}},
			{1, carry = {0.2, 2, 0, -0.2, 2, 0, math.pi / 2, 0, 0}},
		},
	}
	local offset = Vec3()
	keyframes.EvaluateCarry(tilted, 0.5, bones, offset, rotation)
	T(offset.x)["~"](0, 1e-6)
	T(offset.y)["~"](2, 1e-6)
	T(offset.z)["~"](-1, 1e-6)
	local longer = {
		right = {m30 = 0.2, m31 = 1.5, m32 = 0},
		left = {m30 = -0.2, m31 = 1.5, m32 = 0},
	}
	keyframes.EvaluateCarry(def, 0.5, longer, offset, rotation)
	T(offset.y)["~"](0.5, 1e-6)
end)

T.Test("grip keys need carry keys and carry keys need the carried bones", function()
	T(pcall(keyframes.Compile, {Keys = {{0.5, grip = {1}}}}))["=="](false)
	T(pcall(keyframes.Compile, {Keys = {{0.5, carry = {0, 1, 0}}}}))["=="](false)
	T(pcall(keyframes.Compile, {Keys = {{0.5, grip = {1}, carry = {0, 1, 0}}}}))["=="](false)
	local def = keyframes.Compile{
		CarryBones = {"upperarm_r", "upperarm_l"},
		Keys = {{0.5, grip = {1}, carry = {0, 1, 0}}},
	}
	T(def.Bones)["=="](keyframes.ApplyGrip)
	T(def.GripKeys[2][2])["=="](1)
	T(def.CarryKeys[2][3])["=="](1)
	T(def.CarryKeys[2][10])["=="](0)
end)
