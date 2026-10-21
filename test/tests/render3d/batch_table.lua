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

local animation_version = 0

local function get_animation_version()
	return animation_version
end

local function create_table(per_frame)
	return BatchTable.New{
		label = "test batches",
		record_type = Record,
		write_record = write_record,
		animation_version = get_animation_version,
		per_frame = per_frame,
	}
end

local function release_a_buffer()
	local buffer = render.CreateBuffer{
		byte_size = 16,
		buffer_usage = {"storage_buffer", "shader_device_address"},
		memory_property = {"host_visible", "host_coherent"},
	}
	buffer:GetDeviceAddress()
	buffer:Remove()
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

T.Test3D("Graphics render3d batch table copies the record of rows with the same mesh and material", function()
	local batch_table = BatchTable.New{
		label = "test batches",
		record_type = Record,
		shared_records = true,
		write_record = write_record,
		animation_version = get_animation_version,
	}
	local batches = create_batches(20)
	local material = create_material()
	local context = {writes = 0}

	for i = 1, 20 do
		batches[i].material = material
		batches[i].value = 7
	end

	batch_table:Update(pipeline, batches, 1, 1, context)
	T(context.writes)["=="](1)

	for i = 1, 20 do
		T(read_record(batch_table.buffers[1], i).value)["=="](7)
	end

	local more = create_batches(40)

	for i = 1, 40 do
		more[i].material = material
		more[i].value = 7
	end

	for i = 1, 20 do
		more[i] = batches[i]
	end

	context.writes = 0
	batch_table:Update(pipeline, more, 2, 2, context)
	T(context.writes)["<="](5)
	T(read_record(batch_table.buffers[1], 40).value)["=="](7)
	batch_table:Remove()
end)


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
	T(update(1, 2))["=="](4)
	T(update(1, 3))["=="](4)
	T(update(2, 4))["=="](4)
	batches[50] = {mesh = batches[50].mesh, first_polygon3d = batches[50].first_polygon3d, value = 5000}
	T(update(3, 5))["=="](1 + 4)
	T(read_record(batch_table.buffers[1], 50).value)["=="](5000)
	local release_serial = Buffer.address_release_serial
	release_a_buffer()
	T(Buffer.address_release_serial > release_serial)["=="](true)
	T(update(3, 6))["=="](4)
	batches[100].value = 1000
	T(update(3, 7))["=="](4)
	T(read_record(batch_table.buffers[1], 100).value)["=="](100)
	material:SetOther(1)
	T(update(3, 8))["=="](2 + 4)
	T(read_record(batch_table.buffers[1], 100).value)["=="](1000)
	batches[101].value = 2000
	material:SetOther(1)
	T(update(3, 9))["=="](4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](101)
	material:SetOther(2)
	T(update(3, 10))["=="](2 + 4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](2000)
	local other = create_material()
	batches[101] = {mesh = batches[101].mesh, first_polygon3d = batches[101].first_polygon3d, material = other, value = 3000}
	T(update(4, 11))["=="](1 + 4)
	batches[101].value = 3500
	material:SetOther(3)
	T(update(4, 12))["=="](1 + 4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](3000)
	other:SetOther(1)
	T(update(4, 13))["=="](1 + 4)
	T(read_record(batch_table.buffers[1], 101).value)["=="](3500)
	local doomed = Polygon3D.New()
	shapes.BuildCube(doomed, 3)
	doomed:Upload()
	batches[60] = {mesh = doomed:GetMesh(), first_polygon3d = doomed, value = 60}
	T(update(5, 14))["=="](1 + 4)
	local addresses = ffi.cast(UInt64Ptr, read_record(batch_table.buffers[1], 60).addresses)
	T(addresses[0] == doomed:GetMesh():GetVertexBufferAddress())["=="](true)
	doomed:GetMesh():Remove()
	release_a_buffer()
	T(update(5, 15))["=="](4)
	addresses = ffi.cast(UInt64Ptr, read_record(batch_table.buffers[1], 60).addresses)
	T(addresses[0] == 0)["=="](true)
	T(addresses[1] == 0)["=="](true)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table drops what it kept of batches past the end", function()
	local batch_table = BatchTable.New{
		label = "test batches",
		record_type = Record,
		write_record = write_record,
		animation_version = get_animation_version,
		write_animated = function(context, pipeline, record, batch)
			record.value = batch.value + 0.5
		end,
	}
	local batches = create_batches(10)
	batches[9].material = create_material()
	batches[9].material:SetAnimated(true)
	local context = {writes = 0}
	batch_table:Update(pipeline, batches, 1, 1, context)
	batches[9] = nil
	batches[10] = nil
	animation_version = animation_version + 1
	batch_table:Update(pipeline, batches, 2, 2, context)
	T(batch_table.animated_batches[9])["=="](nil)
	T(batch_table.batch_at[9])["=="](nil)
	batch_table:Remove()
end)

T.Test3D("Graphics render3d batch table writes the animated part of animated batches when the animation changed", function()
	local animated_writes = 0
	local batch_table = BatchTable.New{
		label = "test batches",
		record_type = Record,
		write_record = write_record,
		animation_version = get_animation_version,
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
	T(animated_writes)["=="](1)
	T(read_record(batch_table.buffers[1], 8).value)["=="](8.5)
	animation_version = animation_version + 1
	context.writes = 0
	batch_table:Update(pipeline, batches, 1, 3, context)
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
