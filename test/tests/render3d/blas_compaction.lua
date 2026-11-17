local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local system = import("goluwa/system.lua")
local Polygon3D = import("goluwa/render3d/polygon_3d.lua")
local shapes = import("goluwa/render3d/shapes.lua")
local meshes = import("goluwa/render3d/scene/meshes.lua")
local accel = import("goluwa/render3d/scene/accel.lua")
local pvars = import("goluwa/cli/pvars.lua")

local function cube_job(subdivisions)
	local poly = Polygon3D.New()
	shapes.BuildCube(poly, 1, 1, subdivisions)
	poly:Upload()
	local record = meshes.GetRecord(meshes.Get(poly.mesh))
	return {
		poly = poly,
		vertex_address = record.vertex_address,
		vertex_stride = record.vertex_stride,
		vertex_count = record.vertex_count,
		index_address = record.index_address,
		index_is_32 = record.index_is_32,
		triangle_count = record.triangle_count,
		allow_update = false,
		address = 0,
	}
end

local function submit(fn)
	local cmd = render.GetCommandPool():AllocateCommandBuffer()
	cmd:Begin()
	fn(cmd)
	cmd:End()
	render.SubmitAndWait(cmd)
	cmd:Remove()
end

T.Test3DRayTracing("Graphics render3d blas compaction reads a batch's compacted sizes only after the gpu has run it", function()
	pvars.SetSession("r_rt_blas_compaction", true)
	local small = cube_job(1)
	local big = cube_job(24)
	local frame = system.GetFrameNumber()
	local get_frame_number = system.GetFrameNumber
	system.GetFrameNumber = function()
		return frame
	end

	submit(function(cmd)
		accel.BuildBLASes(cmd, {small}, 1)
	end)

	frame = frame + 100

	submit(function(cmd)
		accel.CompactBLASes(cmd)
	end)

	-- the big build takes the query pool the small batch just gave back, its reset has not run on the gpu yet
	local pending = render.GetCommandPool():AllocateCommandBuffer()
	pending:Begin()
	accel.BuildBLASes(pending, {big}, 1)

	submit(function(cmd)
		accel.CompactBLASes(cmd)
	end)

	T(big.compact)["=="](nil)
	pending:End()
	render.SubmitAndWait(pending)
	pending:Remove()
	frame = frame + 100

	submit(function(cmd)
		accel.CompactBLASes(cmd)
	end)

	T(big.compact ~= nil)["=="](true)
	system.GetFrameNumber = get_frame_number
	accel.ReleaseBLAS(small)
	accel.ReleaseBLAS(big)
end)
