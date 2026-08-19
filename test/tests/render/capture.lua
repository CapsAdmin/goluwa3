local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")

-- Mid-frame capture: draw red (left), capture, draw blue (right). A correct mid-frame
-- capture shows red-left + clear-right (the blue rect is drawn after the capture).
T.Test2D("render.Capture reads framebuffer mid-frame", function(w, h)
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(0, 0, w / 2, h)

	local cap = render.Capture()
	assert(cap, "render.Capture should return a texture mid-frame")
	assert(cap.width == w and cap.height == h, "capture should match the target size")

	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(w / 2, 0, w / 2, h)

	local mid_y = math.floor(h / 2)

	-- Left half was drawn red before the capture
	T.AssertTexturePixel{
		tex = cap,
		pos = {math.floor(w / 4), mid_y},
		color = function(r, g, b, a)
			return r > 0.6 and g < 0.4 and b < 0.4
		end,
		msg = "mid-left should be red",
	}
	-- Right half was still the clear color at capture time (blue is drawn after)
	T.AssertTexturePixel{
		tex = cap,
		pos = {math.floor(w * 3 / 4), mid_y},
		color = function(r, g, b, a)
			return b < 0.8
		end,
		msg = "mid-right should not be blue (drawn after capture)",
	}
end)

T.Test("render.Capture returns nil outside a render pass", function()
	test_render.Init()
	local cap = render.Capture()
	assert(cap == nil, "render.Capture should return nil when not inside a render pass")
end)
