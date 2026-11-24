local T = import("test/environment.lua")
local vfs = import("goluwa/vfs.lua")
local cgf = import("lua/crysis_loader/cgf.lua")
local chr = import("lua/crysis_loader/chr.lua")
local cry_game = import("lua/crysis_loader/game.lua")
local CHICKEN = "Objects/Characters/animals/Birds/chicken/chicken.chr"
local TURTLE = "Objects/Characters/animals/turtle/turtle.chr"

local function mount()
	if not cry_game.GetGame(cry_game.CRYSIS_APPID) then return false end

	cry_game.MountContent(cry_game.CRYSIS_APPID)
	return true
end

local function load_skeleton(path)
	local parsed = cgf.Open(path)
	local skeleton

	for _, chunk in ipairs(parsed.chunks) do
		if chunk.type == cgf.CHUNK_COMPILED_BONES then
			skeleton = chr.BuildSkeleton(cgf.ReadCompiledBones(parsed.file, chunk))
		end
	end

	return skeleton, parsed
end

local function max_bind_skin_error(skeleton)
	local pose = skeleton:NewPose()
	local out, world = skeleton:CreateMatrices(), skeleton:CreateMatrices()
	skeleton:ComputeSkinMatrices(pose.data, out, world)
	local worst = 0

	for bone = 0, skeleton.BoneCount - 1 do
		for row = 0, 2 do
			for column = 0, 3 do
				local expected = row == column and 1 or 0
				worst = math.max(worst, math.abs(out[bone * 12 + row * 4 + column] - expected))
			end
		end
	end

	return worst
end

T.Test("CHR skeletons skin to the bind pose without moving vertices", function()
	if not mount() then return T.Unavailable("Crysis is not installed") end

	for _, path in ipairs({CHICKEN, TURTLE}) do
		local skeleton, parsed = load_skeleton(path)
		parsed.file:Close()
		T(skeleton ~= nil)["=="](true)
		T(max_bind_skin_error(skeleton))["<"](0.001)
	end
end)

T.Test("CHR skin weights are normalized per vertex", function()
	if not mount() then return T.Unavailable("Crysis is not installed") end

	local parsed = cgf.Open(CHICKEN)
	local skin = cgf.ReadSkin(parsed)
	parsed.file:Close()
	T(#skin)[">"](0)

	for _, weights in ipairs(skin) do
		T(math.abs(weights[5] + weights[6] + weights[7] + weights[8] - 1))["<"](0.01)
	end
end)

T.Test("CHR animations come from the .cal list as clips", function()
	if not mount() then return T.Unavailable("Crysis is not installed") end

	local skeleton, parsed = load_skeleton(CHICKEN)
	parsed.file:Close()
	chr.AddAnimations(skeleton, vfs.FindMixedCasePath(CHICKEN))
	local walk = skeleton.ClipsByName.walk_loop
	T(walk ~= nil)["=="](true)
	T(skeleton.ClipsByName.idle01 ~= nil)["=="](true)
	T(math.abs(walk.Duration - 78 / 30))["<"](0.001)
	local pose = skeleton:CreatePose()
	walk:Sample(0.5, {}, pose)

	for i = 0, skeleton.BoneCount * 7 - 1 do
		T(pose[i] == pose[i])["=="](true)
	end
end)
