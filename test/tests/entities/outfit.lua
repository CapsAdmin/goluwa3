local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local prefab = import("goluwa/entities/prefab.lua")
local vfs = import("goluwa/vfs.lua")
local outfit = import("lua/outfit.lua")

T.Test("The local outfit is saved with the default body and visor, stays local and keeps edits", function()
	local name = outfit.DefaultName
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
	T(body.transform:GetAttachment())["=="]("root")
	T(body.script ~= nil)["=="](true)
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

T.Test("The default outfit squashes its own body when the player crouches", function()
	local player = Entity.New{transform = {}}
	player.player_avatar = {crouch_alpha = 1}
	prefab.Register("test_outfit_crouch", outfit.GetDefault())
	local instance = Entity.New{Parent = player, prefab = {Path = "test_outfit_crouch"}}
	local body = instance.prefab:GetNode("body")
	T(body.script.Error)["=="](nil)
	body.script.module.Update(body, 0.016)
	T(body.transform:GetScale().y)["~"](0.5, 1e-6)
	T(body.transform:GetPosition().y)["~"](outfit.BodyHeight * 0.25, 1e-6)
	player.player_avatar.crouch_alpha = 0
	body.script.module.Update(body, 0.016)
	T(body.transform:GetScale().y)["~"](1, 1e-6)
	instance:Remove()
	player:Remove()
	prefab.definitions.test_outfit_crouch = nil
end)
