do
	return
end

local Texture = require("graphics.texture")
local render2d = require("graphics.render2d")
local path = "/home/caps/.steam/steam/steamapps/common/GarrysMod/garrysmod/garrysmod_dir.vpk/materials/gm_construct/grass1.vtf"
local tex = Texture.New({
	path = path,
})

function events.Draw2D.test(dt)
	render2d.SetTexture(tex)
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(0, 0, 512, 512)
end
