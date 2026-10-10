local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local vfs = import("goluwa/vfs.lua")
local outfit = import("lua/outfit.lua")

T.Test("The local outfit is saved with the default body and visor, stays local and keeps edits", function()
	local name = outfit.LocalName
	local path = prefab.GetPath(name)
	local backup = vfs.Read(path)
	prefab.definitions[name] = nil
	os.remove(path)
	T(outfit.Exists(name))["=="](false)
	T(outfit.LoadLocal())["=="](name)
	T(vfs.IsFile(path))["=="](true)
	T(prefab.Get(name).local_only)["=="](true)
	prefab.definitions[name] = nil
	local instance = Entity.New{prefab = {Path = outfit.LoadLocal()}}
	local visor = instance.prefab:GetNode("visor")
	local body = instance.prefab:GetNode("body")
	T(visor ~= nil)["=="](true)
	T(visor:GetParent())["=="](instance)
	T(visor.transform:GetAttachment())["=="]("head")
	T(visor.transform:GetPosition():GetLength())["~"](outfit.VisorDistance)
	T(body:GetParent())["=="](instance)
	T(body.transform:GetAttachment())["=="]("body")
	T(instance.transform:GetAttachment())["=="]("root")
	instance:Remove()
	prefab.Get(name).entities[2].properties.Name = "edited"
	outfit.LoadLocal()
	T(prefab.Get(name).entities[2].properties.Name)["=="]("edited")
	prefab.definitions[name] = nil

	if backup then vfs.Write(path, backup) else os.remove(path) end
end)

T.Test("Outfit names of other players are valid prefab names", function()
	T(outfit.GetName("127.0.0.1:5000"))["=="]("outfit_127.0.0.1_5000")
end)
