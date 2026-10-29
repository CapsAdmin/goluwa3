local T = import("test/environment.lua")
local sprites = import("goluwa/render3d/sprites.lua")
local event = import("goluwa/event.lua")

T.Test3D("A sprite batch keeps its world bounds on the sprites that moved", function()
	local batch = sprites.GetBatch(nil, {Additive = true, IgnoreZ = true})

	for i = 1, 3 do
		batch:Add(i * 10, 1, 0, 0.05, 1, 1, 1, 1)
		event.Call("LateUpdate")
		local bounds = batch.entity.visual:GetWorldAABB()
		T(bounds.min_x)["<="](i * 10)
		T(bounds.max_x)[">="](i * 10)
		T(bounds.max_x - bounds.min_x)["<"](1)
	end

	event.Call("LateUpdate")
	batch.entity:Remove()
end)
