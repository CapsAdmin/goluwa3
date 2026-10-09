local objects = import("goluwa/objects/objects.lua")
local META = objects.CreateTemplate("brush_side")

function META:ShouldSerializeEntity()
	return false
end

return META:Register()
