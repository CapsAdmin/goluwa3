local model_loader = {}
import.loaded["goluwa/render3d/model_loader.lua"] = model_loader
local callback = import("goluwa/callback.lua")
local event = import("goluwa/event.lua")
local resource = import("goluwa/resource.lua")
local utility = import("goluwa/utility.lua")
local tasks = import("goluwa/tasks.lua")
local vfs = import("goluwa/vfs.lua")
local thread_pool = import("goluwa/thread_pool.lua")
local assets = import("goluwa/assets.lua")
model_loader.model_decoders = model_loader.model_decoders or {}

function model_loader.AddModelDecoder(id, callback, ext)
	model_loader.RemoveModelDecoder(id)

	if ext == false then ext = "" else ext = "." .. id end

	list.insert(model_loader.model_decoders, {id = id, ext = ext, callback = callback})

	list.sort(model_loader.model_decoders, function(a, b)
		return #a.ext > #b.ext
	end)
end

function model_loader.RemoveModelDecoder(id)
	for i, v in ipairs(model_loader.model_decoders) do
		if v.id == id then
			list.remove(model_loader.model_decoders, i)

			list.sort(model_loader.model_decoders, function(a, b)
				return #a.ext > #b.ext
			end)

			return true
		end
	end

	return false
end

function model_loader.FindModelDecoder(path)
	for _, decoder in ipairs(model_loader.model_decoders) do
		if path:ends_with(decoder.ext) or decoder.ext == "" then
			return decoder.callback
		end
	end
end

model_loader.model_cache = {}
model_loader.model_loads = utility.CreateLoadCache(model_loader.model_cache)

-- a decoder whose parsing runs on a worker thread. Gather(path, full_path) runs on the main thread and returns the
-- input of the job (bytes, the workers have no vfs mounts) and its size, `job` is the source of the worker (it gets
-- the input and returns a table and a blob, see packed_mesh.lua) and Finish(path, full_path, input, meta, blob,
-- mesh_callback, physics_callback, skeleton_callback) turns the result into meshes on the main thread
function model_loader.AddThreadedDecoder(id, decoder, ext)
	model_loader.AddModelDecoder(
		id,
		function(path, full_path, mesh_callback, physics_callback, skeleton_callback)
			local input, size = decoder.Gather(path, full_path)
			local meta, blob = thread_pool.Run(decoder.job, input, size):Await()
			return decoder.Finish(
				path,
				full_path,
				input,
				meta,
				blob,
				mesh_callback,
				physics_callback,
				skeleton_callback
			)
		end,
		ext
	)
end

local function fail_model_load(loads, path, reason)
	local message = tostring(reason)
	logf("model loader failed for %q: %s\n", path, message)
	loads:Emit(path, "on_fail", message)
	loads:Forget(path)
	return message
end

function model_loader.LoadModel(path, callback, callback2, on_fail)
	local loads = model_loader.model_loads

	if loads:Join(path, callback, {mesh = callback2, on_fail = on_fail}) then
		return true
	end

	local data = loads:Get(path)

	if data then
		if callback2 then
			for _, entry in ipairs(data) do
				callback2{mesh = entry.mesh, material = entry.material}
			end
		end

		callback(data)
		return true
	end

	event.Call("PreLoad3DModel", path)
	loads:Begin(path, callback, {mesh = callback2, on_fail = on_fail})

	-- a lua model asset (a file or a virtual one) is built from its descriptor with the default options. the
	-- position, rotation and scale of its primitives are for the model component, they are not applied here
	if path:ends_with(".lua") then
		local entry = assets.GetModel(path)

		if not entry then
			fail_model_load(loads, path, "unable to resolve model asset")
			return true
		end

		if entry.error then
			fail_model_load(loads, path, entry.error)
			return true
		end

		local ok, err = xpcall(
			function()
				local out = {}

				for _, primitive in ipairs(entry.value.create_primitives({})) do
					local ext = {mesh = primitive.mesh, material = primitive.material}
					loads:Emit(path, "mesh", ext)
					list.insert(out, ext)
				end

				loads:Finish(path, out)
			end,
			debug.traceback
		)

		if not ok then fail_model_load(loads, path, err) end

		return true
	end

	resource.Download(path, nil, path:ends_with(".mdl")):Then(function(full_path)
		local out = {}

		local function mesh_callback(mesh, material)
			local ext = {mesh = mesh, material = material}
			loads:Emit(path, "mesh", ext)
			list.insert(out, ext)
		end

		local function physics_callback(physics)
			out.physics = physics
		end

		local function skeleton_callback(skeleton)
			out.skeleton = skeleton
		end

		local decode_callback = model_loader.FindModelDecoder(path)

		if decode_callback then
			local function on_error(task, err)
				fail_model_load(loads, path, err)
			end

			local thread = tasks.CreateTask(nil, nil, nil, on_error)
			thread:SetName(path)

			function thread:OnStart()
				decode_callback(path, full_path, mesh_callback, physics_callback, skeleton_callback)
				loads:Finish(path, out)
			end

			vfs.Prefetch(full_path, function()
				utility.PushTimeWarning()
				thread:Start()
				utility.PopTimeWarning("decoding " .. path, 0.5)
			end)
		else
			fail_model_load(loads, path, "unknown format " .. path)
		end
	end):Catch(function(reason)
		fail_model_load(loads, path, reason)
	end)

	return true
end

import.loaded["goluwa/render3d/model_loader.lua"] = model_loader
import("goluwa/render3d/model_decoders/mdl.lua")
model_loader.AddModelDecoder("cgf", import("goluwa/render3d/model_decoders/cgf.lua").DecodeModel)
import("goluwa/render3d/model_decoders/bsp.lua")
import("goluwa/cry_engine/cry_engine.lua")
return model_loader
