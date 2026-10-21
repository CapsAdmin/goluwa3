local render3d = import("goluwa/render3d/render3d.lua")
local translucent_extras = {}
translucent_extras.list = {
	import("goluwa/render3d/particles.lua"),
}

function translucent_extras.Draw(stage, cmd)
	for _, extra in ipairs(translucent_extras.list) do
		if extra.IsActive() then
			extra.Draw(render3d.pipelines[extra.name .. "_" .. stage], cmd)
		end
	end
end

return translucent_extras
