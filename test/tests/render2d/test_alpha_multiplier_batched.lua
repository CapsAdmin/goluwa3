local T = import("test/environment.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")

T.Test2D("Graphics render2d alpha multiplier instanced batch rendering", function()
	render2d.SetRectBatchMode("instanced")
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(0.5)
	render2d.DrawRect(20, 20, 64, 64)
	render2d.SetAlphaMultiplier(1)
	T(render2d.GetAlphaMultiplier())["=="](1.0)
	return function()
		T.AssertScreenPixel{
			pos = {40, 40},
			color = {0.736, 0.736, 0.736, 0.5},
			tolerance = 0.02,
		}
	end
end)

T.Test2D("Graphics render2d alpha multiplier replay batch rendering", function()
	render2d.SetRectBatchMode("replay")
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(0.5)
	render2d.DrawRect(20, 20, 64, 64)
	render2d.SetAlphaMultiplier(1)
	T(render2d.GetAlphaMultiplier())["=="](1.0)
	return function()
		T.AssertScreenPixel{
			pos = {40, 40},
			color = {0.736, 0.736, 0.736, 0.5},
			tolerance = 0.02,
		}
	end
end)

T.Test2D("Graphics render2d alpha multiplier captured in batch state", function()
	render2d.SetRectBatchMode("instanced")
	render2d.SetColor(1, 1, 1, 1)
	render2d.SetAlphaMultiplier(0.25)
	render2d.DrawRect(20, 20, 64, 64)
	render2d.SetAlphaMultiplier(1.0)
	local state = render2d.GetBatchState()
	T(state.pending_draws)["=="](1)
	T(#state.segments)["=="](1)
	local entry = state.segments[1].entries[1]
	T(entry.state.alpha_multiplier)["~"](0.25)
	render2d.FlushBatches("manual")
	return function()
		T.AssertScreenPixel{
			pos = {40, 40},
			color = {0.537, 0.537, 0.537, 0.25},
			tolerance = 0.02,
		}
	end
end)
