local Entity = import("goluwa/entities/entity.lua")
Entity.RegisterComponent("npc", import("lua/components/npc.lua"))
Entity.RegisterComponent("locomotion", import("lua/components/locomotion.lua"))
import("lua/npcs.lua")
