local T = import("test/environment.lua")
local test_render = import("test/test_render.lua")
local render = import("goluwa/render/render.lua")

test_render.Init()

-- Helper to run imagerendertarget tests in isolation (not inside test_render.Draw2D)
-- because ImageRenderTarget operations can conflict with the swapchain's render context
-- when tests run in parallel.
local function run_irt_test(name, cb)
	return T.Test(name, function()
		local success, err = pcall(cb)
		T(success)["=="](true)
		if not success then
			error(err)
		end
	end)
end

run_irt_test("Graphics imagerendertarget basic creation", function()
	local rt = render.CreateOffscreenRenderTarget{width = 256, height = 256}
	T(rt)["~="](nil)
	local extent = rt:GetExtent()
	T(extent.width)["=="](256)
	T(extent.height)["=="](256)
	rt:Remove()
end)

run_irt_test("Graphics imagerendertarget Clear uses correct command buffer", function()
	test_render.Init2D()
	if render.BeginFrame() then
		local rt = render.CreateOffscreenRenderTarget{width = 128, height = 128}
		-- Clear should not error - it uses the active command buffer from render.GetCommandBuffer()
		rt:Clear(0.5, 0.5, 0.5, 1)
		rt:Remove()
		render.EndFrame()
		T(true)["=="](true)
	end
end)

run_irt_test("Graphics imagerendertarget Clear with depth", function()
	test_render.Init2D()
	if render.BeginFrame() then
		local rt = render.CreateOffscreenRenderTarget{width = 128, height = 128, depth = true}
		rt:Clear(0.3, 0.6, 0.9, 1, 0.5, 0)
		rt:Remove()
		render.EndFrame()
		T(true)["=="](true)
	end
end)

run_irt_test("Graphics imagerendertarget Clear with different colors", function()
	test_render.Init2D()
	if render.BeginFrame() then
		local rt = render.CreateOffscreenRenderTarget{width = 128, height = 128}
		-- Test various clear colors
		rt:Clear(1.0, 0.0, 0.0, 1.0)
		rt:Clear(0.0, 1.0, 0.0, 1.0)
		rt:Clear(0.0, 0.0, 1.0, 1.0)
		rt:Clear(1.0, 1.0, 1.0, 0.5)
		rt:Remove()
		render.EndFrame()
		T(true)["=="](true)
	end
end)

run_irt_test("Graphics imagerendertarget ClearAll with depth and stencil", function()
	test_render.Init2D()
	if render.BeginFrame() then
		local rt = render.CreateOffscreenRenderTarget{width = 128, height = 128, depth = true}
		-- Clear with depth and stencil values
		rt:Clear(0.1, 0.2, 0.3, 0.8, 0.75, 255)
		rt:Remove()
		render.EndFrame()
		T(true)["=="](true)
	end
end)
