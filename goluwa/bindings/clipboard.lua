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

		print("Wayland connection error: " .. err .. ". Reconnecting...")
		wayland_state.core.wl_client.wl_display_disconnect(wayland_state.display)
		wayland_state.display = nil
	end

	local ok, wayland_core = pcall(require, "bindings.wayland.core")

	if not ok then
		return false, "Wayland bindings not found: " .. tostring(wayland_core)
	end

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
				end
			end,
			global_remove = function() end,
		}
	)
	wayland_core.wl_client.wl_display_roundtrip(wayland_state.display)

	if not wayland_state.manager then
		return false, "Wayland: No data device manager found"
	end

	if not wayland_state.seat then return false, "Wayland: No seat found" end

	wayland_state.device = wayland_state.manager:get_data_device(wayland_state.seat)

	if not wayland_state.device then
		return false, "Wayland: Failed to create data device"
	end

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
				-- print("Wayland: Selection changed, offer: " .. tostring(offer))
				wayland_state.current_offer = offer ~= nil and ffi.cast("struct wl_data_offer*", offer) or nil
			end,
		}
	)

	-- Create a dummy surface to gain focus if needed (some compositors require this)
	if wayland_state.compositor and wayland_state.shell then
		wayland_state.surface = wayland_state.compositor:create_surface()
		wayland_state.shell_surface = wayland_state.shell:get_shell_surface(wayland_state.surface)
		wayland_state.shell_surface:set_toplevel()
		wayland_state.shell_surface:set_title("goluwa-clipboard")
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
						local err = wayland_state.core.wl_client.wl_display_get_error(wayland_state.display)
						print("Wayland dispatch error: " .. err .. ", disconnecting.")
						wayland_state.core.wl_client.wl_display_disconnect(wayland_state.display)
						wayland_state.display = nil
						timer.RemoveTimer("wayland_clipboard_dispatch")
					end
				end)

				if not ok then
					print("Wayland timer error: " .. tostring(err))
					timer.RemoveTimer("wayland_clipboard_dispatch")
				end
			end
		)
	else
		print(
			"Warning: timer library not found, Wayland clipboard events will not be dispatched in background"
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
	function clipboard.Get()
		if os.getenv("WAYLAND_DISPLAY") or os.getenv("XDG_SESSION_TYPE") == "wayland" then
			local ok, err = wayland_init()

			if not ok then return nil, err end

			if not wayland_state.display then return nil, "Wayland connection lost" end

			-- Dispatch to get latest selection and MIME types
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

			if not wayland_state.current_offer then
				-- If we are the owner, return our own data
				if wayland_state.source and wayland_state.data then
					return wayland_state.data
				end

				return nil, "No clipboard offer available (is something copied?)"
			end

			local offer_ptr = tonumber(ffi.cast("intptr_t", wayland_state.current_offer))
			local mime_types = wayland_state.mime_types[offer_ptr]

			if not mime_types or next(mime_types) == nil then
				-- Try one more roundtrip if mime_types is missing or empty
				wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)

				-- Re-check current_offer as it might have changed during roundtrip
				if not wayland_state.current_offer then
					return nil, "Clipboard offer lost during roundtrip"
				end

				offer_ptr = tonumber(ffi.cast("intptr_t", wayland_state.current_offer))
				mime_types = wayland_state.mime_types[offer_ptr]

				if not mime_types or next(mime_types) == nil then
					-- If we are the owner, return our own data
					if wayland_state.source and wayland_state.data then
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

			wayland_state.current_offer:receive(target_mime, fds[1])
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
			local ok, err = wayland_init()

			if not ok then return false, err end

			if not wayland_state.display then return false, "Wayland connection lost" end

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

			if wayland_state.device then
				wayland_state.device:set_selection(wayland_state.source, serial)
			end

			wayland_state.core.wl_client.wl_display_flush(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
			wayland_state.core.wl_client.wl_display_roundtrip(wayland_state.display)
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
