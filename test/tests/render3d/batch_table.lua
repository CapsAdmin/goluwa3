local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local Record = ffi.typeof([[struct {
	uint32_t addresses[4];
	uint32_t index_is_32;
	float value;
}]])
local RecordPtr = ffi.typeof("$ *", Record)
local UInt64Ptr = ffi.typeof("uint64_t *")
local pipeline = {}

local function write_record(context, pipeline, record, batch)
	context.writes = context.writes + 1
	record.value = batch.value
end

local function create_table(per_frame)
	return BatchTable.New{
		label = "test batches",
		record_type = Record,
		write_record = write_record,
		per_frame = per_frame,
	}
end

local function create_batches(count)
	local polygon3d = Polygon3D.New()
	shapes.BuildCube(polygon3d, 1)
	polygon3d:Upload()
	local batches = {}

	for i = 1, count do
		batches[i] = {
			mesh = polygon3d:GetMesh(),
			first_polygon3d = polygon3d,
			value = i,
		}
	end

	return batches
end

local function read_record(buffer, index)
	return ffi.cast(RecordPtr, buffer:Map())[index - 1]
end

T.Test3D("Graphics render3d batch table writes mesh addresses and records", function()
	local batch_table = create_table()
	local batches = create_batches(3)
	local context = {writes = 0}
	local address = batch_table:Update(pipeline, batches, 1, 1, context)
	local buffer = batch_table.buffers[1]
	local mesh = batches[1].mesh
	T(mesh.index_buffer)["=="](nil)
	T(address)["=="](buffer:GetDeviceAddress())
	T(context.writes)["=="](3)

	for i = 1, 3 do
		local record = read_record(buffer, i)
		local addresses = ffi.cast(UInt64Ptr, record.addresses)
		T(record.value)["=="](i)
		T(addresses[0] == mesh:GetVertexBufferAddress())["=="](true)
		T(addresses[1] == mesh:GetIndexBufferAddress())["=="](true)
		-- the cube is uploaded without indices
		T(record.index_is_32)["=="](0)
	end

	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table zeroes the addresses of removed meshes", function()
	local batch_table = create_table()
	local batches = create_batches(2)
	local removed = Polygon3D.New()
	shapes.BuildCube(removed, 5)
	removed:Upload()
	batches[2] = {mesh = removed:GetMesh(), first_polygon3d = removed, value = 2}
	removed:GetMesh():Remove()
	local context = {writes = 0}
	batch_table:Update(pipeline, batches, 1, 1, context)
	local record = read_record(batch_table.buffers[1], 2)
	local addresses = ffi.cast(UInt64Ptr, record.addresses)
	T(context.writes)["=="](1)
	T(addresses[0] == 0)["=="](true)
	T(addresses[1] == 0)["=="](true)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table rewrites records when needed", function()
	local batch_table = create_table()
	local batches = create_batches(300)
	local context = {writes = 0}

	local function update(batch_serial, submission)
		context.writes = 0
		batch_table:Update(pipeline, batches, batch_serial, submission, context)
		return context.writes
	end

	T(update(1, 1))["=="](300)
	-- the same submission reuses what it wrote
	T(update(1, 1))["=="](0)
	-- later submissions refresh a window of records and wrap around
	T(update(1, 2))["=="](256)
	T(update(1, 3))["=="](44)
	T(update(1, 4))["=="](256)
	-- a changed dataset rewrites everything, even within a submission
	T(update(2, 4))["=="](300)
	-- as does a removed buffer whose address a record may hold
	local release_serial = Buffer.address_release_serial
	local buffer = render.CreateBuffer{
		byte_size = 16,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
	}
	buffer:GetDeviceAddress()
	buffer:Remove()
	T(Buffer.address_release_serial > release_serial)["=="](true)
	T(update(2, 5))["=="](300)
	-- a record rewritten by a window update reaches the gpu copy
	batches[1].value = 1000
	T(update(2, 6))["=="](256)
	T(read_record(batch_table.buffers[1], 1).value)["=="](1000)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table grows and keeps a buffer per frame in flight", function()
	local get_current_frame = render.GetCurrentFrame
	local frame = 1
	render.GetCurrentFrame = function()
		return frame
	end
	local ok, err = pcall(function()
		local per_frame = create_table(true)
		local single = create_table(false)
		local batches = create_batches(4)
		local context = {writes = 0}
		per_frame:Update(pipeline, batches, 1, 1, context)
		single:Update(pipeline, batches, 1, 1, context)
		frame = 2
		per_frame:Update(pipeline, batches, 1, 2, context)
		single:Update(pipeline, batches, 1, 2, context)
		T(per_frame.buffers[1] ~= per_frame.buffers[2])["=="](true)
		T(single.buffers[2])["=="](nil)
		-- every frame's buffer holds the whole table, not only what changed
		T(read_record(per_frame.buffers[1], 4).value)["=="](4)
		T(read_record(per_frame.buffers[2], 4).value)["=="](4)
		local old = single.buffers[1]
		batches = create_batches(100)
		context.writes = 0
		single:Update(pipeline, batches, 1, 3, context)
		T(context.writes)["=="](100)
		T(old:IsValid())["=="](false)
		T(single.capacity >= 100)["=="](true)
		T(read_record(single.buffers[1], 100).value)["=="](100)
		per_frame:Remove()
		single:Remove()
	end)
	render.GetCurrentFrame = get_current_frame

	if not ok then error(err, 0) end
end)
