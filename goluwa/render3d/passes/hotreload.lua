for k, v in pairs(import.loaded) do
	if k:find("goluwa/render3d") then
		import.loaded[k] = nil
		print(k)
	end
end

local render3d = import("goluwa/render3d/render3d.lua")
render3d.Initialize()
