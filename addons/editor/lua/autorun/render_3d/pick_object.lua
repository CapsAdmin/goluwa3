local event = import("goluwa/event.lua")
local assets = import("goluwa/assets.lua")

event.AddListener("PickObject", "picker", function(what, callback, options)
	local picker = import("lua/picker.lua")

	if what == "material" then
		picker.PickAsset("materials", nil, function(path)
			callback(assets.GetMaterial(path))
		end)
	elseif what == "texture" then
		picker.PickAsset("textures", nil, function(path)
			callback(assets.GetTexture(path))
		end)
	elseif what == "asset" then
		picker.PickAsset(options.category, options.path, callback)
	end
end)
