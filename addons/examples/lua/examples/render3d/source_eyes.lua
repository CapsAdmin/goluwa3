local Vec3 = import("goluwa/structs/vec3.lua")
local Entity = import("goluwa/entities/entity.lua")
local steam = import("goluwa/steam/steam.lua")
local event = import("goluwa/event.lua")
steam.MountSourceGame("gmod")
local entity = Entity.New({Name = "eyes"})
entity:AddComponent("transform")
entity.transform:SetPosition(Vec3(0, 0, 0))
entity:AddComponent("visual")
entity.visual:SetModelPath("models/player/gman_high.mdl")
entity:AddComponent("animator")
entity:AddComponent("eyes")
entity.eyes:SetAutoBlink(true)
local LOOK_INTERVAL = 1.5
local LOOKS = {{0, 0}, {25, 0}, {-25, 0}, {0, 20}, {0, -20}}
local clock = 0

event.AddListener("Update", "source_eyes_example", function(dt)
	clock = clock + dt
	local look = LOOKS[math.floor(clock / LOOK_INTERVAL) % #LOOKS + 1]
	entity.eyes:SetLookYaw(look[1])
	entity.eyes:SetLookPitch(look[2])
end)
