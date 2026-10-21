local T = import("test/environment.lua")
local ffi = require("ffi")
local EasyPipeline = import("goluwa/render/easy_pipeline_base.lua").EasyPipeline
local Constants = ffi.typeof("struct { float values[4]; }")

local function new_pipeline()
	return {push_constant_cache_by_cmd = setmetatable({}, {__mode = "k"})}
end

local function push(pipeline, cmd, key, stage, offset, data)
	return EasyPipeline.ShouldPushConstants(pipeline, cmd, key, stage, offset, data, ffi.sizeof(data))
end

T.Test("EasyPipeline ShouldPushConstants only pushes what changed since the command buffer started recording", function()
	local pipeline = new_pipeline()
	local cmd = {recording_serial = 1}
	local key = {}
	local data = Constants()
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](true)
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](false)
	data.values[2] = 3
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](true)
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](false)
	T(push(pipeline, cmd, key, "fragment", 0, data))["=="](true)
	T(push(pipeline, cmd, key, "vertex", 16, data))["=="](true)
	T(push(pipeline, cmd, {}, "vertex", 0, data))["=="](true)
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](false)
	cmd.recording_serial = 2
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](true)
	T(push(pipeline, cmd, key, "vertex", 0, data))["=="](false)
	T(push(pipeline, {recording_serial = 1}, key, "vertex", 0, data))["=="](true)
end)

T.Test("EasyPipeline ShouldPushConstants reuses its entries instead of allocating new ones", function()
	local pipeline = new_pipeline()
	local cmd = {recording_serial = 1}
	local key = {}
	local data = Constants()
	push(pipeline, cmd, key, "vertex", 0, data)
	local cache = pipeline.push_constant_cache_by_cmd[cmd]
	local entry = cache.entries[1]
	local snapshot = entry.snapshot
	data.values[0] = 1
	push(pipeline, cmd, key, "vertex", 0, data)
	T(cache.entries[1])["=="](entry)
	T(entry.snapshot)["=="](snapshot)
	T(snapshot[0] ~= 0 or snapshot[1] ~= 0 or snapshot[2] ~= 0 or snapshot[3] ~= 0)["=="](true)
	cmd.recording_serial = 2
	push(pipeline, cmd, key, "vertex", 0, data)
	T(cache.entries[1])["=="](entry)
	T(cache.count)["=="](1)
end)

T.Test("EasyPipeline _BytesEqual compares memory", function()
	local a, b = Constants(), Constants()
	T(EasyPipeline._BytesEqual(nil, a, b, ffi.sizeof(a)))["=="](true)
	b.values[3] = 1
	T(EasyPipeline._BytesEqual(nil, a, b, ffi.sizeof(a)))["=="](false)
	T(EasyPipeline._BytesEqual(nil, a, b, 0))["=="](false)
end)
