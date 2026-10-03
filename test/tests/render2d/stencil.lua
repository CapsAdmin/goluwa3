local T = import("test/environment.lua")
local ffi = require("ffi")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local fs = import("goluwa/filesystem/fs.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Color = import("goluwa/structs/color.lua")

T.Test2D("Graphics render2d SetStencilMode and GetStencilMode", function()
	render2d.SetStencilMode("write", 5)
	local mode, ref = render2d.GetStencilMode()
	T(mode)["=="]("write")
	T(ref)["=="](5)
	render2d.SetStencilMode("none")
	mode, ref = render2d.GetStencilMode()
	T(mode)["=="]("none")
end)

T.Test2D("Graphics render2d SetDepthMode and GetDepthMode", function()
	render2d.SetDepthMode("less", true)
	local mode, write = render2d.GetDepthMode()
	T(mode)["=="]("less")
	T(write)["=="](true)
	render2d.SetDepthMode("none", false)
	mode, write = render2d.GetDepthMode()
	T(mode)["=="]("none")
	T(write)["=="](false)
end)

T.Test2D("Graphics render2d stencil rendering", function()
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	render2d.SetStencilMode("test", 1)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.SetStencilMode("test_inverse", 1)
	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(125, 125, 50, 50)
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 0, 1, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d PushStencilMask and PopStencilMask", function()
	render2d.ClearStencil(0)
	render2d.PushStencilMask()
	render2d.DrawRect(200, 200, 100, 100)
	render2d.BeginStencilTest()
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(200, 200, 100, 100)
	render2d.PushStencilMask()
	render2d.DrawRect(225, 225, 50, 50)
	render2d.BeginStencilTest()
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(200, 200, 100, 100)
	render2d.PopStencilMask()
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {250, 250},
			color = {1, 0, 0, 1},
		}
		T.AssertScreenPixel{
			pos = {210, 210},
			color = {1, 1, 1, 1},
		}
		T.AssertScreenPixel{
			pos = {190, 190},
			color = {0, 0, 0, 1},
		}
	end
end)

T.Test2DFrames(
	"Graphics render2d instanced stencil clear across frames",
	8,
	function(width, height, frame)
		render2d.SetRectBatchMode("instanced")
		render2d.SetColor(0.08, 0.1, 0.16, 1)
		render2d.DrawRect(0, 0, width, height)
		render2d.ClearStencil(0)
		render2d.PushStencilMask()
		render2d.SetColor(1, 1, 1, 1)
		render2d.PushBorderRadius(18)
		render2d.DrawRect(96, 96, 96, 72)
		render2d.PopBorderRadius()
		render2d.BeginStencilTest()
		render2d.SetColor(0.9, 0.3, 0.15, 1)
		render2d.DrawRect(72 + frame, 108, 96, 40)
		render2d.PopStencilMask()
		render2d.SetRectBatchMode("replay")
	end,
	function(width, height, frame)
		T.AssertScreenPixel{
			pos = {24, 24},
			color = {0.08, 0.1, 0.16, 1},
			tolerance = 0.15,
		}
		T.AssertScreenPixel{
			pos = {120, 124},
			color = {0.9, 0.3, 0.15, 1},
			tolerance = 0.2,
		}
	end
)

T.Test2D("Graphics render2d stencil greater mode with reference 2", function()
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	render2d.SetStencilMode("write", 3)
	render2d.DrawRect(150, 150, 50, 50)
	render2d.SetStencilMode("greater", 2)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 125, 125)
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil greater mode with reference 0 (mapped to test_inverse)", function()
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	render2d.SetStencilMode("greater", 0)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - write and test", function()
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 5)
	render2d.DrawRect(100, 100, 50, 50)
	render2d.SetStencilMode("test", 5)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - mask_write and mask_test", function()
	render2d.ClearStencil(0)
	render2d.PushStencilMask()
	render2d.DrawRect(100, 100, 50, 50)
	render2d.BeginStencilTest()
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - mask_write, mask_test, mask_decrement", function()
	render2d.ClearStencil(0)
	render2d.PushStencilMask()
	render2d.DrawRect(100, 100, 50, 50)
	render2d.BeginStencilTest()
	render2d.PushStencilMask()
	render2d.DrawRect(125, 125, 50, 50)
	render2d.BeginStencilTest()
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(110, 110, 50, 50)
	render2d.PopStencilMask()
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {140, 140},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {115, 115},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - all basic modes", function()
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 3)
	render2d.DrawRect(100, 100, 50, 50)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(150, 150, 50, 50)
	render2d.SetStencilMode("greater", 2)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(125, 125, 50, 50)
	render2d.SetStencilMode("test_inverse", 3)
	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(175, 175, 50, 50)
	render2d.SetStencilMode("none")
	return function()
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {130, 130},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
		T.AssertScreenPixel{
			pos = {180, 180},
			color = {0, 0, 1, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil test matching love.graphics.stencil pattern", function(width, height)
	render2d.ClearStencil(0)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(16, 16, width - 32, height - 32)
	render2d.SetBlendPreset("additive")
	render2d.SetStencilMode("test", 1)
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(50, 50, 100, 100)
	render2d.SetStencilMode("none")
	render2d.SetBlendPreset("alpha")
	return function()
		T.AssertScreenPixel{pos = {100, 100}, color = {1, 0, 0, 1}, tolerance = 0.08}
		T.AssertScreenPixel{pos = {5, 5}, color = {0, 0, 0, 1}, tolerance = 0.08}
	end
end)
