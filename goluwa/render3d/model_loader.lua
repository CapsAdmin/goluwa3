local callback = require("callback")
local event = require("event")
local resource = require("resource")
local utility = require("utility")
local tasks = require("tasks")
local model_loader = {}
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
model_loader.model_loader_cb = utility.CreateCallbackThing(model_loader.model_cache)

function model_loader.LoadModel(path, callback, callback2, on_fail)
	local cb = model_loader.model_loader_cb

	if cb:check(path, callback, {mesh = callback2, on_fail = on_fail}) then
		return true
	end

	local data = cb:get(path)

	if data then
		if callback2 then
			for _, mesh in ipairs(data) do
				callback2(mesh)
			end
		end

		callback(data)
		return true
	end

	event.Call("PreLoad3DModel", path)
	cb:start(path, callback, {mesh = callback2, on_fail = on_fail})

	resource.Download(path, nil, path:ends_with(".mdl")):Then(function(full_path)
		local out = {}
		local thread = tasks.CreateTask()
		thread:SetName(path)

		local function mesh_callback(mesh)
			cb:callextra(path, "mesh", mesh)
			list.insert(out, mesh)
		end

		local decode_callback = model_loader.FindModelDecoder(path)

		if decode_callback then
			function thread:OnStart()
				decode_callback(path, full_path, mesh_callback)
				cb:stop(path, out)
			end

			utility.PushTimeWarning()
			thread:Start()
			utility.PopTimeWarning("decoding " .. path, 0.5)
		else
			cb:callextra(path, "on_fail", "unknown format " .. path)
		end
	end):Catch(function(reason)
		cb:callextra(path, "on_fail", reason)
	end)

	return true
end

package.loaded["render3d.model_loader"] = model_loader
require("render3d.model_decoders.mdl")
require("render3d.model_decoders.bsp")
return model_loader
