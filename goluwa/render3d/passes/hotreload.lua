for k, v in pairs(import.loaded) do
	if k:find("goluwa/render3d") == 1 then import.loaded[k] = nil end
end

assert(loadfile("goluwa/render3d/render3d.lua"))()
