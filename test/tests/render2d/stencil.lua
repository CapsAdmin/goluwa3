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
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Draw a rectangle into the stencil buffer with value 1
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	-- Now draw a green rectangle that only passes where stencil is 1
	render2d.SetStencilMode("test", 1)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50) -- Overlaps top-left of the first rect
	-- Draw a blue rectangle that only passes where stencil is NOT 1
	render2d.SetStencilMode("test_inverse", 1)
	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(125, 125, 50, 50) -- Overlaps bottom-right of the first rect
	render2d.SetStencilMode("none")
	return function()
		-- (110, 110) should be green (overlap of red write and green test)
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (80, 80) should be black/background (green test failed)
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
		-- (160, 160) should be blue (test_inverse passed, stencil was 0)
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 0, 1, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d PushStencilMask and PopStencilMask", function()
	render2d.ClearStencil(0)
	-- Level 0
	render2d.PushStencilMask()
	render2d.DrawRect(200, 200, 100, 100) -- Writes 1 where drawn
	render2d.BeginStencilTest() -- test == 1
	render2d.SetColor(1, 1, 1, 1)
	render2d.DrawRect(200, 200, 100, 100) -- Should draw white
	-- Nested mask
	render2d.PushStencilMask()
	render2d.DrawRect(225, 225, 50, 50) -- Writes 2 where drawn (if it was 1)
	render2d.BeginStencilTest() -- test == 2
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(200, 200, 100, 100) -- Should draw red only in the 50x50 area
	render2d.PopStencilMask()
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		-- Center should be red
		T.AssertScreenPixel{
			pos = {250, 250},
			color = {1, 0, 0, 1},
		}
		-- Outside center but inside white box should be white
		T.AssertScreenPixel{
			pos = {210, 210},
			color = {1, 1, 1, 1},
		}
		-- Outside everything should be black
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

-- Test ClearStencil with various stencil modes and DrawRect
T.Test2D("Graphics render2d stencil greater mode with reference 2", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Draw a rectangle that writes value 1 to stencil buffer
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	-- Draw another rectangle that writes value 3 to stencil buffer
	render2d.SetStencilMode("write", 3)
	render2d.DrawRect(150, 150, 50, 50)
	-- Now draw a green rectangle that only passes where reference > stencil (i.e., 2 > stencil)
	render2d.SetStencilMode("greater", 2)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 125, 125) -- Covers both written areas
	render2d.SetStencilMode("none")
	return function()
		-- (110, 110) should be green (ref 2 > stencil 1)
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (160, 160) should be black (ref 2 not > stencil 3)
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil greater mode with reference 0 (mapped to test_inverse)", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Draw a rectangle that writes value 1 to stencil buffer
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(100, 100, 50, 50)
	-- Now draw a green rectangle that only passes where reference != stencil (due to workaround mapping)
	render2d.SetStencilMode("greater", 0)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50) -- Overlaps top-left of the first rect
	render2d.SetStencilMode("none")
	return function()
		-- (110, 110) should be green (ref 0 != stencil 1)
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (80, 80) should be black/background (ref 0 == stencil 0)
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - write and test", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Write value 5 to a rectangle
	render2d.SetStencilMode("write", 5)
	render2d.DrawRect(100, 100, 50, 50)
	-- Test for exact match (should draw only where stencil == 5)
	render2d.SetStencilMode("test", 5)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.SetStencilMode("none")
	return function()
		-- (110, 110) should be green
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (80, 80) should be black
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - mask_write and mask_test", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Push mask write (stencil level 0)
	render2d.PushStencilMask()
	-- Draw a rectangle that increments level 0 where it matches reference (0)
	render2d.DrawRect(100, 100, 50, 50)
	-- Begin stencil test for level 0
	render2d.BeginStencilTest()
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(75, 75, 50, 50)
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		-- (110, 110) should be green (level 0 was incremented to 1)
		T.AssertScreenPixel{
			pos = {110, 110},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (80, 80) should be black
		T.AssertScreenPixel{
			pos = {80, 80},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - mask_write, mask_test, mask_decrement", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Push mask write (stencil level 0)
	render2d.PushStencilMask()
	render2d.DrawRect(100, 100, 50, 50)
	render2d.BeginStencilTest()
	-- Push another mask write (stencil level 1)
	render2d.PushStencilMask()
	render2d.DrawRect(125, 125, 50, 50)
	render2d.BeginStencilTest()
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(110, 110, 50, 50)
	render2d.PopStencilMask()
	render2d.PopStencilMask()
	render2d.SetStencilMode("none")
	return function()
		-- (140, 140) should be green (both levels match)
		T.AssertScreenPixel{
			pos = {140, 140},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (115, 115) should be black (only level 0 matches, not level 1)
		T.AssertScreenPixel{
			pos = {115, 115},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
	end
end)

T.Test2D("Graphics render2d stencil mode operators - all basic modes", function()
	-- Clear stencil to 0
	render2d.ClearStencil(0)
	-- Write value 3 to a rectangle
	render2d.SetStencilMode("write", 3)
	render2d.DrawRect(100, 100, 50, 50)
	-- Test greater than 2 (ref > stencil): passes where stencil < 3? Wait, ref=3, op=greater => 3 > stencil
	-- So passes where stencil is 0,1,2. But our stencil is 3 in the rect, so 3 > 3 is false.
	-- Let's use a different approach: test greater with ref=2, stencil=1 (ref > stencil true)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(150, 150, 50, 50) -- Write 1 at a different location
	-- Now test greater with ref=2: passes where 2 > stencil (i.e., stencil 0 or 1)
	render2d.SetStencilMode("greater", 2)
	render2d.SetColor(0, 1, 0, 1)
	render2d.DrawRect(125, 125, 50, 50) -- Overlaps the rect with stencil=1
	-- Test not equal to 3 (should pass where stencil != 3)
	render2d.SetStencilMode("test_inverse", 3)
	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(175, 175, 50, 50) -- Overlaps the rect with stencil=1 (since 1 != 3)
	render2d.SetStencilMode("none")
	return function()
		-- (160, 160) should be green (ref 2 > stencil 1)
		T.AssertScreenPixel{
			pos = {160, 160},
			color = {0, 1, 0, 1},
			tolerance = 0.1,
		}
		-- (130, 130) should be black (ref 2 not > stencil 0)
		T.AssertScreenPixel{
			pos = {130, 130},
			color = {0, 0, 0, 1},
			tolerance = 0.1,
		}
		-- (180, 180) should be blue (stencil 1 != 3)
		T.AssertScreenPixel{
			pos = {180, 180},
			color = {0, 0, 1, 1},
			tolerance = 0.1,
		}
	end
end)

-- Reproduce exact love.graphics.stencil pattern from addons/love/tests/love2d/graphics.lua
T.Test2D("Graphics render2d stencil test matching love.graphics.stencil pattern", function(width, height)
	-- Clear stencil to 0
	render2d.ClearStencil(0)

	-- Draw mask rectangle with "write" mode (like love.graphics.stencil does)
	render2d.SetStencilMode("write", 1)
	render2d.DrawRect(16, 16, width - 32, height - 32)  -- This writes 1 to stencil inside rect

	-- Set additive blend mode like love test
	render2d.SetBlendPreset("additive")

	-- Set stencil test to equal with ref=1
	render2d.SetStencilMode("test", 1)

	-- Draw a single red rectangle inside the mask
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(50, 50, 100, 100) -- Red rect

	render2d.SetStencilMode("none")
	render2d.SetBlendPreset("alpha")  -- Reset blend mode

	return function()
		-- Pixel inside mask should be red
		T.AssertScreenPixel{pos = {100, 100}, color = {1, 0, 0, 1}, tolerance = 0.08}
		-- Pixel outside mask should be black
		T.AssertScreenPixel{pos = {5, 5}, color = {0, 0, 0, 1}, tolerance = 0.08}
	end
end)
