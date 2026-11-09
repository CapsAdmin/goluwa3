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
model_loader.model_loads = utility.CreateLoadCache(model_loader.model_cache, 0.004)
local threaded_decoders = {}
local preloaded = {}
local preload_queue = {}
local preload_head = 1
local preload_in_flight = 0
local PRELOAD_WINDOW = 48

local function pump_preload()
	while preload_in_flight < PRELOAD_WINDOW and preload_head <= #preload_queue do
		local path = preload_queue[preload_head]
		preload_head = preload_head + 1
		local callback = model_loader.FindModelDecoder(path)
		local decoder = threaded_decoders[callback]

		if decoder and not preloaded[path] and not model_loader.model_cache[path] then
			local input, size = decoder.Gather(path, path)
			preloaded[path] = {input = input, size = size, job = thread_pool.Run(decoder.job, input, size)}
			preload_in_flight = preload_in_flight + 1
		end
	end
end

-- Starts the worker jobs of threaded decoders for paths (readable through the vfs) that are about to be loaded,
-- at most PRELOAD_WINDOW unconsumed at a time. A load that never comes keeps its slot.
function model_loader.Preload(paths)
	preload_queue = paths
	preload_head = 1
	pump_preload()
end

function model_loader.AddThreadedDecoder(id, decoder, ext)
	local function callback(
		path,
		full_path,
		mesh_callback,
		physics_callback,
		skeleton_callback,
		bounds_callback
	)
		local entry = preloaded[path]
		local input, size, job

		if entry then
			preloaded[path] = nil
			preload_in_flight = preload_in_flight - 1
			input, size, job = entry.input, entry.size, entry.job
		else
			input, size = decoder.Gather(path, full_path)
			job = thread_pool.Run(decoder.job, input, size)
		end

		pump_preload()
		local meta, blob = job:Await()
		return decoder.Finish(
			path,
			full_path,
			input,
			meta,
			blob,
			mesh_callback,
			physics_callback,
			skeleton_callback,
			bounds_callback
		)
	end

	threaded_decoders[callback] = decoder
	model_loader.AddModelDecoder(id, callback, ext)
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

		local function bounds_callback(min, max)
			out.bounds = {min = min, max = max}
		end

		local decode_callback = model_loader.FindModelDecoder(path)

		if decode_callback then
			local function on_error(task, err)
				fail_model_load(loads, path, err)
			end

			local thread = tasks.CreateTask(nil, nil, nil, on_error)
			thread:SetName(path)

			function thread:OnStart()
				decode_callback(
					path,
					full_path,
					mesh_callback,
					physics_callback,
					skeleton_callback,
					bounds_callback
				)
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
import("goluwa/render3d/model_decoders/gltf.lua")
import("goluwa/render3d/model_decoders/mesh.lua")
import("goluwa/render3d/model_decoders/vmdl_c.lua")
import("goluwa/render3d/model_decoders/vphys_c.lua")
model_loader.AddThreadedDecoder("cgf", import("goluwa/render3d/model_decoders/cgf.lua").Decoder)
import("goluwa/render3d/model_decoders/bsp.lua")
import("goluwa/cry_engine/cry_engine.lua")
return model_loader
