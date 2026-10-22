local Entity = import("goluwa/entities/entity.lua")
Entity.RegisterComponent("rpg", import("lua/components/rpg.lua"))
Entity.RegisterComponent("status_effects", import("lua/components/status_effects.lua"))
Entity.RegisterComponent("magic_projectile", import("lua/components/magic_projectile.lua"))
import("lua/jrpg/jrpg.lua")

if RENDER_3D then import("lua/jrpg/animation.lua") end
