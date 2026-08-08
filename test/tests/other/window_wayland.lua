local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("wayland SetSize requests compositor resize", function()
	if jit.os ~= "Linux" then
		return T.Unavailable("Wayland backend tests require Linux")
	end

	local ffi = require("ffi")
	local wayland = import("goluwa/bindings/wayland/core.lua")
	local apply_wayland_backend = import("goluwa/window_implementations/linux_wayland.lua")
	local META = {}
	apply_wayland_backend(META)
	local geometry_calls = {}
	local commit_count = 0
	local listener
	local fake_toplevel = {
		add_listener = function(_, callbacks)
			listener = callbacks
		end,
	}
	local fake_window = {
		xdg_surface = {
			set_window_geometry = function(_, x, y, width, height)
				geometry_calls[#geometry_calls + 1] = {x, y, width, height}
			end,
		},
		xdg_toplevel = fake_toplevel,
		surface_proxy = {
			commit = function()
				commit_count = commit_count + 1
			end,
		},
		display = nil,
		cached_size = Vec2(800, 600),
		cached_fb_size = Vec2(800, 600),
		width = 800,
		height = 600,
		events = {},
		_ptr = 424242,
	}
	wayland._active_windows[fake_window._ptr] = fake_window
	fake_window.setup_xdg_toplevel_listener = META.setup_xdg_toplevel_listener
	fake_window.SetSize = META.SetSize
	fake_window:setup_xdg_toplevel_listener()
	fake_window:SetSize(Vec2(1280.9, 719.2))
	T(geometry_calls[1][1])["=="](0)
	T(geometry_calls[1][2])["=="](0)
	T(geometry_calls[1][3])["=="](1280)
	T(geometry_calls[1][4])["=="](719)
	T(commit_count)["=="](1)
	T(fake_window.width)["=="](1280)
	T(fake_window.height)["=="](719)
	-- Verify no min/max size constraints are set (they prevent compositor resizing)
	-- Simulate compositor configure callback with the new size
	listener.configure(ffi.cast("void*", fake_window._ptr), fake_toplevel, 1280, 719, nil)
	wayland._active_windows[fake_window._ptr] = nil
	T(fake_window.events[1].type)["=="]("window_resize")
	T(fake_window.events[1].width)["=="](1280)
	T(fake_window.events[1].height)["=="](719)
end)
