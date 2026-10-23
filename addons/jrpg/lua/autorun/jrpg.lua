local Entity = import("goluwa/entities/entity.lua")
local Rpg = import("lua/components/rpg.lua")
Entity.RegisterComponent("rpg", Rpg)
Entity.RegisterComponent("status_effects", import("lua/components/status_effects.lua"))
Entity.RegisterComponent("magic_projectile", import("lua/components/magic_projectile.lua"))
import("lua/jrpg/jrpg.lua")
import("lua/jrpg/surface_hazards.lua")

if RENDER_3D then import("lua/jrpg/animation.lua") end
