local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")
local event = import("goluwa/event.lua")
local Panel = import("goluwa/render2d/ui/panel.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

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

local screenshot_results = {}

T.Test2DFrames(
	"Screenshot captures the frame it is called in",
	1,
	function(w, h, frame)
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(0, 0, w, h)
		screenshot_results.called = false

		Screenshot(function(tex)
			screenshot_results.called = true
			local r, g, b = tex:GetPixel(math.floor(w / 2), math.floor(h / 2))
			screenshot_results.pixel = {r, g, b}
		end)
	end,
	function(w, h, frame)
		assert(screenshot_results.called, "Screenshot callback was not called")
		local r, g, b = unpack(screenshot_results.pixel)
		assert(
			r > 200 and g < 50 and b < 50,
			string.format("center pixel should be red, got %d,%d,%d", r, g, b)
		)
	end
)

T.Test2D("Screenshot midframe captures immediately", function(w, h)
	render2d.SetColor(1, 0, 0, 1)
	render2d.DrawRect(0, 0, w / 2, h)
	local cap

	Screenshot(function(tex)
		cap = tex
	end, {midframe = true})

	assert(cap, "midframe Screenshot should call cb synchronously")
	render2d.SetColor(0, 0, 1, 1)
	render2d.DrawRect(w / 2, 0, w / 2, h)
	local mid_y = math.floor(h / 2)
	local r, g, b = cap:GetPixel(math.floor(w / 4), mid_y)
	assert(r > 200 and g < 50 and b < 50, "left half should be red")
	r, g, b = cap:GetPixel(math.floor(w * 3 / 4), mid_y)
	assert(b < 100, "right half should not be blue (drawn after capture)")
end)

T.Test("Screenshot update_events lets UI layout resolve before capture", function()
	test_render.Init2D()
	local old_world = Panel.World
	local test_world = Panel.New{ComponentSet = {"transform", "visual"}}
	test_world.transform:SetSize(Vec2(512, 512))
	Panel.World = test_world
	local container = Panel.New{
		ComponentSet = {"transform", "layout"},
		Size = Vec2(200, 100),
		Direction = "x",
	}
	container:SetParent(test_world)
	local child = Panel.New{
		ComponentSet = {"transform", "layout"},
		MinSize = Vec2(40, 40),
	}
	child:SetParent(container)

	event.AddListener("Draw2D", "screenshot_ui_test", function()
		local size = child.transform:GetSize()
		render2d.SetColor(1, 0, 0, 1)
		render2d.DrawRect(0, 0, size.x, size.y)
	end)

	local results = {}

	Screenshot(
		function(tex)
			results.called = true
			local r, g, b = tex:GetPixel(20, 50)
			results.pixel = {r, g, b}
		end,
		{update_events = 3}
	)

	-- layout must have converged before the capture frame
	assert(child.transform:GetSize().x == 40, "child layout should have resolved")
	assert(child.transform:GetSize().y == 100, "child should be stretched to container height")
	-- the capture is scheduled for the next frame
	event.Call("Update", 1 / 60)
	event.Call("FrameEnd")
	assert(results.called, "Screenshot callback was not called")
	local r, g, b = unpack(results.pixel)
	assert(
		r > 200 and g < 50 and b < 50,
		string.format("laid-out child should be drawn in the capture, got %d,%d,%d", r, g, b)
	)
	event.RemoveListener("Draw2D", "screenshot_ui_test")
	child:Remove()
	container:Remove()
	test_world:Remove()
	Panel.World = old_world
end)
