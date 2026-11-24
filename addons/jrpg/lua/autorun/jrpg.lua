import("lua/components/rpg.lua")
import("lua/jrpg/jrpg.lua")

local AIController = import("lua/components/ai_controller.lua")
local magic_projectile = import("lua/components/magic_projectile.lua")

function AIController:Cast(position, direction, target, aim, element, amount)
	magic_projectile.Cast(position, self.Owner, direction, target, nil, element, amount)
end
