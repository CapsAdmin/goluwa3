local T = import("test/environment.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fonts = import("goluwa/render2d/fonts.lua")

T.Test2D("sdf font", function()
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 256,
		Unique = true,
	}
	render2d.SetTexture(nil)
	render2d.DrawRect(500, 500, 5, 5)
	render2d.SetColor(1, 1, 1, 1)
	font:DrawText("Hg", 10, 10)
	return function()
		T.AssertScreenPixel{
			pos = {48, 99},
			color = {1, 1, 1, 1},
			tolerance = 0.5,
		}
	end
end)

do
	local font = fonts.New{
		Path = fonts.GetDefaultSystemFontPath(),
		Size = 64,
		Unique = true,
	}

	T.Test2DFrames(
		"sdf font uses rect batching",
		3,
		function(width, height, frame)
			render2d.SetColor(0, 0, 0, 1)
			render2d.DrawRect(0, 0, width, height)

			if frame == 1 then
				font:GetTextSize("RectStats")
				return
			end

			if frame == 2 then
				render2d.SetColor(1, 1, 1, 1)
				font:DrawText("RectStats", 20, 20)
				local state = render2d.GetBatchState()
				T(state.pending_draws)[">"](0)
				T(#state.segments)[">"](0)
			end
		end,
		function(width, height, frame)
			if frame ~= 3 then return end

			local last_flush = render2d.GetBatchState().last_flush
			T((last_flush.instanced_draws or 0))[">"](0)
			T((last_flush.gpu_rect_draw_calls or 0))[">"](0)
			T((last_flush.queued_draws or 0))[">"](0)
		end
	)
end
