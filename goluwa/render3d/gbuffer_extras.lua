-- geometry the gbuffer pass draws besides the scene's models, in the order it is drawn. an extra
-- is a table with
--   name: the name of its pass, render3d.pipelines[name] is its pipeline
--   BuildPass(gbuffer_pass): the pass config, drawn inside the gbuffer's render pass
--   PreDraw(cmd): before that render pass begins, for compute work
--   Draw(pipeline, cmd): inside it, after the models are flushed
-- a bundle that leaves the pass out has no pipeline, and the extra is skipped there
return {
	import("goluwa/render3d/grass.lua"),
}
