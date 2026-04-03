local T = import("test/environment.lua")
local Vec2 = import("goluwa/structs/vec2.lua")

T.Test("wayland SetSize requests compositor resize", function()
	if jit.os ~= "Linux" then return T.Unavailable("Wayland backend tests require Linux") end

	local ffi = require("ffi")
	local wayland = import("goluwa/bindings/wayland/core.lua")
	local apply_wayland_backend = import("goluwa/window_implementations/linux_wayland.lua")
	local META = {}
	apply_wayland_backend(META)
	local geometry_calls = {}
	local min_size_calls = {}
	local max_size_calls = {}
	local commit_count = 0
	local listener
	local fake_toplevel = {
		add_listener = function(_, callbacks)
			listener = callbacks
		end,
		set_min_size = function(_, width, height)
			min_size_calls[#min_size_calls + 1] = {width, height}
		end,
		set_max_size = function(_, width, height)
			max_size_calls[#max_size_calls + 1] = {width, height}
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
	T(min_size_calls[1][1])["=="](1280)
	T(min_size_calls[1][2])["=="](719)
	T(max_size_calls[1][1])["=="](1280)
	T(max_size_calls[1][2])["=="](719)
	T(commit_count)["=="](1)
	T(fake_window.width)["=="](1280)
	T(fake_window.height)["=="](719)
	T(fake_window.pending_size_request.x)["=="](1280)
	T(fake_window.pending_size_request.y)["=="](719)
	listener.configure(ffi.cast("void*", fake_window._ptr), fake_toplevel, 1280, 719, nil)
	wayland._active_windows[fake_window._ptr] = nil
	T(fake_window.pending_size_request)["=="](nil)
	T(min_size_calls[2][1])["=="](0)
	T(min_size_calls[2][2])["=="](0)
	T(max_size_calls[2][1])["=="](0)
	T(max_size_calls[2][2])["=="](0)
	T(commit_count)["=="](2)
	T(fake_window.events[1].type)["=="]("window_resize")
	T(fake_window.events[1].width)["=="](1280)
	T(fake_window.events[1].height)["=="](719)
end)