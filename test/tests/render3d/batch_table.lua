local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local Buffer = import("goluwa/render/vulkan/internal/buffer.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local BatchTable = import("goluwa/render3d/batch_table.lua")
local objects = import("goluwa/objects/objects.lua")
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

-- a material of the batches: its versioned properties stamp it, which is how a batch table finds out it changed
local Material = objects.CreateTemplate("test_batch_table_material")
Material:StartStorable({versioned = true})
Material:GetSet("Animated", false)
Material:GetSet("Other", 0)
Material:EndStorable()
Material:Register()

function Material:HasVertexAnimation()
	return self.Animated
end

local function create_material()
	return objects.CreateObject(Material)
end

T.Test3D("Graphics render3d batch table rewrites records when needed", function()
	local batch_table = create_table()
	local batches = create_batches(300)
	local material = create_material()
	batches[100].material = material
	batches[101].material = material
	batches[200].material = create_material()
	local context = {writes = 0}

	local function update(batch_serial, submission)
		context.writes = 0
		batch_table:Update(pipeline, batches, batch_serial, submission, context)
		return context.writes
	end

	T(update(1, 1))["=="](300)
	T(update(1, 1))["=="](0)
	-- a few records are written in full every update in case something changed that no version saw
	T(update(1, 2))["=="](4)
	T(update(1, 3))["=="](4)
	T(update(2, 4))["=="](300)
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
	-- what a batch holds changes without its material saying so, which it only finds out by the window
	batches[100].value = 1000
	T(update(2, 6))["=="](4)
	T(read_record(batch_table.buffers[1], 100).value)["=="](100)
	-- the batches of a material that changed are written
	material:SetOther(1)
	T(update(2, 7))["=="](2 + 4)
	T(read_record(batch_table.buffers[1], 100).value)["=="](1000)
	batches[101].value = 2000
	-- a material that did not change since is left alone, also when it is the same value
	material:SetOther(1)
	T(update(2, 8))["=="](4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](101)
	material:SetOther(2)
	T(update(2, 9))["=="](2 + 4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](2000)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table writes the animated part of animated batches every update", function()
	local animated_writes = 0
	local batch_table = BatchTable.New{
		label = "test batches",
		record_type = Record,
		write_record = write_record,
		write_animated = function(context, pipeline, record, batch)
			animated_writes = animated_writes + 1
			record.value = batch.value + 0.5
		end,
	}
	local batches = create_batches(10)
	batches[8].material = create_material()
	batches[8].material:SetAnimated(true)
	local context = {writes = 0}
	batch_table:Update(pipeline, batches, 1, 1, context)
	T(context.writes)["=="](10)
	T(animated_writes)["=="](1)
	T(read_record(batch_table.buffers[1], 8).value)["=="](8.5)
	context.writes = 0
	batches[8].value = 80
	batch_table:Update(pipeline, batches, 1, 2, context)
	T(context.writes)["=="](4)
	T(animated_writes)["=="](2)
	T(read_record(batch_table.buffers[1], 8).value)["=="](80.5)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table only copies the records a frame's buffer is behind on", function()
	local get_current_frame = render.GetCurrentFrame
	local frame = 1
	render.GetCurrentFrame = function()
		return frame
	end
	local ok, err = pcall(function()
		local batch_table = create_table(true)
		local batches = create_batches(8)
		local material = create_material()
		batches[8].material = material
		local context = {writes = 0}
		batch_table:Update(pipeline, batches, 1, 1, context)
		frame = 2
		batch_table:Update(pipeline, batches, 1, 2, context)
		batches[8].value = 80
		material:SetOther(1)
		frame = 1
		batch_table:Update(pipeline, batches, 1, 3, context)
		T(read_record(batch_table.buffers[1], 8).value)["=="](80)
		-- the other frame's buffer has not been written yet, but still gets the change when its turn comes
		T(read_record(batch_table.buffers[2], 8).value)["=="](8)
		frame = 2
		batch_table:Update(pipeline, batches, 1, 4, context)
		T(read_record(batch_table.buffers[2], 8).value)["=="](80)
		batch_table:Remove()
	end)
	render.GetCurrentFrame = get_current_frame

	if not ok then error(err, 0) end
end)

T.Test3D("Graphics render3d batch table follows every material when the log was outrun", function()
	local batch_table = create_table()
	local batches = create_batches(20)
	local material = create_material()
	batches[15].material = material
	local context = {writes = 0}
	batch_table:Update(pipeline, batches, 1, 1, context)
	batches[15].value = 150
	local other = create_material()

	for i = 1, objects.VERSION_LOG_SIZE do
		other:SetOther(i)
	end

	material:SetOther(5)
	context.writes = 0
	batch_table:Update(pipeline, batches, 1, 2, context)
	T(read_record(batch_table.buffers[1], 15).value)["=="](150)
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
