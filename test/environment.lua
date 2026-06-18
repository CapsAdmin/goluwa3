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
			local requests = self.mouse_trap_requests

			if requests and #requests > 0 then return requests[#requests].trapped end

			return self.mouse_trapped
		end

		function window:SetMouseTrapped(trapped)
			self.mouse_trapped = not not trapped
		end

		function window:PushMouseTrapRequest(id, trapped)
			self.mouse_trap_requests = self.mouse_trap_requests or {}
			self.mouse_trap_request_lookup = self.mouse_trap_request_lookup or {}
			local requests = self.mouse_trap_requests
			local lookup = self.mouse_trap_request_lookup
			local index = lookup[id]

			if index then
				table.remove(requests, index)

				for i = index, #requests do
					lookup[requests[i].id] = i
				end
			end

			requests[#requests + 1] = {id = id, trapped = not not trapped}
			lookup[id] = #requests
		end

		function window:PopMouseTrapRequest(id)
			local lookup = self.mouse_trap_request_lookup

			if not lookup then return end

			local index = lookup[id]

			if not index then return end

			local requests = self.mouse_trap_requests
			table.remove(requests, index)
			lookup[id] = nil

			for i = index, #requests do
				lookup[requests[i].id] = i
			end

			if #requests == 0 then
				self.mouse_trap_requests = nil
				self.mouse_trap_request_lookup = nil
			end
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
local T = import("goluwa/test.lua")
local gmod_initialized_files = {}
T.TestGmod = function(name, cb, gamemode)
	gamemode = gamemode or "sandbox"
	return T.Test(name, function()
		local file_name = T.GetCurrentTestFileName() or "<unknown>"

		if not gmod_initialized_files[file_name] then
			test_render.InitGMod2D(gamemode, true)
			gmod_initialized_files[file_name] = true
		end

		return cb()
	end)
end
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
