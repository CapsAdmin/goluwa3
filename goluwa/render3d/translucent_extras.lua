local render3d = import("goluwa/render3d/render3d.lua")
local translucent_extras = {}
local particles = import("goluwa/render3d/particles.lua")
translucent_extras.list = {
	particles,
	import("goluwa/render3d/trails.lua"),
	import("goluwa/render3d/surface_effect_sheets.lua"),
}
translucent_extras.post_list = {particles}

function translucent_extras.Draw(stage, cmd)
	for _, extra in ipairs(translucent_extras.list) do
		if extra.IsActive() then
			extra.Draw(render3d.pipelines[extra.name .. "_" .. stage], cmd)
		end
	end
end

function translucent_extras.IsPostActive()
	for _, extra in ipairs(translucent_extras.post_list) do
		if extra.IsPostActive() then return true end
	end

	return false
end

function translucent_extras.DrawPost(cmd)
	for _, extra in ipairs(translucent_extras.post_list) do
		if extra.IsPostActive() then
			extra.Draw(render3d.pipelines[extra.name .. "_post"], cmd)
		end
	end
end

return translucent_extras
