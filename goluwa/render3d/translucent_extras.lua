local render3d = import("goluwa/render3d/render3d.lua")
local translucent_extras = {}

-- geometry the translucent passes draw besides the scene's models, in the order it is drawn. an
-- extra is a table with
--   name: the prefix of its pass names, <name>_moments and <name>_accumulate
--   IsActive(): whether it draws this frame
--   BuildPasses(): the configs of those two passes, they draw inside the translucent passes of the
--     same stage after the models
--   Draw(pipeline, cmd): draws into the pipeline of a stage
translucent_extras.list = {
	import("goluwa/render3d/precipitation.lua"),
}

-- stage is "moments" or "accumulate"
function translucent_extras.Draw(stage, cmd)
	for _, extra in ipairs(translucent_extras.list) do
		if extra.IsActive() then
			extra.Draw(render3d.pipelines[extra.name .. "_" .. stage], cmd)
		end
	end
end

return translucent_extras
