-- moves `view` to the ground of a view with a `ground` field: up high first, trace down until the terrain has colliders
local event = import("goluwa/event.lua")
local system = import("goluwa/system.lua")
local trace = import("goluwa/physics/trace.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local locate = {}
function locate.Go(view, v, done)
	local pos = v.Position
	view:SetPosition(Vec3(pos.x, 400, pos.z))
	view:SetRotation(v.Rotation)
	view:SetFOV(v.FOV)
	if not v.Ground then done() return end
	local start = system.GetTime()
	local id = "locate_" .. tostring(v)
	event.AddListener("Update", id, function()
		local hit = trace.RayCast(Vec3(pos.x, 400, pos.z), Vec3(0, -1, 0), 1000)
		if hit then
			event.RemoveListener("Update", id)
			local y = hit.position and hit.position.y or (400 - hit.distance)
			print(string.format("ground at %.0f %.0f is %.1f", pos.x, pos.z, y))
			view:SetPosition(Vec3(pos.x, y + v.Ground, pos.z))
			done()
		elseif system.GetTime() - start > 20 then
			event.RemoveListener("Update", id)
			print("no ground found")
			done()
		end
	end)
end
return locate
