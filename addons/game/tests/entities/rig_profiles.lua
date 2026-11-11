local T = import("test/environment.lua")
local ffi = require("ffi")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local Skeleton = import("goluwa/render3d/skeleton.lua")
local resource = import("goluwa/source_engine/source2/resource.lua")
local mesh_pack = import("goluwa/source_engine/source2/mesh_pack.lua")
import("goluwa/render3d/model_loader.lua")
local mdl_decoder = import("goluwa/render3d/model_decoders/mdl.lua")
local rig_profiles = import("lua/rig_profiles.lua")

local function is_rotation(fix)
	local function dot(a, b)
		return fix[a] * fix[b] + fix[a + 3] * fix[b + 3] + fix[a + 6] * fix[b + 6]
	end

	return math.abs(dot(1, 1) - 1) < 1e-4 and
		math.abs(dot(2, 2) - 1) < 1e-4 and
		math.abs(dot(3, 3) - 1) < 1e-4 and
		math.abs(dot(1, 2)) < 1e-4 and
		math.abs(dot(1, 3)) < 1e-4 and
		math.abs(dot(2, 3)) < 1e-4
end

local function load_eli()
	local res = resource.Load(vfs, "models/characters/eli/eli.vmdl_c")
	local model_data = resource.ReadKV3(res)
	local meta, blob = mesh_pack.PackModel{
		path = "eli",
		model = res.data,
		masks = model_data.m_refLODGroupMasks,
		external = 0,
		meshes = {},
	}
	local count = #meta.skeleton.names
	local bind = ffi.new("float[?]", count * 7)
	local inverse = ffi.new("float[?]", count * 12)
	ffi.copy(bind, blob + meta.skeleton.bind_offset, count * 28)
	ffi.copy(inverse, blob + meta.skeleton.inverse_bind_offset, count * 48)
	return Skeleton.New{
		BoneNames = meta.skeleton.names,
		Parents = meta.skeleton.parents,
		BindLocal = bind,
		InverseBind = inverse,
	}
end

T.Test("the alyx rig profile names every biped bone and fixes the frames the pose code reads", function()
	local info = steam.FindSourceGame(546560)

	if not info then return T.Unavailable("half-life: alyx is not installed") end

	steam.MountSourceGame(info)
	local skeleton = load_eli()
	local profile = rig_profiles.Get(skeleton)
	T(profile.Name)["=="]("alyx")

	for _, name in ipairs(profile.Eyes) do
		T(skeleton:GetBoneIndex(name) ~= nil)["=="](true)
	end

	for key in pairs(rig_profiles.ValveBiped.Bones) do
		T(skeleton:GetBoneIndex(profile.Bones[key]) ~= nil)["=="](true)
	end

	for _, key in ipairs{"head", "chest", "hand_r", "hand_l"} do
		T(is_rotation(profile.Frames[key].fix))["=="](true)
	end
end)

T.Test("the source 1 skeleton is its own canonical frame", function()
	steam.MountSourceGame("gmod")

	if not vfs.IsFile("models/player/kleiner.mdl") then
		return T.Unavailable("gmod content not mounted")
	end

	local skeleton = mdl_decoder.LoadSkeleton("models/player/kleiner")
	T(rig_profiles.Get(skeleton).Name)["=="]("valvebiped")
	local frames = rig_profiles.GetFrames(
		skeleton,
		{
			Bones = rig_profiles.ValveBiped.Bones,
			Fingers = {
				hand_r = {fingers = "ValveBiped.Bip01_R_Finger2", thumb = "ValveBiped.Bip01_R_Finger0"},
				hand_l = {fingers = "ValveBiped.Bip01_L_Finger2", thumb = "ValveBiped.Bip01_L_Finger0"},
			},
		}
	)

	for _, key in ipairs{"head", "chest", "hand_r", "hand_l"} do
		local fix = frames[key].fix
		T(math.abs(fix[1] + fix[5] + fix[9] - 3) < 0.02)["=="](true)
	end
end)
