-- geometry the gbuffer pass draws besides the scene's models, in the order it is drawn. an extra
-- is a table with
--   name: the name of its pass, render3d.pipelines[name] is its pipeline
--   BuildPass(gbuffer_pass): the pass config, drawn inside the gbuffer's render pass. an extra that
--     draws with one of the gbuffer's own pipelines names it and has no pass of its own
--   PreDraw(cmd): before that render pass begins, for compute work
--   Draw(pipeline, cmd): inside it, after the models are flushed
-- a bundle that leaves the pass out has no pipeline, and the extra is skipped there
return {
	import("goluwa/render3d/scatter.lua"),
}
