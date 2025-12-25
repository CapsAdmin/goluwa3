local ffi = require("ffi")
local clipboard = {}
local wayland_state = {
	display = nil,
	registry = nil,
	manager = nil,
	seat = nil,
	device = nil,
	source = nil,
	data = nil,
	current_offer = nil,
	mime_types = {},
	compositor = nil,
	shm = nil,
	shell = nil,
	surface = nil,
	shell_surface = nil,
	keyboard = nil,
	keyboard_serial = nil,
	shm_pool = nil,
	buffer = nil,
	-- wlr-data-control protocol (doesn't require focus)
	wlr_manager = nil,
	wlr_device = nil,
	wlr_source = nil,
	wlr_current_offer = nil,
	wlr_mime_types = {},
	-- ext-data-control protocol (standardized, GNOME/KDE)
	ext_manager = nil,
	ext_device = nil,
	ext_source = nil,
	ext_current_offer = nil,
	ext_mime_types = {},
}
local pollfd_t

if jit.os == "Linux" then
	local ok, res = pcall(ffi.typeof, "struct pollfd[?]")

	if ok then
		pollfd_t = res
	else
		pollfd_t = ffi.typeof([[
		struct {
			int fd;
			short events;
			short revents;
		}[?]
	]])
	end

	pcall(
		ffi.cdef,
		[[
		int poll(void *fds, unsigned long nfds, int timeout);

		int pipe(int pipefd[2]);
		long read(int fd, void *buf, size_t count);
		long write(int fd, const void *buf, size_t count);
		int close(int fd);
		int fcntl(int fd, int cmd, ...);
		int ftruncate(int fd, long length);
		int memfd_create(const char *name, unsigned int flags);
		
		void (*signal(int sig, void (*func)(int)))(int);
	]]
	)

	-- Ignore SIGPIPE to prevent crashes when writing to closed pipes
	pcall(function()
		ffi.C.signal(13, ffi.cast("void (*)(int)", 1))
	end)
end

local function wayland_init()
	if wayland_state.display then
		local err = wayland_state.core.wl_client.wl_display_get_error(wayland_state.display)

		if err == 0 then return true end

		-- Connection has an error, disconnect and reconnect
		wayland_state.core.wl_client.wl_display_disconnect(wayland_state.display)
		wayland_state.display = nil
	end

	local ok, wayland_core = pcall(require, "bindings.wayland.core")

	if not ok then
		return false, "Wayland bindings not found: " .. tostring(wayland_core)
	end

	-- Try to load wlr_data_control for clipboard manager support (no focus required)
	local wlr_data_control
	local wlr_load_ok, wlr_load_err = pcall(function()
		wlr_data_control = require("bindings.wayland.wlr_data_control")
	end)
	
	-- Try to load ext_data_control (standardized version used by GNOME/KDE)
	local ext_data_control
	local ext_load_ok, ext_load_err = pcall(function()
		ext_data_control = require("bindings.wayland.ext_data_control")
	end)

	wayland_state.core = wayland_core
	wayland_state.display = wayland_core.wl_client.wl_display_connect(nil)

	if not wayland_state.display then
		return false, "Failed to connect to Wayland (is WAYLAND_DISPLAY set?)"
	end

	wayland_state.registry = wayland_state.display:get_registry()
	wayland_state.registry:add_listener(
		{
			global = function(data, registry_proxy, name, interface, version)
				local iface = ffi.string(interface)
				local reg = ffi.cast("struct wl_registry*", registry_proxy)

				if iface == "wl_data_device_manager" then
					wayland_state.manager = ffi.cast(
						"struct wl_data_device_manager*",
						reg:bind(name, wayland_core.get_interface("wl_data_device_manager"), math.min(version, 3))
					)
				elseif iface == "wl_seat" then
					wayland_state.seat = ffi.cast(
						"struct wl_seat*",
						reg:bind(name, wayland_core.get_interface("wl_seat"), math.min(version, 2))
					)
				elseif iface == "wl_compositor" then
					wayland_state.compositor = ffi.cast(
						"struct wl_compositor*",
						reg:bind(name, wayland_core.get_interface("wl_compositor"), 1)
					)
				elseif iface == "wl_shm" then
					wayland_state.shm = ffi.cast("struct wl_shm*", reg:bind(name, wayland_core.get_interface("wl_shm"), 1))
				elseif iface == "wl_shell" then
					wayland_state.shell = ffi.cast(
						"struct wl_shell*",
						reg:bind(name, wayland_core.get_interface("wl_shell"), 1)
					)
				elseif iface == "zwlr_data_control_manager_v1" and wlr_data_control then
					wayland_state.wlr_manager = ffi.cast(
						"struct zwlr_data_control_manager_v1*",
						reg:bind(name, wlr_data_control.get_interface("zwlr_data_control_manager_v1"), math.min(version, 2))
					)
				elseif iface == "ext_data_control_manager_v1" and ext_data_control then
					wayland_state.ext_manager = ffi.cast(
						"struct ext_data_control_manager_v1*",
						reg:bind(name, ext_data_control.get_interface("ext_data_control_manager_v1"), math.min(version, 2))
					)
				end
			end,
			global_remove = function() end,
		}
	)
	wayland_core.wl_client.wl_display_roundtrip(wayland_state.display)

	if not wayland_state.manager and not wayland_state.wlr_manager and not wayland_state.ext_manager then
		return false, "Wayland: No data device manager found"
	end

	if not wayland_state.seat then return false, "Wayland: No seat found" end

	-- Use ext_data_control if available (standardized, GNOME/KDE)
	if wayland_state.ext_manager then
		wayland_state.ext_device = wayland_state.ext_manager:get_data_device(wayland_state.seat)
		if wayland_state.ext_device then
			wayland_state.ext_device:add_listener({
				data_offer = function(data, device, offer)
					if offer == nil then return end
					local off = ffi.cast("struct ext_data_control_offer_v1*", offer)
					local key = tonumber(ffi.cast("intptr_t", off))
					wayland_state.ext_mime_types[key] = {}
					off:add_listener({
						offer = function(data, offer, mime_type)
							if mime_type == nil then return end
							local m = ffi.string(mime_type)
							if wayland_state.ext_mime_types[key] then
								wayland_state.ext_mime_types[key][m] = true
							end
						end,
					})
				end,
				selection = function(data, device, offer)
					wayland_state.ext_current_offer = offer ~= nil and ffi.cast("struct ext_data_control_offer_v1*", offer) or nil
					-- Note: don't clear data here - the cancelled event handles ownership loss
				end,
				finished = function() end,
				primary_selection = function() end,
			})
		end
	end

	-- Use wlr_data_control if available (doesn't require focus)
	if wayland_state.wlr_manager then
		wayland_state.wlr_device = wayland_state.wlr_manager:get_data_device(wayland_state.seat)
		if wayland_state.wlr_device then
			wayland_state.wlr_device:add_listener({
				data_offer = function(data, device, offer)
					if offer == nil then return end
					local off = ffi.cast("struct zwlr_data_control_offer_v1*", offer)
					local key = tonumber(ffi.cast("intptr_t", off))
					wayland_state.wlr_mime_types[key] = {}
					off:add_listener({
						offer = function(data, offer, mime_type)
							if mime_type == nil then return end
							local m = ffi.string(mime_type)
							if wayland_state.wlr_mime_types[key] then
								wayland_state.wlr_mime_types[key][m] = true
							end
						end,
					})
				end,
				selection = function(data, device, offer)
					wayland_state.wlr_current_offer = offer ~= nil and ffi.cast("struct zwlr_data_control_offer_v1*", offer) or nil
					-- Note: don't clear data here - the cancelled event handles ownership loss
				end,
				finished = function() end,
				primary_selection = function() end,
			})
		end
	end

	-- Also set up regular data device as fallback
	if wayland_state.manager then
		wayland_state.device = wayland_state.manager:get_data_device(wayland_state.seat)
	end

	if wayland_state.device then
		wayland_state.device:add_listener(
		{
			data_offer = function(data, device, offer)
				if offer == nil then return end

				local off = ffi.cast("struct wl_data_offer*", offer)
				local key = tonumber(ffi.cast("intptr_t", off))
				-- print("Wayland: New data offer: " .. key)
				wayland_state.mime_types[key] = {}
				off:add_listener(
					{
						offer = function(data, offer, mime_type)
							if mime_type == nil then return end

							local m = ffi.string(mime_type)

							-- print("Wayland: Offer " .. key .. " supports " .. m)
							if wayland_state.mime_types[key] then
								wayland_state.mime_types[key][m] = true
							end
						end,
					}
				)
			end,
			selection = function(data, device, offer)
				wayland_state.current_offer = offer ~= nil and ffi.cast("struct wl_data_offer*", offer) or nil
				-- Note: don't clear data here - the cancelled event handles ownership loss
			end,
		}
	)
	end

	-- Create a dummy surface to gain focus if needed (some compositors require this)
	if wayland_state.compositor and wayland_state.shell and wayland_state.shm then
		-- Get keyboard from seat to receive enter events with serial
		wayland_state.keyboard = wayland_state.seat:get_keyboard()
		if wayland_state.keyboard then
			wayland_state.keyboard:add_listener({
				keymap = function(data, keyboard, format, fd, size)
					ffi.C.close(fd)
				end,
				enter = function(data, keyboard, serial, surface, keys)
					-- Store the serial from keyboard focus - this is what we need for set_selection
					wayland_state.keyboard_serial = serial
				end,
				leave = function(data, keyboard, serial, surface) end,
				key = function(data, keyboard, serial, time, key, state) end,
				modifiers = function(data, keyboard, serial, mods_depressed, mods_latched, mods_locked, group) end,
				repeat_info = function(data, keyboard, rate, delay) end,
			})
		end

		-- Dispatch to get keyboard before creating surface
		wayland_core.wl_client.wl_display_dispatch(wayland_state.display)

		-- Create surface
		wayland_state.surface = wayland_state.compositor:create_surface()
		wayland_state.shell_surface = wayland_state.shell:get_shell_surface(wayland_state.surface)
		wayland_state.shell_surface:set_toplevel()
		wayland_state.shell_surface:set_title("goluwa-clipboard")

		-- Create a 1x1 transparent buffer using shared memory
		local width, height = 1, 1
		local stride = width * 4
		local size = stride * height

		-- Create anonymous file for shared memory
		local fd = ffi.C.memfd_create("wl_shm", 0)
		if fd >= 0 then
			if ffi.C.ftruncate(fd, size) == 0 then
				wayland_state.shm_pool = wayland_state.shm:create_pool(fd, size)
				if wayland_state.shm_pool then
					-- WL_SHM_FORMAT_ARGB8888 = 0, zero bytes = transparent
					wayland_state.buffer = wayland_state.shm_pool:create_buffer(0, width, height, stride, 0)
					if wayland_state.buffer then
						wayland_state.surface:attach(wayland_state.buffer, 0, 0)
						wayland_state.surface:damage(0, 0, width, height)
					end
				end
			end
			ffi.C.close(fd)
		end

		wayland_state.surface:commit()
	end

	wayland_core.wl_client.wl_display_roundtrip(wayland_state.display)
	wayland_core.wl_client.wl_display_roundtrip(wayland_state.display)
	wayland_core.wl_client.wl_display_flush(wayland_state.display)
	local timer = require("timer")

	if timer then
		timer.Repeat(
			"wayland_clipboard_dispatch",
			0.05,
			0,
			function()
				local ok, err = pcall(function()
					if not wayland_state.display then return end

					wayland_state.core.wl_client.wl_display_dispatch_pending(wayland_state.display)
					wayland_state.core.wl_client.wl_display_flush(wayland_state.display)

					if wayland_state.core.wl_client.wl_display_prepare_read(wayland_state.display) == 0 then
						local pfd = pollfd_t(1)
						pfd[0].fd = wayland_state.core.wl_client.wl_display_get_fd(wayland_state.display)
						pfd[0].events = 1 -- POLLIN
						if ffi.C.poll(ffi.cast("void *", pfd), 1, 0) > 0 then
							wayland_state.core.wl_client.wl_display_read_events(wayland_state.display)
						else
							wayland_state.core.wl_client.wl_display_cancel_read(wayland_state.display)
						end
					end

					local ret = wayland_state.core.wl_client.wl_display_dispatch_pending(wayland_state.display)

					if ret == -1 then
						-- Silently reconnect on next clipboard operation
						wayland_state.core.wl_client.wl_display_disconnect(wayland_state.display)
						wayland_state.display = nil
						timer.RemoveTimer("wayland_clipboard_dispatch")
					end
				end)

				if not ok then
					timer.RemoveTimer("wayland_clipboard_dispatch")
				end
			end
		)
	end

	return true
end

-- XCB definitions for Linux
if jit.os == "Linux" then
	pcall(
		ffi.cdef,
		[[
	
		int poll(void *fds, unsigned long nfds, int timeout);

		int pipe(int pipefd[2]);
		long read(int fd, void *buf, size_t count);
		long write(int fd, const void *buf, size_t count);
		int close(int fd);
		int fcntl(int fd, int cmd, ...);

		typedef struct xcb_connection_t xcb_connection_t;
		typedef uint32_t xcb_window_t;
		typedef uint32_t xcb_atom_t;
		typedef uint32_t xcb_timestamp_t;
		typedef struct xcb_screen_t xcb_screen_t;
		typedef struct xcb_setup_t xcb_setup_t;
		typedef struct xcb_generic_event_t xcb_generic_event_t;
		typedef struct xcb_generic_error_t xcb_generic_error_t;
		
		typedef struct {
			unsigned int sequence;
		} xcb_void_cookie_t;
		
		typedef struct {
			unsigned int sequence;
		} xcb_intern_atom_cookie_t;
		
		typedef struct {
			unsigned int sequence;
		} xcb_get_property_cookie_t;
		
		typedef struct {
			unsigned int sequence;
		} xcb_get_selection_owner_cookie_t;
		
		typedef struct {
			uint8_t response_type;
			uint8_t pad0;
			uint16_t sequence;
			uint32_t length;
			xcb_atom_t atom;
		} xcb_intern_atom_reply_t;
		
		typedef struct {
			uint8_t response_type;
			uint8_t format;
			uint16_t sequence;
			uint32_t length;
			xcb_atom_t type;
			uint32_t bytes_after;
			uint32_t value_len;
			uint8_t pad0[12];
		} xcb_get_property_reply_t;
		
		typedef struct {
			uint8_t response_type;
			uint8_t pad0;
			uint16_t sequence;
			uint32_t length;
			xcb_window_t owner;
		} xcb_get_selection_owner_reply_t;
		
		typedef struct {
			uint8_t response_type;
			uint8_t pad0;
			uint16_t sequence;
			xcb_timestamp_t time;
			xcb_window_t requestor;
			xcb_atom_t selection;
			xcb_atom_t target;
			xcb_atom_t property;
		} xcb_selection_notify_event_t;
		
		typedef struct {
			xcb_screen_t *data;
			int rem;
		} xcb_screen_iterator_t;
		
		xcb_connection_t *xcb_connect(const char *displayname, int *screenp);
		void xcb_disconnect(xcb_connection_t *c);
		int xcb_connection_has_error(xcb_connection_t *c);
		int xcb_flush(xcb_connection_t *c);
		xcb_setup_t *xcb_get_setup(xcb_connection_t *c);
		xcb_screen_iterator_t xcb_setup_roots_iterator(const xcb_setup_t *R);
		void xcb_screen_next(xcb_screen_iterator_t *i);
		uint32_t xcb_generate_id(xcb_connection_t *c);
		
		xcb_void_cookie_t xcb_create_window(xcb_connection_t *c, uint8_t depth,
			xcb_window_t wid, xcb_window_t parent, int16_t x, int16_t y,
			uint16_t width, uint16_t height, uint16_t border_width,
			uint16_t _class, uint32_t visual, uint32_t value_mask,
			const void *value_list);
		
		xcb_void_cookie_t xcb_destroy_window(xcb_connection_t *c, xcb_window_t window);
		
		xcb_intern_atom_cookie_t xcb_intern_atom(xcb_connection_t *c, uint8_t only_if_exists,
			uint16_t name_len, const char *name);
		xcb_intern_atom_reply_t *xcb_intern_atom_reply(xcb_connection_t *c,
			xcb_intern_atom_cookie_t cookie, xcb_generic_error_t **e);
		
		xcb_void_cookie_t xcb_convert_selection(xcb_connection_t *c, xcb_window_t requestor,
			xcb_atom_t selection, xcb_atom_t target, xcb_atom_t property, xcb_timestamp_t time);
		
		xcb_void_cookie_t xcb_set_selection_owner(xcb_connection_t *c, xcb_window_t owner,
			xcb_atom_t selection, xcb_timestamp_t time);
		
		xcb_get_selection_owner_cookie_t xcb_get_selection_owner(xcb_connection_t *c,
			xcb_atom_t selection);
		xcb_get_selection_owner_reply_t *xcb_get_selection_owner_reply(xcb_connection_t *c,
			xcb_get_selection_owner_cookie_t cookie, xcb_generic_error_t **e);
		
		xcb_get_property_cookie_t xcb_get_property(xcb_connection_t *c, uint8_t _delete,
			xcb_window_t window, xcb_atom_t property, xcb_atom_t type,
			uint32_t long_offset, uint32_t long_length);
		xcb_get_property_reply_t *xcb_get_property_reply(xcb_connection_t *c,
			xcb_get_property_cookie_t cookie, xcb_generic_error_t **e);
		void *xcb_get_property_value(const xcb_get_property_reply_t *R);
		int xcb_get_property_value_length(const xcb_get_property_reply_t *R);
		
		xcb_void_cookie_t xcb_change_property(xcb_connection_t *c, uint8_t mode,
			xcb_window_t window, xcb_atom_t property, xcb_atom_t type,
			uint8_t format, uint32_t data_len, const void *data);
		
		xcb_generic_event_t *xcb_poll_for_event(xcb_connection_t *c);
		xcb_generic_event_t *xcb_wait_for_event(xcb_connection_t *c);
		
		void free(void *ptr);
		
		typedef long time_t;
		typedef long suseconds_t;
		struct timeval {
			time_t tv_sec;
			suseconds_t tv_usec;
		};
		int gettimeofday(struct timeval *tv, void *tz);
	]]
	)
end

if jit.os == "Windows" then
	ffi.cdef([[
		void* GetClipboardData(unsigned int uFormat);
		int SetClipboardData(unsigned int uFormat, void* hMem);
		int OpenClipboard(void* hWndNewOwner);
		int CloseClipboard(void);
		int EmptyClipboard(void);
		void* GlobalAlloc(unsigned int uFlags, size_t dwBytes);
		void* GlobalLock(void* hMem);
		int GlobalUnlock(void* hMem);
		void* GlobalFree(void* hMem);
		size_t GlobalSize(void* hMem);
	]])
	local user32 = ffi.load("user32")
	local kernel32 = ffi.load("kernel32")
	local CF_TEXT = 1
	local CF_UNICODETEXT = 13
	local GMEM_MOVEABLE = 0x0002

	function clipboard.Get()
		if user32.OpenClipboard(nil) == 0 then
			return nil, "Failed to open clipboard"
		end

		local hData = user32.GetClipboardData(CF_UNICODETEXT)

		if hData == nil then
			user32.CloseClipboard()
			return ""
		end

		local pData = kernel32.GlobalLock(hData)

		if pData == nil then
			user32.CloseClipboard()
			return nil, "Failed to lock clipboard data"
		end

		local size = kernel32.GlobalSize(hData)
		local text = ffi.string(ffi.cast("const uint16_t*", pData), size)
		-- Convert UTF-16 to UTF-8
		local str = ""
		local i = 0

		while i < #text - 1 do
			local byte1 = text:byte(i + 1)
			local byte2 = text:byte(i + 2)
			local codepoint = byte1 + byte2 * 256

			if codepoint == 0 then break end

			if codepoint < 128 then
				str = str .. string.char(codepoint)
			elseif codepoint < 2048 then
				str = str .. string.char(0xC0 + math.floor(codepoint / 64), 0x80 + (codepoint % 64))
			else
				str = str .. string.char(
						0xE0 + math.floor(codepoint / 4096),
						0x80 + (math.floor(codepoint / 64) % 64),
						0x80 + (codepoint % 64)
					)
			end

			i = i + 2
		end

		kernel32.GlobalUnlock(hData)
		user32.CloseClipboard()
		return str
	end

	function clipboard.Set(str)
		if type(str) ~= "string" then return false, "Input must be a string" end

		-- Convert UTF-8 to UTF-16
		local utf16 = {}
		local i = 1

		while i <= #str do
			local byte = str:byte(i)
			local codepoint

			if byte < 128 then
				codepoint = byte
				i = i + 1
			elseif byte < 224 then
				codepoint = (byte - 192) * 64 + (str:byte(i + 1) - 128)
				i = i + 2
			elseif byte < 240 then
				codepoint = (byte - 224) * 4096 + (str:byte(i + 1) - 128) * 64 + (str:byte(i + 2) - 128)
				i = i + 3
			else
				codepoint = (
						byte - 240
					) * 262144 + (
						str:byte(i + 1) - 128
					) * 4096 + (
						str:byte(i + 2) - 128
					) * 64 + (
						str:byte(i + 3) - 128
					)
				i = i + 4
			end

			table.insert(utf16, codepoint % 256)
			table.insert(utf16, math.floor(codepoint / 256))
		end

		table.insert(utf16, 0)
		table.insert(utf16, 0)
		local size = #utf16
		local hMem = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)

		if hMem == nil then return false, "Failed to allocate memory" end

		local pMem = kernel32.GlobalLock(hMem)

		if pMem == nil then
			kernel32.GlobalFree(hMem)
			return false, "Failed to lock memory"
		end

		ffi.copy(pMem, ffi.new("uint8_t[?]", size, utf16), size)
		kernel32.GlobalUnlock(hMem)

		if user32.OpenClipboard(nil) == 0 then
			kernel32.GlobalFree(hMem)
			return false, "Failed to open clipboard"
		end

		user32.EmptyClipboard()

		if user32.SetClipboardData(CF_UNICODETEXT, hMem) == 0 then
			user32.CloseClipboard()
			kernel32.GlobalFree(hMem)
			return false, "Failed to set clipboard data"
		end

		user32.CloseClipboard()
		return true
	end
elseif jit.os == "OSX" then
	local objc = require("bindings.objc")
	-- Load AppKit framework for NSPasteboard
	objc.loadFramework("AppKit")
	-- Cache commonly used classes and selectors
	local NSPasteboard = objc.Class("NSPasteboard")
	local NSString = objc.Class("NSString")

	function clipboard.Get()
		-- Get the general pasteboard
		local pasteboard = NSPasteboard:Call("generalPasteboard")
		-- Get string from pasteboard
		local nsstring = pasteboard:Call(
			"stringForType:",
			NSString:Call("stringWithUTF8String:", "public.utf8-plain-text")
		)

		if nsstring == nil then
			-- Try NSStringPboardType as fallback
			nsstring = pasteboard:Call("stringForType:", NSString:Call("stringWithUTF8String:", "NSStringPboardType"))
		end

		if nsstring == nil then return "" end

		-- Convert NSString to C string
		local utf8String = nsstring:Call("UTF8String")

		if utf8String == nil then return "" end

		return ffi.string(utf8String)
	end

	function clipboard.Set(str)
		if type(str) ~= "string" then return false, "Input must be a string" end

		-- Get the general pasteboard
		local pasteboard = NSPasteboard:Call("generalPasteboard")
		-- Clear the pasteboard
		pasteboard:Call("clearContents")
		-- Create NSString from UTF-8 string
		local nsstring = NSString:Call("stringWithUTF8String:", str)

		if nsstring == nil then return false, "Failed to create NSString" end

		-- Create array with the NSString
		local NSArray = objc.Class("NSArray")
		local array = NSArray:Call("arrayWithObject:", nsstring)
		-- Write to pasteboard
		local success = pasteboard:Call("writeObjects:", array)

		if success == 0 then return false, "Failed to write to pasteboard" end

		return true
	end
elseif jit.os == "Linux" then
	-- Check for wl-paste/wl-copy availability
	local function run_command(cmd)
		local handle = io.popen(cmd .. " 2>/dev/null")
		if not handle then return nil end
		local result = handle:read("*a")
		local ok = handle:close()
		return ok and result or nil
	end

	local wl_paste_available = run_command("which wl-paste") ~= nil
	local wl_copy_available = run_command("which wl-copy") ~= nil

	function clipboard.Get()
		if os.getenv("WAYLAND_DISPLAY") or os.getenv("XDG_SESSION_TYPE") == "wayland" then
			-- Try wl-paste first as it's the most reliable
			if wl_paste_available then
				local result = run_command("wl-paste --no-newline 2>/dev/null")
				if result then return result end
			end

			local ok, err = wayland_init()

			if not ok then return nil, err end

			if not wayland_state.display then return nil, "Wayland connection lost" end

			-- Dispatch to get latest selection and MIME types
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

			-- Prefer ext_data_control (GNOME/KDE) > wlr_data_control (Sway) > regular (requires focus)
			local current_offer = wayland_state.ext_current_offer or wayland_state.wlr_current_offer or wayland_state.current_offer
			local mime_types_table
			if wayland_state.ext_current_offer then
				mime_types_table = wayland_state.ext_mime_types
			elseif wayland_state.wlr_current_offer then
				mime_types_table = wayland_state.wlr_mime_types
			else
				mime_types_table = wayland_state.mime_types
			end

			-- If we are the owner (have an active source and no external offer), return our own data
			local we_own_clipboard = (wayland_state.ext_source or wayland_state.wlr_source or wayland_state.source) and wayland_state.data
			if we_own_clipboard and not current_offer then
				return wayland_state.data
			end

			if not current_offer then
				return nil, "No clipboard offer available (is something copied?)"
			end

			local offer_ptr = tonumber(ffi.cast("intptr_t", current_offer))
			local mime_types = mime_types_table[offer_ptr]

			if not mime_types or next(mime_types) == nil then
				-- Try one more roundtrip if mime_types is missing or empty
				wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

				-- Re-check current_offer as it might have changed during roundtrip
				current_offer = wayland_state.ext_current_offer or wayland_state.wlr_current_offer or wayland_state.current_offer
				if not current_offer then
					return nil, "Clipboard offer lost during roundtrip"
				end

				offer_ptr = tonumber(ffi.cast("intptr_t", current_offer))
				mime_types = mime_types_table[offer_ptr]

				if not mime_types or next(mime_types) == nil then
					-- If we are the owner, return our own data
					if wayland_state.data then
						return wayland_state.data
					end

					local msg = "No MIME types found for current offer " .. offer_ptr

					if not mime_types then msg = msg .. " (offer unknown)" end

					return nil, msg
				end
			end

			local target_mime = "text/plain;charset=utf-8"

			if not mime_types[target_mime] then
				target_mime = "text/plain"

				if not mime_types[target_mime] then
					for m in pairs(mime_types) do
						if m:find("text/") or m:find("STRING") then
							target_mime = m

							break
						end
					end
				end
			end

			if not mime_types[target_mime] then
				local available = {}

				for m in pairs(mime_types) do
					table.insert(available, m)
				end

				return nil,
				"No suitable text MIME type found. Available: " .. table.concat(available, ", ")
			end

			local fds = ffi.new("int[2]")

			if ffi.C.pipe(fds) ~= 0 then return nil, "Failed to create pipe" end

			current_offer:receive(target_mime, fds[1])
			ffi.C.close(fds[1])
			wayland_state.core.wl_client.wl_display_flush(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
			-- Use poll to wait for data with a timeout to avoid hanging
			local pfd = pollfd_t(1)
			pfd[0].fd = fds[0]
			pfd[0].events = 1 -- POLLIN
			local result = ""
			local buf = ffi.new("char[4096]")

			while true do
				local ret = ffi.C.poll(ffi.cast("void *", pfd), 1, 200) -- 200ms timeout
				if ret <= 0 then break end

				local n = tonumber(ffi.C.read(fds[0], buf, 4096))

				if n <= 0 then break end

				result = result .. ffi.string(buf, n)
			end

			ffi.C.close(fds[0])
			return result
		end

		return nil, "Clipboard operations are not supported on X11 yet (Wayland only)"
	end

	function clipboard.Set(str)
		if type(str) ~= "string" then return false, "Input must be a string" end

		if os.getenv("WAYLAND_DISPLAY") or os.getenv("XDG_SESSION_TYPE") == "wayland" then
			-- Try wl-copy first as it's the most reliable
			if wl_copy_available then
				local handle = io.popen("wl-copy 2>/dev/null", "w")
				if handle then
					handle:write(str)
					local ok = handle:close()
					if ok then return true end
				end
			end

			local ok, err = wayland_init()

			if not ok then return false, err end

			if not wayland_state.display then return false, "Wayland connection lost" end

			-- Use ext_data_control if available (GNOME/KDE, doesn't require focus)
			if wayland_state.ext_manager then
				if wayland_state.ext_source then
					wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.ext_source)
					wayland_state.ext_source = nil
				end

				wayland_state.data = str
				wayland_state.ext_source = wayland_state.ext_manager:create_data_source()

				if not wayland_state.ext_source then
					return false, "Failed to create ext data source"
				end

				wayland_state.ext_source:offer("text/plain;charset=utf-8")
				wayland_state.ext_source:offer("text/plain")
				wayland_state.ext_source:offer("UTF8_STRING")
				wayland_state.ext_source:add_listener({
					send = function(data, source, mime_type, fd)
						if mime_type == nil then
							ffi.C.close(fd)
							return
						end

						if not wayland_state.data then
							ffi.C.close(fd)
							return
						end

						local n = ffi.C.write(fd, wayland_state.data, #wayland_state.data)
						if n < 0 then
							print("Wayland: Failed to write to clipboard pipe (errno: " .. ffi.errno() .. ")")
						end
						ffi.C.close(fd)
					end,
					cancelled = function()
						if wayland_state.ext_source then
							wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.ext_source)
							wayland_state.ext_source = nil
						end
						wayland_state.data = nil
					end,
				})

				-- ext_data_control doesn't need a serial - just set the selection
				wayland_state.ext_device:set_selection(wayland_state.ext_source)

				wayland_state.core.wl_client.wl_display_flush(wayland_state.display)
				wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

				-- Check if we still have ownership
				if not wayland_state.data then
					return false, "Clipboard ownership was rejected by compositor"
				end

				return true
			end

			-- Use wlr_data_control if available (doesn't require focus)
			if wayland_state.wlr_manager then
				if wayland_state.wlr_source then
					wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.wlr_source)
					wayland_state.wlr_source = nil
				end

				wayland_state.data = str
				wayland_state.wlr_source = wayland_state.wlr_manager:create_data_source()

				if not wayland_state.wlr_source then
					return false, "Failed to create wlr data source"
				end

				wayland_state.wlr_source:offer("text/plain;charset=utf-8")
				wayland_state.wlr_source:offer("text/plain")
				wayland_state.wlr_source:offer("UTF8_STRING")
				wayland_state.wlr_source:add_listener({
					send = function(data, source, mime_type, fd)
						if mime_type == nil then
							ffi.C.close(fd)
							return
						end

						if not wayland_state.data then
							ffi.C.close(fd)
							return
						end

						local n = ffi.C.write(fd, wayland_state.data, #wayland_state.data)
						if n < 0 then
							print("Wayland: Failed to write to clipboard pipe (errno: " .. ffi.errno() .. ")")
						end
						ffi.C.close(fd)
					end,
					cancelled = function()
						if wayland_state.wlr_source then
							wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.wlr_source)
							wayland_state.wlr_source = nil
						end
						wayland_state.data = nil
					end,
				})

				-- wlr_data_control doesn't need a serial - just set the selection
				wayland_state.wlr_device:set_selection(wayland_state.wlr_source)

				wayland_state.core.wl_client.wl_display_flush(wayland_state.display)
				wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

				-- Check if we still have ownership
				if not wayland_state.data then
					return false, "Clipboard ownership was rejected by compositor"
				end

				return true
			end

			-- Fallback to regular wl_data_device (requires focus)
			if wayland_state.source then
				wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.source)
			end

			wayland_state.data = str
			wayland_state.source = wayland_state.manager:create_data_source()

			if not wayland_state.source then
				return false, "Failed to create Wayland data source"
			end

			wayland_state.source:offer("text/plain;charset=utf-8")
			wayland_state.source:offer("text/plain")
			wayland_state.source:offer("UTF8_STRING")
			wayland_state.source:add_listener(
				{
					target = function() end,
					send = function(data, source, mime_type, fd)
						if mime_type == nil then
							ffi.C.close(fd)
							return
						end

						local m = ffi.string(mime_type)

						if not wayland_state.data then
							ffi.C.close(fd)
							return
						end

						local n = ffi.C.write(fd, wayland_state.data, #wayland_state.data)

						if n < 0 then
							print("Wayland: Failed to write to clipboard pipe (errno: " .. ffi.errno() .. ")")
						end

						ffi.C.close(fd)
					end,
					cancelled = function()
						-- print("Wayland: Clipboard selection cancelled (lost ownership)")
						if wayland_state.source then
							wayland_state.core.wl_client.wl_proxy_destroy(wayland_state.source)
							wayland_state.source = nil
						end

						wayland_state.data = nil
					end,
					dnd_drop_performed = function() end,
					dnd_finished = function() end,
					action = function() end,
				}
			)
			local serial = 0
			local window = package.loaded["window"]

			if window and window.active then
				for _, wnd in pairs(window.active) do
					if wnd.pointer_serial then
						serial = wnd.pointer_serial

						break
					end
				end
			end

			-- Fall back to keyboard serial from our popup surface
			if serial == 0 and wayland_state.keyboard_serial then
				serial = wayland_state.keyboard_serial
			end

			if wayland_state.device then
				wayland_state.device:set_selection(wayland_state.source, serial)
			end

			wayland_state.core.wl_client.wl_display_flush(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

			-- Check if we still have ownership after roundtrips
			if not wayland_state.data then
				return false, "Clipboard ownership was rejected by compositor (no input focus?)"
			end

			return true
		end

		return false, "Clipboard operations are not supported on X11 yet (Wayland only)"
	end
else
	function clipboard.Get()
		return nil, "Clipboard operations are not supported on this OS"
	end

	function clipboard.Set(str)
		return false, "Clipboard operations are not supported on this OS"
	end
end

return clipboard
