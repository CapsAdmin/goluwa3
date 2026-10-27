local animations = import("lua/animations.lua")
local files = {
	import("lua/animations/actions.lua"),
	import("lua/animations/impulses.lua"),
	import("lua/animations/block.lua"),
	import("lua/animations/air.lua"),
	import("lua/animations/roll.lua"),
	import("lua/animations/seat.lua"),
}

for _, definitions in ipairs(files) do
	for name, def in pairs(definitions) do
		animations.Register(name, def)
	end
end

return animations
