local event = import("goluwa/event.lua")
local vfs = import("goluwa/vfs.lua")

event.AddListener("ParseSpriteSheet", "source_loader", function(path)
	if not path:lower():find("%.vtf$") then return end

	local data = vfs.Read(path)

	return data and import("lua/codecs/vtf.lua").ParseSheet(data)
end)
