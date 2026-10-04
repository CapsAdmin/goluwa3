local T = import("test/environment.lua")
local ffi = require("ffi")
local buffer = require("string.buffer")
local steam = import("goluwa/steam/steam.lua")
local vfs = import("goluwa/vfs.lua")
local mdl = import("goluwa/codecs/mdl.lua")
local vvd = import("goluwa/codecs/vvd.lua")
local vtx = import("goluwa/codecs/vtx.lua")
local phy = import("goluwa/codecs/phy.lua")
local source = import("goluwa/codecs/internal/source.lua")
local tasks = import("goluwa/tasks.lua")
local MODEL = "models/props_c17/oildrum001"
local mounted = steam.FindSourceGame("gmod") and steam.MountSourceGame("gmod")

local function read(path)
	local file = vfs.Open(vfs.FindMixedCasePath(path) or path)

	if not file then return nil end

	local data = file:ReadBytes(file:GetSize())
	file:Close()
	return data
end

T.Test("source2meters comes from the shared constant", function()
	T(steam.source2meters)["=="](source.meters)
end)

T.Test("mdl codec reads the header, materials and bodyparts", function()
	if not mounted then return end

	local meta = assert(mdl.Decode(read(MODEL .. ".mdl")))
	T(meta.bodypart_count)[">"](0)
	T(meta.mass)[">"](0)
	T(meta.materials[1] ~= nil)["=="](true)
	T(#meta.texturedir)[">"](0)
	T(#meta.bodypart_models[1][1].meshes)[">"](0)
	T(table.equal(buffer.decode(buffer.encode(meta)), meta))["=="](true)
end)

T.Test("vvd and vtx codecs agree on the vertex count and the indices stay in range", function()
	if not mounted then return end

	local vvd_meta, vertices = assert(vvd.Decode(read(MODEL .. ".vvd")))
	local vtx_meta, ids = assert(vtx.Decode(read(MODEL .. ".dx90.vtx"), 25, 1))
	T(vvd_meta.count)[">"](0)
	T(ffi.sizeof(vertices))[">="](vvd_meta.count * vvd.VertexSize)
	local mesh = vtx_meta.body_parts[1].models[1].lods[1].meshes[1]
	T(mesh.count)[">"](0)
	T(mesh.count % 3)["=="](0)
	local pointer = ffi.cast("const uint16_t *", ids + mesh.offset)

	for i = 0, mesh.count - 1 do
		T(pointer[i])["<"](vvd_meta.count)
	end

	T(table.equal(buffer.decode(buffer.encode(vtx_meta)), vtx_meta))["=="](true)
end)

T.Test("phy codec returns plain solids in engine space", function()
	if not mounted then return end

	local meta = assert(phy.Decode(read(MODEL .. ".phy")))
	T(#meta.solids)[">"](0)
	T(#meta.solids[1].ledges[1] % 3)["=="](0)
	T(meta.solids[1].mass)[">"](0)
	T(type(meta.solids[1].surface_property))["=="]("string")
	T(table.equal(buffer.decode(buffer.encode(meta)), meta))["=="](true)
end)

T.Test("codecs report malformed data as errors instead of crashing", function()
	if not mounted then return end

	local inputs = {
		{mdl.Decode, read(MODEL .. ".mdl")},
		{vvd.Decode, read(MODEL .. ".vvd")},
		{
			function(str)
				return vtx.Decode(str, 25, 1)
			end,
			read(MODEL .. ".dx90.vtx"),
		},
		{phy.Decode, read(MODEL .. ".phy")},
	}

	for _, input in ipairs(inputs) do
		local decode, data = input[1], input[2]

		for _, length in ipairs{0, 1, 4, 16, 64, 200, 1000, math.floor(#data / 2), #data - 1} do
			pcall(decode, data:sub(1, length))
		end

		math.randomseed(11)

		for _ = 1, 60 do
			local position = math.random(1, #data)
			local corrupt = data:sub(1, position - 1) .. string.char(math.random(0, 255)) .. data:sub(position + 1)
			pcall(decode, corrupt)
		end
	end
end)

T.Test("the model decoder job gives the same result on a worker as inline", function()
	if not mounted then return end

	local thread_pool = import("goluwa/thread_pool.lua")
	local model_loader = import("goluwa/render3d/model_loader.lua")
	local pvars = import("goluwa/cli/pvars.lua")
	local results = {}

	for _, threads in ipairs{0, 4} do
		pvars.SetSession("r_codec_threads", threads)
		thread_pool.Shutdown()
		local meshes, physics
		local done = false

		model_loader.LoadModel(MODEL .. ".mdl", function(data)
			meshes, physics = #data, data.physics
			done = true
		end)

		local waited = 0

		while not done and waited < 600 do
			waited = waited + 1
			tasks.Wait(0.05)
		end

		results[#results + 1] = {meshes = meshes, hull_count = physics and #physics.children or 0}
		model_loader.model_cache = {}
		model_loader.model_loads = import("goluwa/utility.lua").CreateLoadCache(model_loader.model_cache)
	end

	thread_pool.Shutdown()
	T(results[1].hull_count)[">"](0)
	T(results[1].hull_count)["=="](results[2].hull_count)
	T(results[1].meshes)["=="](results[2].meshes)
end)
