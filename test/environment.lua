require("goluwa.global_environment")
local vfs = import("goluwa/vfs.lua")
local system = import("goluwa/system.lua")
local Vec2 = import("goluwa/structs/vec2.lua")
import.loadfile = vfs.LoadFile
vfs.Mount("os:" .. vfs.GetStorageDirectory("working_directory"))
vfs.MountStorageDirectories()
local vk = import("goluwa/bindings/vk.lua")
local has_rendering = false

if pcall(vk.find_library) then has_rendering = true end

do
	import.loaded["goluwa/bindings/clipboard.lua"] = {
		Get = function()
			return clipboard
		end,
		Set = function(text)
			clipboard = tostring(text)
		end,
	}
end

do
	if not system.GetWindows()[1] then
		local window = {
			title = "",
			position = Vec2(0, 0),
			size = Vec2(512, 512),
			framebuffer_size = Vec2(512, 512),
			mouse_position = Vec2(0, 0),
			mouse_delta = Vec2(0, 0),
			cursor = "arrow",
			mouse_trapped = false,
			focused = true,
		}

		function window:GetTitle()
			return self.title
		end

		function window:SetTitle(title)
			self.title = title or ""
		end

		function window:GetPosition()
			return self.position
		end

		function window:SetPosition(pos)
			self.position = pos
		end

		function window:GetSize()
			return self.size
		end

		function window:SetSize(size)
			self.size = size
			self.framebuffer_size = Vec2(size)
		end

		function window:GetFramebufferSize()
			return self.framebuffer_size
		end

		function window:SetFramebufferSize(size)
			self.framebuffer_size = size
		end

		function window:GetMousePosition()
			return self.mouse_position
		end

		function window:SetMousePosition(pos)
			self.mouse_position = pos
		end

		function window:GetMouseDelta()
			return self.mouse_delta
		end

		function window:SetMouseDelta(delta)
			self.mouse_delta = delta
		end

		function window:GetCursor()
			return self.cursor
		end

		function window:SetCursor(cursor)
			self.cursor = cursor
		end

		function window:GetMouseTrapped()
			return self.mouse_trapped
		end

		function window:SetMouseTrapped(trapped)
			self.mouse_trapped = not not trapped
		end

		function window:IsFocused()
			return self.focused
		end

		function window:SetFocused(focused)
			self.focused = not not focused
		end

		system.RegisterWindow(window)
	end
end

local test_render = import("test/test_render.lua")
local T = import("goluwa/helpers/test.lua")
T.Test2D = function(name, cb)
	if not has_rendering then
		return T.Unavailable("Vulkan library not available, skipping render2d tests.")
	end

	return T.Test(name, function()
		test_render.Draw2D(cb)
	end)
end
T.Test2DFrames = function(name, frame_count, cb, after_frame)
	if not has_rendering then
		return T.Unavailable("Vulkan library not available, skipping render2d tests.")
	end

	return T.Test(name, function()
		test_render.Draw2DFrames(frame_count, cb, after_frame)
	end)
end
T.Test3D = function(name, cb)
	if not has_rendering then
		return T.Unavailable("Vulkan library not available, skipping render3d tests.")
	end

	return T.Test(name, function()
		test_render.Draw3D(cb)
	end)
end
return T
