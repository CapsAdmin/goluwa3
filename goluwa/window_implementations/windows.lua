local ffi = require("ffi")
local Vec2 = import("goluwa/structs/vec2.lua")
ffi.cdef([[ 
	void *GetModuleHandleW(const uint16_t *name);
	uint16_t RegisterClassExW(const void *wndclass);
	int UnregisterClassW(const uint16_t *class_name, void *instance);
	void *CreateWindowExW(
		uint32_t ex_style,
		const uint16_t *class_name,
		const uint16_t *window_name,
		uint32_t style,
		int x,
		int y,
		int width,
		int height,
		void *parent,
		void *menu,
		void *instance,
		void *param
	);
	int DestroyWindow(void *hwnd);
	intptr_t DefWindowProcW(void *hwnd, uint32_t msg, uintptr_t wparam, intptr_t lparam);
	int ShowWindow(void *hwnd, int cmd_show);
	int UpdateWindow(void *hwnd);
	int SetWindowTextW(void *hwnd, const uint16_t *text);
	int GetClientRect(void *hwnd, void *rect);
	int GetWindowRect(void *hwnd, void *rect);
	int AdjustWindowRectEx(void *rect, uint32_t style, int menu, uint32_t ex_style);
	int SetWindowPos(void *hwnd, void *insert_after, int x, int y, int cx, int cy, uint32_t flags);
	int PeekMessageW(void *msg, void *hwnd, uint32_t min_filter, uint32_t max_filter, uint32_t remove_msg);
	int TranslateMessage(const void *msg);
	intptr_t DispatchMessageW(const void *msg);
	void *LoadCursorW(void *instance, const uint16_t *cursor_name);
	void *SetCursor(void *cursor);
	int GetCursorPos(void *point);
	int ScreenToClient(void *hwnd, void *point);
	int ClientToScreen(void *hwnd, void *point);
	int SetCursorPos(int x, int y);
	int TrackMouseEvent(void *event_track);
	int ClipCursor(const void *rect);
	void *GetFocus(void);
	int IsIconic(void *hwnd);
	int IsZoomed(void *hwnd);
	void DragAcceptFiles(void *hwnd, int accept);
	uint32_t DragQueryFileW(void *drop, uint32_t index, uint16_t *buffer, uint32_t length);
	void DragFinish(void *drop);
]])
return function(META)
	local user32 = ffi.load("user32")
	local kernel32 = ffi.load("kernel32")
	local shell32 = ffi.load("shell32")
	local base_on_remove = META.OnRemove or META.OnRemoved
	local WNDPROC_T = ffi.typeof("intptr_t (__stdcall *)(void *, uint32_t, uintptr_t, intptr_t)")
	local WNDCLASSEXW_T = ffi.typeof([[struct {
		uint32_t cbSize;
		uint32_t style;
		intptr_t (__stdcall *lpfnWndProc)(void *, uint32_t, uintptr_t, intptr_t);
		int cbClsExtra;
		int cbWndExtra;
		void *hInstance;
		void *hIcon;
		void *hCursor;
		void *hbrBackground;
		const uint16_t *lpszMenuName;
		const uint16_t *lpszClassName;
		void *hIconSm;
	}]])
	local WNDCLASSEXW_BOX_T = ffi.typeof("$[1]", WNDCLASSEXW_T)
	local MSG_T = ffi.typeof([[struct {
		void *hwnd;
		uint32_t message;
		uintptr_t wParam;
		intptr_t lParam;
		uint32_t time;
		struct {
			long x;
			long y;
		} pt;
		uint32_t lPrivate;
	}]])
	local MSG_BOX_T = ffi.typeof("$[1]", MSG_T)
	local POINT_T = ffi.typeof("struct { long x; long y; }")
	local POINT_BOX_T = ffi.typeof("$[1]", POINT_T)
	local RECT_T = ffi.typeof("struct { long left; long top; long right; long bottom; }")
	local RECT_BOX_T = ffi.typeof("$[1]", RECT_T)
	local TRACKMOUSEEVENT_T = ffi.typeof([[struct {
		uint32_t cbSize;
		uint32_t dwFlags;
		void *hwndTrack;
		uint32_t dwHoverTime;
	}]])
	local TRACKMOUSEEVENT_BOX_T = ffi.typeof("$[1]", TRACKMOUSEEVENT_T)
	local UTF16_BUFFER_T = ffi.typeof("uint16_t[?]")
	local active_windows = {}
	local class_name = nil
	local module_instance = nil
	local class_registered = false
	local wndproc_callback = nil
	local cursor_cache = {}
	local cursor_ids = {
		arrow = 32512,
		hand = 32649,
		text_input = 32513,
		crosshair = 32515,
		vertical_resize = 32645,
		horizontal_resize = 32644,
		top_right_resize = 32643,
		bottom_left_resize = 32643,
		top_left_resize = 32642,
		bottom_right_resize = 32642,
		all_resize = 32646,
		no = 32648,
	}
	local bit_band = bit.band
	local bit_rshift = bit.rshift
	local bit_bor = bit.bor
	local constants = {
		CS_HREDRAW = 0x0002,
		CS_VREDRAW = 0x0001,
		CS_OWNDC = 0x0020,
		CW_USEDEFAULT = 0x80000000,
		HTCLIENT = 1,
		PM_REMOVE = 0x0001,
		SIZE_RESTORED = 0,
		SIZE_MINIMIZED = 1,
		SIZE_MAXIMIZED = 2,
		SW_SHOW = 5,
		SW_MINIMIZE = 6,
		SW_RESTORE = 9,
		SW_MAXIMIZE = 3,
		SWP_NOSIZE = 0x0001,
		SWP_NOMOVE = 0x0002,
		SWP_NOZORDER = 0x0004,
		SWP_NOACTIVATE = 0x0010,
		TME_LEAVE = 0x00000002,
		WHEEL_DELTA = 120,
		WM_CLOSE = 0x0010,
		WM_DESTROY = 0x0002,
		WM_MOVE = 0x0003,
		WM_SIZE = 0x0005,
		WM_SETFOCUS = 0x0007,
		WM_KILLFOCUS = 0x0008,
		WM_SETCURSOR = 0x0020,
		WM_CHAR = 0x0102,
		WM_KEYDOWN = 0x0100,
		WM_KEYUP = 0x0101,
		WM_SYSKEYDOWN = 0x0104,
		WM_SYSKEYUP = 0x0105,
		WM_MOUSEMOVE = 0x0200,
		WM_MOUSELEAVE = 0x02A3,
		WM_LBUTTONDOWN = 0x0201,
		WM_LBUTTONUP = 0x0202,
		WM_RBUTTONDOWN = 0x0204,
		WM_RBUTTONUP = 0x0205,
		WM_MBUTTONDOWN = 0x0207,
		WM_MBUTTONUP = 0x0208,
		WM_XBUTTONDOWN = 0x020B,
		WM_XBUTTONUP = 0x020C,
		WM_MOUSEWHEEL = 0x020A,
		WM_MOUSEHWHEEL = 0x020E,
		WM_DROPFILES = 0x0233,
		WS_OVERLAPPED = 0x00000000,
		WS_CAPTION = 0x00C00000,
		WS_SYSMENU = 0x00080000,
		WS_THICKFRAME = 0x00040000,
		WS_MINIMIZEBOX = 0x00020000,
		WS_MAXIMIZEBOX = 0x00010000,
	}
	constants.WS_OVERLAPPEDWINDOW = bit_bor(
		constants.WS_OVERLAPPED,
		constants.WS_CAPTION,
		constants.WS_SYSMENU,
		constants.WS_THICKFRAME,
		constants.WS_MINIMIZEBOX,
		constants.WS_MAXIMIZEBOX
	)
	local virtual_keys = {
		[0x08] = "backspace",
		[0x09] = "tab",
		[0x0D] = "enter",
		[0x1B] = "escape",
		[0x20] = "space",
		[0x21] = "pageup",
		[0x22] = "pagedown",
		[0x23] = "end",
		[0x24] = "home",
		[0x25] = "left",
		[0x26] = "up",
		[0x27] = "right",
		[0x28] = "down",
		[0x2D] = "insert",
		[0x2E] = "delete",
		[0x5B] = "left_super",
		[0x5C] = "right_super",
		[0x70] = "f1",
		[0x71] = "f2",
		[0x72] = "f3",
		[0x73] = "f4",
		[0x74] = "f5",
		[0x75] = "f6",
		[0x76] = "f7",
		[0x77] = "f8",
		[0x78] = "f9",
		[0x79] = "f10",
		[0x7A] = "f11",
		[0x7B] = "f12",
		[0xBA] = "semicolon",
		[0xBB] = "equal",
		[0xBC] = "comma",
		[0xBD] = "minus",
		[0xBE] = "period",
		[0xBF] = "slash",
		[0xC0] = "grave_accent",
		[0xDB] = "left_bracket",
		[0xDC] = "backslash",
		[0xDD] = "right_bracket",
		[0xDE] = "apostrophe",
	}

	local function normalize_cursor_mode(mode)
		if mode == "trapped" then return "hidden" end

		return mode
	end

	local function make_int_resource(id)
		return ffi.cast("const uint16_t*", id)
	end

	local function hwnd_key(hwnd)
		return tonumber(ffi.cast("intptr_t", hwnd))
	end

	local function loword_unsigned(value)
		return bit_band(value, 0xFFFF)
	end

	local function hiword_unsigned(value)
		return bit_band(bit_rshift(value, 16), 0xFFFF)
	end

	local function loword_signed(value)
		local out = loword_unsigned(value)

		if out >= 0x8000 then out = out - 0x10000 end

		return out
	end

	local function hiword_signed(value)
		local out = hiword_unsigned(value)

		if out >= 0x8000 then out = out - 0x10000 end

		return out
	end

	local function codepoint_to_utf8(codepoint)
		if codepoint < 0x80 then
			return string.char(codepoint)
		elseif codepoint < 0x800 then
			return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + (codepoint % 0x40))
		elseif codepoint < 0x10000 then
			return string.char(
				0xE0 + math.floor(codepoint / 0x1000),
				0x80 + (math.floor(codepoint / 0x40) % 0x40),
				0x80 + (codepoint % 0x40)
			)
		end

		return string.char(
			0xF0 + math.floor(codepoint / 0x40000),
			0x80 + (math.floor(codepoint / 0x1000) % 0x40),
			0x80 + (math.floor(codepoint / 0x40) % 0x40),
			0x80 + (codepoint % 0x40)
		)
	end

	local function utf8_to_wide(str)
		str = tostring(str or "")
		local units = {}
		local index = 1

		while index <= #str do
			local byte = str:byte(index)
			local codepoint

			if byte < 0x80 then
				codepoint = byte
				index = index + 1
			elseif byte < 0xE0 then
				codepoint = (byte - 0xC0) * 0x40 + (str:byte(index + 1) - 0x80)
				index = index + 2
			elseif byte < 0xF0 then
				codepoint = (
						byte - 0xE0
					) * 0x1000 + (
						str:byte(index + 1) - 0x80
					) * 0x40 + (
						str:byte(index + 2) - 0x80
					)
				index = index + 3
			else
				codepoint = (
						byte - 0xF0
					) * 0x40000 + (
						str:byte(index + 1) - 0x80
					) * 0x1000 + (
						str:byte(index + 2) - 0x80
					) * 0x40 + (
						str:byte(index + 3) - 0x80
					)
				index = index + 4
			end

			if codepoint < 0x10000 then
				units[#units + 1] = codepoint
			else
				codepoint = codepoint - 0x10000
				units[#units + 1] = 0xD800 + math.floor(codepoint / 0x400)
				units[#units + 1] = 0xDC00 + (codepoint % 0x400)
			end
		end

		local buffer = UTF16_BUFFER_T(#units + 1)

		for i, unit in ipairs(units) do
			buffer[i - 1] = unit
		end

		buffer[#units] = 0
		return buffer
	end

	local function wide_to_utf8(buffer, length)
		local parts = {}
		local index = 0

		while true do
			if length and index >= length then break end

			local unit = tonumber(buffer[index])

			if not length and unit == 0 then break end

			if unit >= 0xD800 and unit <= 0xDBFF then
				local low = tonumber(buffer[index + 1])

				if low and low >= 0xDC00 and low <= 0xDFFF then
					local codepoint = 0x10000 + (unit - 0xD800) * 0x400 + (low - 0xDC00)
					parts[#parts + 1] = codepoint_to_utf8(codepoint)
					index = index + 2
				else
					parts[#parts + 1] = codepoint_to_utf8(unit)
					index = index + 1
				end
			else
				parts[#parts + 1] = codepoint_to_utf8(unit)
				index = index + 1
			end
		end

		return table.concat(parts)
	end

	local function get_cursor_handle(mode)
		mode = normalize_cursor_mode(mode)

		if mode == "hidden" then return nil end

		local handle = cursor_cache[mode]

		if handle ~= nil then return handle end

		local cursor_id = cursor_ids[mode] or cursor_ids.arrow
		handle = user32.LoadCursorW(nil, make_int_resource(cursor_id))

		if handle == nil then
			handle = user32.LoadCursorW(nil, make_int_resource(cursor_ids.arrow))
		end

		cursor_cache[mode] = handle
		return handle
	end

	local function translate_virtual_key(vk, lparam)
		if vk >= 0x41 and vk <= 0x5A then return string.char(vk + 32) end

		if vk >= 0x30 and vk <= 0x39 then return string.char(vk) end

		if vk == 0x10 then
			local scan = bit_band(bit_rshift(lparam, 16), 0xFF)
			return scan == 0x36 and "right_shift" or "left_shift"
		end

		if vk == 0x11 then
			return bit_band(lparam, 0x01000000) ~= 0 and "right_control" or "left_control"
		end

		if vk == 0x12 then
			return bit_band(lparam, 0x01000000) ~= 0 and "right_alt" or "left_alt"
		end

		return virtual_keys[vk] or "unknown"
	end

	local function track_mouse_leave(hwnd)
		local track = TRACKMOUSEEVENT_BOX_T()
		track[0].cbSize = ffi.sizeof(TRACKMOUSEEVENT_T)
		track[0].dwFlags = constants.TME_LEAVE
		track[0].hwndTrack = hwnd
		track[0].dwHoverTime = 0
		user32.TrackMouseEvent(track)
	end

	local function pump_messages()
		local msg = MSG_BOX_T()

		while user32.PeekMessageW(msg, nil, 0, 0, constants.PM_REMOVE) ~= 0 do
			user32.TranslateMessage(msg)
			user32.DispatchMessageW(msg)
		end
	end

	local function push_drop_event(wnd, hdrop)
		local count = shell32.DragQueryFileW(hdrop, 0xFFFFFFFF, nil, 0)
		local paths = {}

		for index = 0, count - 1 do
			local length = shell32.DragQueryFileW(hdrop, index, nil, 0)
			local buffer = UTF16_BUFFER_T(length + 1)
			shell32.DragQueryFileW(hdrop, index, buffer, length + 1)
			paths[#paths + 1] = wide_to_utf8(buffer, length)
		end

		shell32.DragFinish(hdrop)

		if #paths > 0 then
			table.insert(wnd.events, {type = "drop", paths = paths})
		end
	end

	local function window_proc(hwnd, msg, wparam, lparam)
		local wnd = active_windows[hwnd_key(hwnd)]

		if not wnd then return user32.DefWindowProcW(hwnd, msg, wparam, lparam) end

		local wparam_num = tonumber(wparam) or 0
		local lparam_num = tonumber(lparam) or 0

		if msg == constants.WM_CLOSE then
			table.insert(wnd.events, {type = "window_close"})
			return 0
		elseif msg == constants.WM_DESTROY then
			return 0
		elseif msg == constants.WM_SETFOCUS then
			table.insert(wnd.events, {type = "window_focus", focused = true})
			return 0
		elseif msg == constants.WM_KILLFOCUS then
			table.insert(wnd.events, {type = "window_focus", focused = false})
			return 0
		elseif msg == constants.WM_MOVE then
			table.insert(
				wnd.events,
				{
					type = "window_move",
					x = loword_signed(lparam_num),
					y = hiword_signed(lparam_num),
				}
			)
			return 0
		elseif msg == constants.WM_SIZE then
			local size_type = wparam_num
			local width = loword_unsigned(lparam_num)
			local height = hiword_unsigned(lparam_num)

			if size_type == constants.SIZE_MINIMIZED then
				wnd.is_minimized = true
				wnd.is_maximized = false
				table.insert(wnd.events, {type = "window_minimize"})
			else
				local was_maximized = wnd.is_maximized
				wnd.is_minimized = false
				wnd.is_maximized = size_type == constants.SIZE_MAXIMIZED

				if wnd.is_maximized and not was_maximized then
					table.insert(wnd.events, {type = "window_maximize"})
				end

				table.insert(wnd.events, {type = "window_resize", width = width, height = height})
			end

			return 0
		elseif msg == constants.WM_SETCURSOR then
			if loword_unsigned(lparam_num) == constants.HTCLIENT then
				user32.SetCursor(wnd.cursor_handle)
				return 1
			end
		elseif msg == constants.WM_CHAR then
			local code_unit = wparam_num

			if code_unit >= 0xD800 and code_unit <= 0xDBFF then
				wnd.pending_high_surrogate = code_unit
			elseif code_unit >= 0xDC00 and code_unit <= 0xDFFF and wnd.pending_high_surrogate then
				local codepoint = 0x10000 + (wnd.pending_high_surrogate - 0xD800) * 0x400 + (code_unit - 0xDC00)
				wnd.pending_high_surrogate = nil
				table.insert(wnd.events, {type = "char", char = codepoint_to_utf8(codepoint)})
			elseif code_unit >= 32 then
				wnd.pending_high_surrogate = nil
				table.insert(wnd.events, {type = "char", char = codepoint_to_utf8(code_unit)})
			end

			return 0
		elseif msg == constants.WM_KEYDOWN or msg == constants.WM_SYSKEYDOWN then
			table.insert(
				wnd.events,
				{
					type = "key",
					pressed = true,
					is_repeat = bit_band(lparam_num, 0x40000000) ~= 0,
					key = translate_virtual_key(wparam_num, lparam_num),
				}
			)
			return 0
		elseif msg == constants.WM_KEYUP or msg == constants.WM_SYSKEYUP then
			table.insert(
				wnd.events,
				{
					type = "key",
					pressed = false,
					key = translate_virtual_key(wparam_num, lparam_num),
				}
			)
			return 0
		elseif msg == constants.WM_MOUSEMOVE then
			local x = loword_signed(lparam_num)
			local y = hiword_signed(lparam_num)
			local delta_x = x - wnd.last_mouse_pos.x
			local delta_y = y - wnd.last_mouse_pos.y
			wnd.last_mouse_pos.x = x
			wnd.last_mouse_pos.y = y

			if not wnd.mouse_inside then
				wnd.mouse_inside = true
				track_mouse_leave(hwnd)
				table.insert(wnd.events, {type = "cursor_enter"})
			end

			table.insert(
				wnd.events,
				{type = "mouse_move", x = x, y = y, delta_x = delta_x, delta_y = delta_y}
			)
			return 0
		elseif msg == constants.WM_MOUSELEAVE then
			wnd.mouse_inside = false
			table.insert(wnd.events, {type = "cursor_leave"})
			return 0
		elseif msg == constants.WM_LBUTTONDOWN or msg == constants.WM_LBUTTONUP then
			table.insert(
				wnd.events,
				{
					type = "mouse_button",
					button = "button_1",
					pressed = msg == constants.WM_LBUTTONDOWN,
				}
			)
			return 0
		elseif msg == constants.WM_RBUTTONDOWN or msg == constants.WM_RBUTTONUP then
			table.insert(
				wnd.events,
				{
					type = "mouse_button",
					button = "button_2",
					pressed = msg == constants.WM_RBUTTONDOWN,
				}
			)
			return 0
		elseif msg == constants.WM_MBUTTONDOWN or msg == constants.WM_MBUTTONUP then
			table.insert(
				wnd.events,
				{
					type = "mouse_button",
					button = "button_3",
					pressed = msg == constants.WM_MBUTTONDOWN,
				}
			)
			return 0
		elseif msg == constants.WM_XBUTTONDOWN or msg == constants.WM_XBUTTONUP then
			local button = hiword_unsigned(wparam_num) == 1 and "button_4" or "button_5"
			table.insert(
				wnd.events,
				{
					type = "mouse_button",
					button = button,
					pressed = msg == constants.WM_XBUTTONDOWN,
				}
			)
			return 1
		elseif msg == constants.WM_MOUSEWHEEL then
			table.insert(
				wnd.events,
				{
					type = "mouse_scroll",
					delta_x = 0,
					delta_y = hiword_signed(wparam_num) / constants.WHEEL_DELTA,
				}
			)
			return 0
		elseif msg == constants.WM_MOUSEHWHEEL then
			table.insert(
				wnd.events,
				{
					type = "mouse_scroll",
					delta_x = hiword_signed(wparam_num) / constants.WHEEL_DELTA,
					delta_y = 0,
				}
			)
			return 0
		elseif msg == constants.WM_DROPFILES then
			push_drop_event(wnd, ffi.cast("void*", wparam))
			return 0
		end

		return user32.DefWindowProcW(hwnd, msg, wparam, lparam)
	end

	local function ensure_class_registered()
		if class_registered then return end

		module_instance = kernel32.GetModuleHandleW(nil)
		class_name = utf8_to_wide("goluwa_window_class")
		wndproc_callback = WNDPROC_T(window_proc)
		local class_info = WNDCLASSEXW_BOX_T()
		class_info[0].cbSize = ffi.sizeof(WNDCLASSEXW_T)
		class_info[0].style = bit_bor(constants.CS_HREDRAW, constants.CS_VREDRAW, constants.CS_OWNDC)
		class_info[0].lpfnWndProc = wndproc_callback
		class_info[0].cbClsExtra = 0
		class_info[0].cbWndExtra = 0
		class_info[0].hInstance = module_instance
		class_info[0].hIcon = nil
		class_info[0].hCursor = get_cursor_handle("arrow")
		class_info[0].hbrBackground = nil
		class_info[0].lpszMenuName = nil
		class_info[0].lpszClassName = class_name
		class_info[0].hIconSm = nil
		assert(user32.RegisterClassExW(class_info) ~= 0, "RegisterClassExW failed")
		class_registered = true
	end

	local function maybe_unregister_class()
		if not class_registered or next(active_windows) ~= nil then return end

		user32.UnregisterClassW(class_name, module_instance)
		class_registered = false
	end

	function META:Initialize()
		ensure_class_registered()
		self.events = {}
		self.cached_pos = nil
		self.cached_size = nil
		self.cached_fb_size = nil
		self.width = (self.Size and self.Size.x > 0) and self.Size.x or 800
		self.height = (self.Size and self.Size.y > 0) and self.Size.y or 600
		self.last_mouse_pos = Vec2(0, 0)
		self.focused = false
		self.mouse_inside = false
		self.is_minimized = false
		self.is_maximized = false
		self.mouse_captured = false
		self.pending_high_surrogate = nil
		self.cursor_handle = get_cursor_handle(self.Cursor)
		local rect = RECT_BOX_T()
		rect[0].left = 0
		rect[0].top = 0
		rect[0].right = self.width
		rect[0].bottom = self.height
		user32.AdjustWindowRectEx(rect, constants.WS_OVERLAPPEDWINDOW, 0, 0)
		self.title_buffer = utf8_to_wide(self.Title or "no title")
		self.hwnd = user32.CreateWindowExW(
			0,
			class_name,
			self.title_buffer,
			constants.WS_OVERLAPPEDWINDOW,
			constants.CW_USEDEFAULT,
			constants.CW_USEDEFAULT,
			rect[0].right - rect[0].left,
			rect[0].bottom - rect[0].top,
			nil,
			nil,
			module_instance,
			nil
		)
		assert(self.hwnd ~= nil, "CreateWindowExW failed")
		active_windows[hwnd_key(self.hwnd)] = self
		shell32.DragAcceptFiles(self.hwnd, 1)
		self.pending_show = true
		self.focused = false
		self.is_minimized = user32.IsIconic(self.hwnd) ~= 0
		self.is_maximized = user32.IsZoomed(self.hwnd) ~= 0
		return true
	end

	function META:OnUpdate(dt)
		self:SetMouseDelta(Vec2(0, 0))

		if self.pending_show then
			user32.ShowWindow(self.hwnd, constants.SW_SHOW)
			user32.UpdateWindow(self.hwnd)
			self.pending_show = false
			self.focused = user32.GetFocus() == self.hwnd
			self.is_minimized = user32.IsIconic(self.hwnd) ~= 0
			self.is_maximized = user32.IsZoomed(self.hwnd) ~= 0
		end

		pump_messages()
		local events = self.events
		self.events = {}

		for _, event in ipairs(events) do
			if event.type == "key" then
				if event.pressed then
					if event.is_repeat then
						self:OnKeyInputRepeat(event.key, true)
					else
						self:OnKeyInput(event.key, true)
					end
				else
					self:OnKeyInput(event.key, false)
				end
			elseif event.type == "char" then
				self:OnCharInput(event.char)
			elseif event.type == "mouse_button" then
				self:OnMouseInput(event.button, event.pressed)
			elseif event.type == "mouse_move" then
				self:SetMouseDelta(Vec2(event.delta_x, event.delta_y))
				self:OnCursorPosition(Vec2(event.x, event.y))
			elseif event.type == "mouse_scroll" then
				self:OnMouseScroll(Vec2(event.delta_x, event.delta_y))
			elseif event.type == "window_close" then
				self:OnClose()
			elseif event.type == "window_focus" then
				self.focused = event.focused
				self[event.focused and "OnGainedFocus" or "OnLostFocus"](self)
			elseif event.type == "window_move" then
				self.cached_pos = nil
				self:OnPositionChanged(Vec2(event.x, event.y))
			elseif event.type == "window_resize" then
				self.cached_size = nil
				self.cached_fb_size = nil
				local size = Vec2(event.width, event.height)
				self:OnSizeChanged(size:Copy())
				self:OnFramebufferResized(size:Copy())
			elseif event.type == "window_minimize" then
				self:OnMinimize()
			elseif event.type == "window_maximize" then
				self:OnMaximize()
			elseif event.type == "cursor_enter" then
				self:OnCursorEnter()
			elseif event.type == "cursor_leave" then
				self:OnCursorLeave()
			elseif event.type == "drop" then
				self:OnDrop(event.paths)
			end
		end
	end

	function META:OnRemove()
		if not self.hwnd then return end

		if self.mouse_captured then self:ReleaseMouse() end

		active_windows[hwnd_key(self.hwnd)] = nil
		user32.DestroyWindow(self.hwnd)
		self.hwnd = nil
		maybe_unregister_class()

		if base_on_remove then base_on_remove(self) end
	end

	function META:Maximize()
		user32.ShowWindow(self.hwnd, constants.SW_MAXIMIZE)
	end

	function META:Minimize()
		user32.ShowWindow(self.hwnd, constants.SW_MINIMIZE)
	end

	function META:Restore()
		user32.ShowWindow(self.hwnd, constants.SW_RESTORE)
	end

	function META:CaptureMouse()
		if self.mouse_captured then return end

		local rect = RECT_BOX_T()
		local top_left = POINT_BOX_T()
		local bottom_right = POINT_BOX_T()
		user32.GetClientRect(self.hwnd, rect)
		top_left[0].x = rect[0].left
		top_left[0].y = rect[0].top
		bottom_right[0].x = rect[0].right
		bottom_right[0].y = rect[0].bottom
		user32.ClientToScreen(self.hwnd, top_left)
		user32.ClientToScreen(self.hwnd, bottom_right)
		rect[0].left = top_left[0].x
		rect[0].top = top_left[0].y
		rect[0].right = bottom_right[0].x
		rect[0].bottom = bottom_right[0].y
		user32.ClipCursor(rect)
		self.mouse_captured = true
	end

	function META:ReleaseMouse()
		if not self.mouse_captured then return end

		user32.ClipCursor(nil)
		self.mouse_captured = false
	end

	function META:IsMouseCaptured()
		return self.mouse_captured
	end

	function META:SetCursor(mode)
		if not self.Cursors[mode] then mode = "arrow" end

		mode = normalize_cursor_mode(mode)
		self.Cursor = mode
		self.cursor_handle = get_cursor_handle(mode)

		if self.mouse_inside then user32.SetCursor(self.cursor_handle) end
	end

	function META:GetPosition()
		if not self.cached_pos then
			local rect = RECT_BOX_T()
			user32.GetWindowRect(self.hwnd, rect)
			self.cached_pos = Vec2(rect[0].left, rect[0].top)
		end

		return self.cached_pos
	end

	function META:GetSize()
		if not self.cached_size then
			local rect = RECT_BOX_T()
			user32.GetClientRect(self.hwnd, rect)
			self.cached_size = Vec2(rect[0].right - rect[0].left, rect[0].bottom - rect[0].top)
		end

		return self.cached_size
	end

	function META:SetSize(size)
		self.cached_size = nil
		self.cached_fb_size = nil
		local width = math.max(1, math.floor(tonumber(size.x) or 0))
		local height = math.max(1, math.floor(tonumber(size.y) or 0))
		self.width = width
		self.height = height
		local rect = RECT_BOX_T()
		rect[0].left = 0
		rect[0].top = 0
		rect[0].right = width
		rect[0].bottom = height
		user32.AdjustWindowRectEx(rect, constants.WS_OVERLAPPEDWINDOW, 0, 0)
		user32.SetWindowPos(
			self.hwnd,
			nil,
			0,
			0,
			rect[0].right - rect[0].left,
			rect[0].bottom - rect[0].top,
			bit_bor(constants.SWP_NOMOVE, constants.SWP_NOZORDER, constants.SWP_NOACTIVATE)
		)
	end

	function META:GetFramebufferSize()
		if not self.cached_fb_size then
			self.cached_fb_size = self:GetSize():Copy()
		end

		return self.cached_fb_size
	end

	function META:SetTitle(title)
		self.title_buffer = utf8_to_wide(tostring(title or ""))

		if self.hwnd then user32.SetWindowTextW(self.hwnd, self.title_buffer) end
	end

	function META:GetMousePosition()
		return self.last_mouse_pos
	end

	function META:SetMousePosition(pos)
		local point = POINT_BOX_T()
		local x = math.floor(tonumber(pos.x) or 0)
		local y = math.floor(tonumber(pos.y) or 0)
		point[0].x = x
		point[0].y = y
		user32.ClientToScreen(self.hwnd, point)
		user32.SetCursorPos(point[0].x, point[0].y)
		self.last_mouse_pos = Vec2(x, y)
	end

	function META:GetSurfaceHandle()
		return self.hwnd, module_instance
	end

	function META:IsFocused()
		return self.focused
	end
end
