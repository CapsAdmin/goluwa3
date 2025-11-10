local ffi = require("ffi")
local terminal = {}
local meta = {}
meta.__index = meta

function meta:SetTitle(str)
	self:Write(string.format("\27[s\27[0;0f%s\27[u", str))
end

function meta:SetCaretPosition(x, y)
	self:Write(string.format("\27[%i;%if", y, x))
end

function meta:WriteStringToScreen(x, y, str)
	self:Write(string.format("\27[s\27[%i;%if%s\27[u", y, x, str))
end

function meta:PushForegroundColor(r, g, b)
	table.insert(self.attribute_stack, {type = "fg", r = r, g = g, b = b})
	self:ForegroundColor(r, g, b)
end

function meta:PushBackgroundColor(r, g, b)
	table.insert(self.attribute_stack, {type = "bg", r = r, g = g, b = b})
	self:BackgroundColor(r, g, b)
end

function meta:PushBold()
	table.insert(self.attribute_stack, {type = "bold"})
	self:Bold()
end

function meta:PushUnderline()
	table.insert(self.attribute_stack, {type = "underline"})
	self:Underline()
end

function meta:PushItalic()
	table.insert(self.attribute_stack, {type = "italic"})
	self:Italic()
end

function meta:PushDim()
	table.insert(self.attribute_stack, {type = "dim"})
	self:Dim()
end

function meta:PopAttribute()
	if #self.attribute_stack == 0 then
		-- Stack is empty, reset all attributes
		self:NoAttributes()
		return
	end

	-- Remove the top attribute
	table.remove(self.attribute_stack)

	-- Reset everything and reapply all remaining attributes
	self:NoAttributes()
	for _, attr in ipairs(self.attribute_stack) do
		if attr.type == "fg" then
			self:ForegroundColor(attr.r, attr.g, attr.b)
		elseif attr.type == "bg" then
			self:BackgroundColor(attr.r, attr.g, attr.b)
		elseif attr.type == "bold" then
			self:Bold()
		elseif attr.type == "underline" then
			self:Underline()
		elseif attr.type == "italic" then
			self:Italic()
		elseif attr.type == "dim" then
			self:Dim()
		end
	end
end

-- Text attribute stack management
function meta:ForegroundColor(r, g, b)
	self:Write(string.format("\27[38;2;%i;%i;%im", r, g, b))
end

function meta:BackgroundColor(r, g, b)
	self:Write(string.format("\27[48;2;%i;%i;%im", r, g, b))
end

function meta:Bold()
	self:Write("\27[1m")
end

function meta:Underline()
	self:Write("\27[4m")
end

function meta:Italic()
	self:Write("\27[3m")
end

function meta:Dim()
	self:Write("\27[2m")
end

function meta:NoAttributes()
	self:Write("\27[0m")
end

function meta:ClearAttributeStack()
	self.attribute_stack = {}
	self:NoAttributes()
end

function meta:Clear()
	self:Write("\27[2J\27[3J\27[H")
end

function meta:UseAlternateScreen(enable)
	if enable then
		self:Write("\27[?1049h") -- Switch to alternate screen
	else
		self:Write("\27[?1049l") -- Switch back to main screen
	end
end

function meta:Flush()
	self.output:flush()
end

function meta:BeginFrame()
	self._frame_buffer = {}
end

function meta:EndFrame()
	if self._frame_buffer then
		local buffer = table.concat(self._frame_buffer)
		self._frame_buffer = nil
		self.output:write(buffer)
		self.output:flush()
	end
end

function meta:Write(str)
	if self._frame_buffer then
		table.insert(self._frame_buffer, str)
	else
		self.output:write(str)
	end
end

function meta:EnableCaret(b)
	if b then
		self:Write("\27[?25h") -- Show cursor
	else
		self:Write("\27[?25l") -- Hide cursor
	end
end

function meta:EnableMouse(b)
	if b then
		-- Enable mouse tracking with SGR (1006) mode for better coordinate support
		self:Write("\27[?1000h\27[?1006h") -- Enable mouse reporting + SGR extended mode
	else
		-- Disable mouse tracking
		self:Write("\27[?1006l\27[?1000l") -- Disable SGR mode + mouse reporting
	end
	self.mouse_enabled = b
end

do
	local function read_coordinates()
		while true do
			local str = terminal.Read()

			if str then
				local a, b = str:match("^\27%[(%d+);(%d+)R$")

				if a then return tonumber(a), tonumber(b) end
			end
		end
	end

	local _x, _y = 0, 0

	function meta:GetCaretPosition()
		self:Write("\x1b[6n")
		local y, x = read_coordinates()

		if y then _x, _y = x, y end

		return _x, _y
	end
end

if jit.os == "Windows" then
	local STD_INPUT_HANDLE = -10
	local STD_OUTPUT_HANDLE = -11
	local ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200
	local DISABLE_NEWLINE_AUTO_RETURN = 0x0008
	local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
	ffi.cdef([[
	struct COORD {
		short X;
		short Y;
	};

	struct KEY_EVENT_RECORD {
		int bKeyDown;
		unsigned short wRepeatCount;
		unsigned short wVirtualKeyCode;
		unsigned short wVirtualScanCode;
		union {
			wchar_t UnicodeChar;
			char AsciiChar;
		} uChar;
		unsigned long dwControlKeyState;
	};

	struct MOUSE_EVENT_RECORD {
	struct COORD dwMousePosition;
	unsigned long dwButtonState;
	unsigned long dwControlKeyState;
	unsigned long dwEventFlags;
	};

	struct WINDOW_BUFFER_SIZE_RECORD {
	struct COORD dwSize;
	};

	struct MENU_EVENT_RECORD {
	unsigned int dwCommandId;
	};

	struct FOCUS_EVENT_RECORD {
	int bSetFocus;
	};

	struct INPUT_RECORD {
	unsigned short  EventType;
	union {
		struct KEY_EVENT_RECORD KeyEvent;
		struct MOUSE_EVENT_RECORD MouseEvent;
		struct WINDOW_BUFFER_SIZE_RECORD WindowBufferSizeEvent;
		struct MENU_EVENT_RECORD MenuEvent;
		struct FOCUS_EVENT_RECORD FocusEvent;
	} Event;
	};


	int PeekConsoleInputW(
		void* hConsoleInput,
		struct INPUT_RECORD* lpBuffer,
		unsigned long nLength,
		unsigned long * lpNumberOfEventsRead
	);

	int ReadConsoleInputW(
		void* hConsoleInput,
		struct INPUT_RECORD* lpBuffer,
		unsigned long nLength,
		unsigned long * lpNumberOfEventsRead
	);

	struct SMALL_RECT {
		uint16_t Left;
		uint16_t Top;
		uint16_t Right;
		uint16_t Bottom;
		};


	struct CONSOLE_SCREEN_BUFFER_INFO {
	struct COORD dwSize;
	struct COORD dwCursorPosition;
	uint16_t wAttributes;
		struct SMALL_RECT srWindow;
	struct COORD dwMaximumWindowSize;
	};

	struct CONSOLE_CURSOR_INFO {
		unsigned long dwSize;
		int bVisible;
	};

	int SetConsoleCursorInfo(
		void *hConsoleOutput,
		const struct CONSOLE_CURSOR_INFO *lpConsoleCursorInfo
	);

	int GetConsoleScreenBufferInfo(
		void* hConsoleOutput,
		struct CONSOLE_SCREEN_BUFFER_INFO* lpConsoleScreenBufferInfo
	);

	int SetConsoleCursorPosition(
		void* hConsoleOutput,
		struct COORD  dwCursorPosition
	);


	int SetConsoleMode(void*, uint16_t);
	int GetConsoleMode(void*, uint16_t*);
	void* GetStdHandle(unsigned long nStdHandle);
	int SetConsoleTitleA(const char*);
	int SetConsoleOutputCP(unsigned int wCodePageID);
	int SetConsoleCP(unsigned int wCodePageID);

	uint32_t GetLastError();

	uint32_t FormatMessageA(
		uint32_t dwFlags,
		const void* lpSource,
		uint32_t dwMessageId,
		uint32_t dwLanguageId,
		char* lpBuffer,
		uint32_t nSize,
		va_list *Arguments
	);

	struct CHAR_INFO {
		union {
			wchar_t UnicodeChar;
			char AsciiChar;
		} Char;
		uint16_t Attributes;
	} CHAR_INFO;
]])
	local error_str = ffi.new("uint8_t[?]", 1024)
	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000
	local ENABLE_WINDOW_INPUT = 0x0008
	local FORMAT_MESSAGE_IGNORE_INSERTS = 0x00000200
	local error_flags = bit.bor(FORMAT_MESSAGE_FROM_SYSTEM, FORMAT_MESSAGE_IGNORE_INSERTS)

	local function throw_error()
		local code = ffi.C.GetLastError()
		local numout = ffi.C.FormatMessageA(error_flags, nil, code, 0, error_str, 1023, nil)
		local err = numout ~= 0 and ffi.string(error_str, numout)

		if err and err:sub(-2) == "\r\n" then return err:sub(0, -3) end

		return err
	end

	local mode_flags = {
		ENABLE_ECHO_INPUT = 0x0004,
		ENABLE_EXTENDED_FLAGS = 0x0080,
		ENABLE_INSERT_MODE = 0x0020,
		ENABLE_LINE_INPUT = 0x0002,
		ENABLE_MOUSE_INPUT = 0x0010,
		ENABLE_PROCESSED_INPUT = 0x0001,
		ENABLE_QUICK_EDIT_MODE = 0x0040,
		ENABLE_WINDOW_INPUT = 0x0008,
		ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200,
		ENABLE_PROCESSED_OUTPUT = 0x0001,
		ENABLE_WRAP_AT_EOL_OUTPUT = 0x0002,
		ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004,
		DISABLE_NEWLINE_AUTO_RETURN = 0x0008,
		ENABLE_LVB_GRID_WORLDWIDE = 0x0010,
	}
	local stdin = ffi.C.GetStdHandle(STD_INPUT_HANDLE)
	local stdout = ffi.C.GetStdHandle(STD_OUTPUT_HANDLE)

	-- Convert table of flag names to combined flag value
	local function table_to_flags(tbl, flags_map, combiner)
		local result = 0

		for _, flag_name in ipairs(tbl) do
			if flags_map[flag_name] then
				result = combiner(result, flags_map[flag_name])
			end
		end

		return result
	end

	local function add_flags(handle, tbl)
		local ptr = ffi.C.GetStdHandle(handle)

		if ptr == nil then throw_error() end

		local flags = ffi.new("uint16_t[1]")

		if ffi.C.GetConsoleMode(ptr, flags) == 0 then throw_error() end
		local old_flags = tonumber(flags[0])
		flags[0] = table_to_flags(tbl, mode_flags, function(out, val)
			return bit.bor(out, val)
		end)

		if ffi.C.SetConsoleMode(ptr, flags[0]) == 0 then throw_error() end

		return old_flags
	end

	function terminal.WrapFile(input, output)
		input:setvbuf("no")
		output:setvbuf("no")
		-- Set console to UTF-8 (code page 65001)
		ffi.C.SetConsoleOutputCP(65001)
		ffi.C.SetConsoleCP(65001)

		local old_flags_input = add_flags(STD_INPUT_HANDLE, {
			"ENABLE_INSERT_MODE",
		}, mode_flags)

		local old_flags_output = add_flags(
			STD_OUTPUT_HANDLE,
			{
				"ENABLE_PROCESSED_INPUT",
				"ENABLE_VIRTUAL_TERMINAL_PROCESSING",
			},
			mode_flags
		)
		local self = setmetatable(
			{
				input = input,
				output = output,
				event_queue = {},
				old_flags_input = old_flags_input,
				old_flags_output = old_flags_output,
				attribute_stack = {},
				mouse_enabled = false,
			},
			meta
		)
		self:EnableCaret(true)
		return self
	end

	local function revert_flags(handle, old_flags)
		local ptr = ffi.C.GetStdHandle(handle)

		if ptr == nil then throw_error() end

		if ffi.C.SetConsoleMode(ptr, old_flags) == 0 then throw_error() end
	end

	function meta:__gc()
		revert_flags(STD_INPUT_HANDLE, self.old_flags_input)
		revert_flags(STD_OUTPUT_HANDLE, self.old_flags_output)
	end

	function meta:GetSize()
		local out = ffi.new("struct CONSOLE_SCREEN_BUFFER_INFO[1]")
		ffi.C.GetConsoleScreenBufferInfo(stdout, out)
		return out[0].dwSize.X, out[0].dwSize.Y
	end

	local keys = {
		MOD_ALT = 0x0001,
		MOD_CONTROL = 0x0002,
		MOD_SHIFT = 0x0004,
		MOD_WIN = 0x0008,
		MOD_NOREPEAT = 0x4000,
		VK_LBUTTON = 0x01,
		VK_RBUTTON = 0x02,
		VK_CANCEL = 0x03,
		VK_MBUTTON = 0x04,
		VK_XBUTTON1 = 0x05,
		VK_XBUTTON2 = 0x06,
		VK_BACK = 0x08,
		VK_TAB = 0x09,
		VK_CLEAR = 0x0C,
		VK_RETURN = 0x0D,
		VK_SHIFT = 0x10,
		VK_CONTROL = 0x11,
		VK_MENU = 0x12,
		VK_PAUSE = 0x13,
		VK_CAPITAL = 0x14,
		VK_KANA = 0x15,
		VK_JUNJA = 0x17,
		VK_FINAL = 0x18,
		VK_KANJI = 0x19,
		VK_ESCAPE = 0x1B,
		VK_CONVERT = 0x1C,
		VK_NONCONVERT = 0x1D,
		VK_ACCEPT = 0x1E,
		VK_MODECHANGE = 0x1F,
		VK_SPACE = 0x20,
		VK_PRIOR = 0x21,
		VK_NEXT = 0x22,
		VK_END = 0x23,
		VK_HOME = 0x24,
		VK_LEFT = 0x25,
		VK_UP = 0x26,
		VK_RIGHT = 0x27,
		VK_DOWN = 0x28,
		VK_SELECT = 0x29,
		VK_PRINT = 0x2A,
		VK_EXECUTE = 0x2B,
		VK_SNAPSHOT = 0x2C,
		VK_INSERT = 0x2D,
		VK_DELETE = 0x2E,
		VK_HELP = 0x2F,
		VK_LWIN = 0x5B,
		VK_RWIN = 0x5C,
		VK_APPS = 0x5D,
		VK_SLEEP = 0x5F,
		VK_NUMPAD0 = 0x60,
		VK_NUMPAD1 = 0x61,
		VK_NUMPAD2 = 0x62,
		VK_NUMPAD3 = 0x63,
		VK_NUMPAD4 = 0x64,
		VK_NUMPAD5 = 0x65,
		VK_NUMPAD6 = 0x66,
		VK_NUMPAD7 = 0x67,
		VK_NUMPAD8 = 0x68,
		VK_NUMPAD9 = 0x69,
		VK_MULTIPLY = 0x6A,
		VK_ADD = 0x6B,
		VK_SEPARATOR = 0x6C,
		VK_SUBTRACT = 0x6D,
		VK_DECIMAL = 0x6E,
		VK_DIVIDE = 0x6F,
		VK_F1 = 0x70,
		VK_F2 = 0x71,
		VK_F3 = 0x72,
		VK_F4 = 0x73,
		VK_F5 = 0x74,
		VK_F6 = 0x75,
		VK_F7 = 0x76,
		VK_F8 = 0x77,
		VK_F9 = 0x78,
		VK_F10 = 0x79,
		VK_F11 = 0x7A,
		VK_F12 = 0x7B,
		VK_F13 = 0x7C,
		VK_F14 = 0x7D,
		VK_F15 = 0x7E,
		VK_F16 = 0x7F,
		VK_F17 = 0x80,
		VK_F18 = 0x81,
		VK_F19 = 0x82,
		VK_F20 = 0x83,
		VK_F21 = 0x84,
		VK_F22 = 0x85,
		VK_F23 = 0x86,
		VK_F24 = 0x87,
		VK_NUMLOCK = 0x90,
		VK_SCROLL = 0x91,
		VK_OEM_NEC_EQUAL = 0x92,
		VK_LSHIFT = 0xA0,
		VK_RSHIFT = 0xA1,
		VK_LCONTROL = 0xA2,
		VK_RCONTROL = 0xA3,
		VK_LMENU = 0xA4,
		VK_RMENU = 0xA5,
		VK_BROWSER_BACK = 0xA6,
		VK_BROWSER_FORWARD = 0xA7,
		VK_BROWSER_REFRESH = 0xA8,
		VK_BROWSER_STOP = 0xA9,
		VK_BROWSER_SEARCH = 0xAA,
		VK_BROWSER_FAVORITES = 0xAB,
		VK_BROWSER_HOME = 0xAC,
		VK_VOLUME_MUTE = 0xAD,
		VK_VOLUME_DOWN = 0xAE,
		VK_VOLUME_UP = 0xAF,
		VK_MEDIA_NEXT_TRACK = 0xB0,
		VK_MEDIA_PREV_TRACK = 0xB1,
		VK_MEDIA_STOP = 0xB2,
		VK_MEDIA_PLAY_PAUSE = 0xB3,
		VK_LAUNCH_MAIL = 0xB4,
		VK_LAUNCH_MEDIA_SELECT = 0xB5,
		VK_LAUNCH_APP1 = 0xB6,
		VK_LAUNCH_APP2 = 0xB7,
		VK_OEM_1 = 0xBA,
		VK_OEM_PLUS = 0xBB,
		VK_OEM_COMMA = 0xBC,
		VK_OEM_MINUS = 0xBD,
		VK_OEM_PERIOD = 0xBE,
		VK_OEM_2 = 0xBF,
		VK_OEM_3 = 0xC0,
		VK_OEM_4 = 0xDB,
		VK_OEM_5 = 0xDC,
		VK_OEM_6 = 0xDD,
		VK_OEM_7 = 0xDE,
		VK_OEM_8 = 0xDF,
		VK_OEM_AX = 0xE1,
		VK_OEM_102 = 0xE2,
		VK_ICO_HELP = 0xE3,
		VK_ICO_00 = 0xE4,
		VK_PROCESSKEY = 0xE5,
		VK_ICO_CLEAR = 0xE6,
		VK_PACKET = 0xE7,
		VK_OEM_RESET = 0xE9,
		VK_OEM_JUMP = 0xEA,
		VK_OEM_PA1 = 0xEB,
		VK_OEM_PA2 = 0xEC,
		VK_OEM_PA3 = 0xED,
		VK_OEM_WSCTRL = 0xEE,
		VK_OEM_CUSEL = 0xEF,
		VK_OEM_ATTN = 0xF0,
		VK_OEM_FINISH = 0xF1,
		VK_OEM_COPY = 0xF2,
		VK_OEM_AUTO = 0xF3,
		VK_OEM_ENLW = 0xF4,
		VK_OEM_BACKTAB = 0xF5,
		VK_ATTN = 0xF6,
		VK_CRSEL = 0xF7,
		VK_EXSEL = 0xF8,
		VK_EREOF = 0xF9,
		VK_PLAY = 0xFA,
		VK_ZOOM = 0xFB,
		VK_NONAME = 0xFC,
		VK_PA1 = 0xFD,
		VK_OEM_CLEAR = 0xFE,
	}
	local modifiers = {
		CAPSLOCK_ON = 0x0080,
		ENHANCED_KEY = 0x0100,
		LEFT_ALT_PRESSED = 0x0002,
		LEFT_CTRL_PRESSED = 0x0008,
		NUMLOCK_ON = 0x0020,
		RIGHT_ALT_PRESSED = 0x0001,
		RIGHT_CTRL_PRESSED = 0x0004,
		SCROLLLOCK_ON = 0x0040,
		SHIFT_PRESSED = 0x0010,
	}

	function meta:Read()
		local events = ffi.new("unsigned long[1]")
		local rec = ffi.new("struct INPUT_RECORD[128]")

		if ffi.C.PeekConsoleInputW(stdin, rec, 128, events) == 0 then
			error(throw_error())
		end

		if events[0] > 0 then
			local rec = ffi.new("struct INPUT_RECORD[?]", events[0])

			if ffi.C.ReadConsoleInputW(stdin, rec, events[0], events) == 0 then
				error(throw_error())
			end

			return rec, events[0]
		end
	end

	-- Convert Unicode code point to UTF-8 string
	local function utf8_from_uint32(code)
		if code == 0 then return "" end

		if code < 0x80 then
			return string.char(code)
		elseif code < 0x800 then
			return string.char(0xC0 + bit.rshift(code, 6), 0x80 + bit.band(code, 0x3F))
		elseif code < 0x10000 then
			return string.char(
				0xE0 + bit.rshift(code, 12),
				0x80 + bit.band(bit.rshift(code, 6), 0x3F),
				0x80 + bit.band(code, 0x3F)
			)
		elseif code < 0x110000 then
			return string.char(
				0xF0 + bit.rshift(code, 18),
				0x80 + bit.band(bit.rshift(code, 12), 0x3F),
				0x80 + bit.band(bit.rshift(code, 6), 0x3F),
				0x80 + bit.band(code, 0x3F)
			)
		end

		return ""
	end

	-- Convert flag value to table of flag names
	local function flags_to_table(value, flags_map)
		local result = {}

		for name, flag_value in pairs(flags_map) do
			if bit.band(value, flag_value) ~= 0 then result[name] = true end
		end

		return result
	end

	-- Mouse button state flags
	local mouse_buttons = {
		FROM_LEFT_1ST_BUTTON_PRESSED = 0x0001,
		RIGHTMOST_BUTTON_PRESSED = 0x0002,
		FROM_LEFT_2ND_BUTTON_PRESSED = 0x0004,
		FROM_LEFT_3RD_BUTTON_PRESSED = 0x0008,
		FROM_LEFT_4TH_BUTTON_PRESSED = 0x0010,
	}

	local mouse_event_flags = {
		MOUSE_MOVED = 0x0001,
		DOUBLE_CLICK = 0x0002,
		MOUSE_WHEELED = 0x0004,
		MOUSE_HWHEELED = 0x0008,
	}

	function meta:ReadEvent()
		-- Fill the event queue if it's empty
		if #self.event_queue == 0 then
			local events, count = self:Read()

			if events then
				for i = 1, count do
					local evt = events[i - 1]

					if evt.EventType == 1 then -- KEY_EVENT
						if evt.Event.KeyEvent.bKeyDown == 1 then
							local unicode_char = evt.Event.KeyEvent.uChar.UnicodeChar
							local str = utf8_from_uint32(unicode_char)
							local key_code = evt.Event.KeyEvent.wVirtualKeyCode
							local mod = flags_to_table(evt.Event.KeyEvent.dwControlKeyState, modifiers)
							local ctrl = mod.LEFT_CTRL_PRESSED or mod.RIGHT_CTRL_PRESSED
							local shift = mod.SHIFT_PRESSED
							local alt = mod.LEFT_ALT_PRESSED or mod.RIGHT_ALT_PRESSED

							-- Special case for Shift+Alt+D (becomes Ctrl+Delete)
							if shift and alt and evt.Event.KeyEvent.uChar.UnicodeChar == 68 then
								ctrl = true
								shift = false
								alt = false
								key_code = keys.VK_DELETE
							end

							local event = {
								key = "",
								modifiers = {
									ctrl = ctrl,
									shift = shift,
									alt = alt,
								},
							}

							-- Determine the key name
							if key_code == keys.VK_RETURN then
								event.key = "enter"
							elseif key_code == keys.VK_DELETE then
								event.key = "delete"
							elseif key_code == keys.VK_LEFT then
								event.key = "left"
							elseif key_code == keys.VK_RIGHT then
								event.key = "right"
							elseif key_code == keys.VK_UP then
								event.key = "up"
							elseif key_code == keys.VK_DOWN then
								event.key = "down"
							elseif key_code == keys.VK_HOME then
								event.key = "home"
							elseif key_code == keys.VK_END then
								event.key = "end"
							elseif key_code == keys.VK_BACK then
								event.key = "backspace"
							elseif key_code == keys.VK_TAB then
								event.key = "tab"
							elseif key_code == keys.VK_INSERT then
								event.key = "insert"
							elseif key_code == keys.VK_PRIOR then
								event.key = "pageup"
							elseif key_code == keys.VK_NEXT then
								event.key = "pagedown"
							elseif key_code == keys.VK_ESCAPE then
								event.key = "escape"
							elseif key_code >= keys.VK_F1 and key_code <= keys.VK_F12 then
								event.key = "f" .. (key_code - keys.VK_F1 + 1)
							elseif evt.Event.KeyEvent.uChar.UnicodeChar > 31 then
								-- Printable character
								event.key = str
							elseif
								ctrl and
								evt.Event.KeyEvent.uChar.UnicodeChar >= 1 and
								evt.Event.KeyEvent.uChar.UnicodeChar <= 26
							then
								-- Ctrl+letter combinations
								event.key = string.char(evt.Event.KeyEvent.uChar.UnicodeChar + 96)
							else
								-- Skip unknown keys
								event = nil
							end

							if event and event.key ~= "" then
								table.insert(self.event_queue, event)
							end
						end
					elseif evt.EventType == 2 and self.mouse_enabled then -- MOUSE_EVENT
						local mouse_evt = evt.Event.MouseEvent
						local x = mouse_evt.dwMousePosition.X + 1 -- Convert to 1-based
						local y = mouse_evt.dwMousePosition.Y + 1
						local button_state = mouse_evt.dwButtonState
						local event_flags = mouse_evt.dwEventFlags
						local control_state = mouse_evt.dwControlKeyState

						-- Parse modifiers
						local mod = flags_to_table(control_state, modifiers)
						local ctrl = mod.LEFT_CTRL_PRESSED or mod.RIGHT_CTRL_PRESSED
						local shift = mod.SHIFT_PRESSED
						local alt = mod.LEFT_ALT_PRESSED or mod.RIGHT_ALT_PRESSED

						-- Track previous button state for press/release detection
						if not self.last_button_state then
							self.last_button_state = 0
						end

						local event = nil

						-- Check for wheel events
						if bit.band(event_flags, mouse_event_flags.MOUSE_WHEELED) ~= 0 then
							-- High word of button_state contains wheel delta (signed)
							local delta = bit.arshift(button_state, 16)
							event = {
								mouse = true,
								x = x,
								y = y,
								button = delta > 0 and "wheel_up" or "wheel_down",
								action = "pressed",
								modifiers = {ctrl = ctrl, shift = shift, alt = alt},
							}
						-- Check for movement
						elseif bit.band(event_flags, mouse_event_flags.MOUSE_MOVED) ~= 0 then
							event = {
								mouse = true,
								x = x,
								y = y,
								button = "none",
								action = "moved",
								modifiers = {ctrl = ctrl, shift = shift, alt = alt},
							}
						-- Check for button events
						else
							-- Detect button changes
							local changed = bit.bxor(button_state, self.last_button_state)

							if changed ~= 0 then
								local button_name = nil
								local action = nil

								-- Check which button changed
								if bit.band(changed, mouse_buttons.FROM_LEFT_1ST_BUTTON_PRESSED) ~= 0 then
									button_name = "left"
									action = bit.band(button_state, mouse_buttons.FROM_LEFT_1ST_BUTTON_PRESSED) ~= 0 and "pressed" or "released"
								elseif bit.band(changed, mouse_buttons.RIGHTMOST_BUTTON_PRESSED) ~= 0 then
									button_name = "right"
									action = bit.band(button_state, mouse_buttons.RIGHTMOST_BUTTON_PRESSED) ~= 0 and "pressed" or "released"
								elseif bit.band(changed, mouse_buttons.FROM_LEFT_2ND_BUTTON_PRESSED) ~= 0 then
									button_name = "middle"
									action = bit.band(button_state, mouse_buttons.FROM_LEFT_2ND_BUTTON_PRESSED) ~= 0 and "pressed" or "released"
								end

								if button_name then
									event = {
										mouse = true,
										x = x,
										y = y,
										button = button_name,
										action = action,
										modifiers = {ctrl = ctrl, shift = shift, alt = alt},
									}
								end
							end
						end

						self.last_button_state = button_state

						if event then
							table.insert(self.event_queue, event)
						end
					end
				end
			end
		end

		-- Return the first event from the queue
		if #self.event_queue > 0 then return table.remove(self.event_queue, 1) end

		return nil
	end
else
	ffi.cdef("const char *strerror(int errnum)")

	local function lasterror(num)
		num = num or ffi.errno()
		local err = ffi.string(ffi.C.strerror(num))
		err = err == "" and tostring(num) or err
		return err, num
	end

	local termios

	if jit.os ~= "OSX" then
		termios = ffi.typeof([[
            struct
            {
                unsigned int c_iflag;		/* input mode flags */
                unsigned int c_oflag;		/* output mode flags */
                unsigned int c_cflag;		/* control mode flags */
                unsigned int c_lflag;		/* local mode flags */
                unsigned char c_line;			/* line discipline */
                unsigned char c_cc[32];		/* control characters */
                unsigned int c_ispeed;		/* input speed */
                unsigned int c_ospeed;		/* output speed */
            }
        ]])
	else
		termios = ffi.typeof([[
            struct
            {
                unsigned long c_iflag;		/* input mode flags */
                unsigned long c_oflag;		/* output mode flags */
                unsigned long c_cflag;		/* control mode flags */
                unsigned long c_lflag;		/* local mode flags */
                unsigned char c_cc[20];		/* control characters */
                unsigned long c_ispeed;		/* input speed */
                unsigned long c_ospeed;		/* output speed */
            }
        ]])
	end

	ffi.cdef(
		[[
        int tcgetattr(int, $ *);
        int tcsetattr(int, int, const $ *);

        size_t fwrite(const char *ptr, size_t size, size_t nmemb, void *stream);
        size_t fread( char * ptr, size_t size, size_t count, void * stream );

        ssize_t read(int fd, void *buf, size_t count);
        int fileno(void *stream);

        int ferror(void*stream);
    ]],
		termios,
		termios
	)
	local VMIN = 6
	local VTIME = 5
	local TCSANOW = 0
	local flags

	if jit.os ~= "OSX" then
		flags = {
			-- c_lflag (local flags)
			ECHOCTL = 512,
			EXTPROC = 65536,
			ECHOK = 32,
			NOFLSH = 128,
			FLUSHO = 4096,
			ECHONL = 64,
			ECHOE = 16,
			ECHOKE = 2048,
			ECHO = 8,
			ICANON = 2,
			IEXTEN = 32768,
			PENDIN = 16384,
			XCASE = 4,
			ECHOPRT = 1024,
			TOSTOP = 256,
			ISIG = 1,
			-- c_iflag (input flags)
			IXON = 0x00000400, -- Enable XON/XOFF flow control on output
			IXOFF = 0x00001000, -- Enable XON/XOFF flow control on input
			IXANY = 0x00000800, -- Allow any char to restart output
		}
	else
		VMIN = 16
		VTIME = 17
		flags = {
			-- c_lflag (local flags)
			ECHOKE = 0x00000001,
			ECHOE = 0x00000002,
			ECHOK = 0x00000004,
			ECHO = 0x00000008,
			ECHONL = 0x00000010,
			ECHOPRT = 0x00000020,
			ECHOCTL = 0x00000040,
			ISIG = 0x00000080,
			ICANON = 0x00000100,
			ALTWERASE = 0x00000200,
			IEXTEN = 0x00000400,
			EXTPROC = 0x00000800,
			TOSTOP = 0x00400000,
			FLUSHO = 0x00800000,
			NOKERNINFO = 0x02000000,
			PENDIN = 0x20000000,
			NOFLSH = 0x80000000,
			-- c_iflag (input flags)
			IXON = 0x00000200, -- Enable XON/XOFF flow control on output
			IXOFF = 0x00000400, -- Enable XON/XOFF flow control on input
			IXANY = 0x00000800, -- Allow any char to restart output
		}
	end

	local termios_boxed = ffi.typeof("$[1]", termios)

	function terminal.WrapFile(input, output)
		local fd_no = ffi.C.fileno(input)
		input:setvbuf("no")
		output:setvbuf("no")
		local old_attributes = termios_boxed()
		ffi.C.tcgetattr(fd_no, old_attributes)
		local attr = termios_boxed()

		if ffi.C.tcgetattr(fd_no, attr) ~= 0 then error(lasterror(), 2) end

		-- Disable canonical mode, echo, and other local flags
		attr[0].c_lflag = bit.band(
			tonumber(attr[0].c_lflag),
			bit.bnot(
				bit.bor(
					flags.ICANON,
					flags.ECHO,
					flags.ISIG,
					flags.ECHOE,
					flags.ECHOCTL,
					flags.ECHOKE,
					flags.ECHOK
				)
			)
		)
		-- Disable XON/XOFF flow control (allows Ctrl+S and Ctrl+Q to work)
		attr[0].c_iflag = bit.band(
			tonumber(attr[0].c_iflag),
			bit.bnot(
				bit.bor(
					flags.IXON, -- Disable output flow control
					flags.IXOFF, -- Disable input flow control
					flags.IXANY -- Disable restart on any char
				)
			)
		)
		attr[0].c_cc[VMIN] = 0
		attr[0].c_cc[VTIME] = 0

		if ffi.C.tcsetattr(fd_no, TCSANOW, attr) ~= 0 then error(lasterror(), 2) end

		if ffi.C.tcgetattr(fd_no, attr) ~= 0 then error(lasterror(), 2) end

		local self = setmetatable(
			{
				input = input,
				output = output,
				old_attributes = old_attributes,
				attribute_stack = {},
				mouse_enabled = false,
			},
			meta
		)

		if attr[0].c_cc[VMIN] ~= 0 or attr[0].c_cc[VTIME] ~= 0 then
			self:__gc()
			error("unable to make fd non blocking", 2)
		end

		return self
	end

	do
		local winsize = ffi.typeof([[struct {
			unsigned short int ws_row;
			unsigned short int ws_col;
			unsigned short int ws_xpixel;
			unsigned short int ws_ypixel;
		}]])
		ffi.cdef("int ioctl(int fd, unsigned long int req, ...);")
		local TIOCGWINSZ = 0x5413

		if jit.os == "OSX" then TIOCGWINSZ = 0x40087468 end

		local size = ffi.typeof("$[1]", ffi.typeof("$", winsize))()

		function meta:GetSize()
			local fd_no = ffi.C.fileno(self.output)
			local num = ffi.C.ioctl(fd_no, TIOCGWINSZ, size)

			if num ~= 0 then error(lasterror(), 2) end

			return size[0].ws_col, size[0].ws_row
		end
	end

	function meta:Read()
		local char = self.input:read(1)

		if char == "" then return nil end

		return char
	end

	function meta:__gc()
		local fd_no = ffi.C.fileno(self.output)
		local num = ffi.C.tcsetattr(fd_no, TCSANOW, self.old_attributes)

		if num ~= 0 then
			print("terminal:__gc: unable to restore terminal attributes: %s", lasterror())
		end
	end

	-- Mouse tracking state for Unix
	local last_mouse_buttons = {}

	-- Escape sequence parser for macOS
	local escape_buffer = ""
	local escape_sequences = {
		["\27[A"] = "up",
		["\27[B"] = "down",
		["\27[C"] = "right",
		["\27[D"] = "left",
		["\27[H"] = "home",
		["\27[F"] = "end",
		["\27[3~"] = "delete",
		["\27[2~"] = "insert",
		["\27[5~"] = "pageup",
		["\27[6~"] = "pagedown",
		["\27OP"] = "f1",
		["\27OQ"] = "f2",
		["\27OR"] = "f3",
		["\27OS"] = "f4",
		["\27[15~"] = "f5",
		["\27[17~"] = "f6",
		["\27[18~"] = "f7",
		["\27[19~"] = "f8",
		["\27[20~"] = "f9",
		["\27[21~"] = "f10",
		["\27[23~"] = "f11",
		["\27[24~"] = "f12",
	}
	-- CSI sequences with modifiers: \x1b[1;MODIFIERkey
	-- Modifier codes: 2=Shift, 3=Alt, 4=Shift+Alt, 5=Ctrl, 6=Ctrl+Shift, 7=Ctrl+Alt, 8=Ctrl+Shift+Alt
	local csi_keys = {
		A = "up",
		B = "down",
		C = "right",
		D = "left",
		H = "home",
		F = "end",
		P = "f1",
		Q = "f2",
		R = "f3",
		S = "f4",
	}

	local function decode_modifier(mod_code)
		local modifiers = {
			ctrl = false,
			shift = false,
			alt = false,
		}

		if mod_code >= 5 then
			modifiers.ctrl = true
			mod_code = mod_code - 4
		end

		if mod_code >= 3 then
			modifiers.alt = true
			mod_code = mod_code - 2
		end

		if mod_code >= 2 then modifiers.shift = true end

		return modifiers
	end

	-- Get byte length of UTF-8 character from its first byte
	local function utf8_byte_length(c)
		local byte = c:byte()

		if byte < 0x80 then
			return 1
		elseif byte < 0xE0 then
			return 2
		elseif byte < 0xF0 then
			return 3
		elseif byte < 0xF8 then
			return 4
		else
			return nil
		end
	end

	-- Parse SGR (1006) mouse format: \x1b[<button;x;y[Mm]
	local function parse_sgr_mouse(seq)
		local button_code, x, y, action_char = seq:match("^\27%[<(%d+);(%d+);(%d+)([Mm])$")
		if not button_code then return nil end

		button_code = tonumber(button_code)
		x = tonumber(x)
		y = tonumber(y)

		-- Check for motion bit (0x20 = 32)
		local has_motion = bit.band(button_code, 0x20) ~= 0

		-- Parse button
		local button_base = bit.band(button_code, 0x03)
		local button_name
		if bit.band(button_code, 0x40) ~= 0 then
			-- Wheel event
			button_name = (button_base == 0) and "wheel_up" or "wheel_down"
		elseif button_base == 0 then
			button_name = "left"
		elseif button_base == 1 then
			button_name = "middle"
		elseif button_base == 2 then
			button_name = "right"
		else
			button_name = "none"
		end

		-- Parse modifiers
		local shift = bit.band(button_code, 0x04) ~= 0
		local alt = bit.band(button_code, 0x08) ~= 0
		local ctrl = bit.band(button_code, 0x10) ~= 0

		-- Parse action
		local action
		if has_motion then
			-- Motion bit is set - this is a drag/move event
			action = "moved"
		elseif action_char == "M" then
			-- 'M' without motion bit = pressed
			action = (button_name == "wheel_up" or button_name == "wheel_down") and "pressed" or "pressed"
		else
			-- 'm' = released
			action = "released"
		end

		return {
			mouse = true,
			x = x,
			y = y,
			button = button_name,
			action = action,
			modifiers = {ctrl = ctrl, shift = shift, alt = alt},
		}
	end

	function meta:ReadEvent()
		local char = self:Read()

		if not char then return nil end

		-- Handle escape sequences
		if char == "\27" then
			escape_buffer = "\27"

			while true do
				local next_char = self:Read()

				if not next_char then break end

				escape_buffer = escape_buffer .. next_char

				-- Check for SGR mouse sequence: \x1b[<...M or \x1b[<...m
				if escape_buffer:match("^\27%[<[%d;]+[Mm]$") then
					if self.mouse_enabled then
						local mouse_event = parse_sgr_mouse(escape_buffer)
						if mouse_event then
							return mouse_event
						end
					end
					break
				end
				-- Check for CSI sequence with modifiers: \x1b[1;MODkey or \x1b[MODkey
				local mod_code, key_char = escape_buffer:match("^\27%[1;(%d+)([A-Z])$")

				if not mod_code then
					mod_code, key_char = escape_buffer:match("^\27%[(%d+)([A-Z])$")
				end

				if mod_code and key_char and csi_keys[key_char] then
					local modifiers = decode_modifier(tonumber(mod_code))
					return {
						key = csi_keys[key_char],
						modifiers = modifiers,
					}
				end

				-- Check for complete escape sequence
				if escape_sequences[escape_buffer] then
					return {
						key = escape_sequences[escape_buffer],
						modifiers = {ctrl = false, shift = false, alt = false},
					}
				end

				-- Check if it's a tilde-terminated sequence
				if escape_buffer:match("~$") then break end

				-- Check if it's a letter-terminated CSI sequence
				if escape_buffer:match("^\27%[[%d;]*[A-Z]$") then break end

				-- Check if it's an SS3 sequence (alt sequences)
				if escape_buffer:match("^\27O[A-Z]$") then break end
			end

			-- Alt + key combinations (ESC followed by regular character)
			if
				#escape_buffer == 2 and
				escape_buffer:byte(2) >= 32 and
				escape_buffer:byte(2) <= 126
			then
				return {
					key = escape_buffer:sub(2, 2),
					modifiers = {ctrl = false, shift = false, alt = true},
				}
			end

			-- Unknown or incomplete escape sequence
			escape_buffer = ""
			return {
				key = "escape",
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		end

		-- Handle control characters (Ctrl+A through Ctrl+Z)
		local byte = char:byte()

		-- Special characters
		if byte == 127 or byte == 8 then -- DEL or backspace
			return {
				key = "backspace",
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		elseif byte == 9 then -- Tab
			return {
				key = "tab",
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		elseif byte == 13 or byte == 10 then -- Enter
			return {
				key = "enter",
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		end

		-- Regular printable characters
		if byte >= 32 and byte <= 126 then
			return {
				key = char,
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		end

		if byte >= 1 and byte <= 26 then
			local key = string.char(byte + 96) -- Convert to lowercase letter
			return {
				key = key,
				modifiers = {ctrl = true, shift = false, alt = false},
			}
		end

		-- UTF-8 multi-byte character
		local len = utf8_byte_length(char)

		if len and len > 1 then
			local full_char = char

			for i = 2, len do
				local next = self:Read()

				if next then full_char = full_char .. next end
			end

			return {
				key = full_char,
				modifiers = {ctrl = false, shift = false, alt = false},
			}
		end

		return nil
	end
end

-- Detect terminal type
function meta:GetTerminalType()
	if jit.os == "Windows" then
		-- Windows terminal detection
		if os.getenv("WT_SESSION") then
			return "windows-terminal"
		elseif os.getenv("ConEmuPID") then
			return "conemu"
		elseif os.getenv("TERM") == "xterm" then
			-- Likely Mintty (Git Bash, MSYS2, Cygwin)
			return "mintty"
		else
			return os.getenv("TERM") or "unknown"
		end
	else
		-- Unix-like systems (macOS, Linux, BSD, etc.)
		local term_program = os.getenv("TERM_PROGRAM")
		local term = os.getenv("TERM")
		
		if term_program == "iTerm.app" then
			return "iterm2"
		elseif term_program == "Apple_Terminal" then
			return "apple-terminal"
		elseif term == "xterm-kitty" or os.getenv("KITTY_WINDOW_ID") then
			return "kitty"
		elseif term_program == "WezTerm" or os.getenv("WEZTERM_EXECUTABLE") then
			return "wezterm"
		elseif term_program == "vscode" then
			return "vscode"
		elseif os.getenv("KONSOLE_VERSION") then
			return "konsole"
		elseif term == "xterm-256color" or term == "xterm" then
			return "xterm"
		else
			return term or "unknown"
		end
	end
end

-- Base64 encoding helper
local function base64_encode(data)
	local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	return ((data:gsub('.', function(x) 
		local r, b = '', x:byte()
		for i = 8, 1, -1 do
			r = r .. (b % 2^i - b % 2^(i-1) > 0 and '1' or '0')
		end
		return r
	end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
		if #x < 6 then return '' end
		local c = 0
		for i = 1, 6 do
			c = c + (x:sub(i, i) == '1' and 2^(6-i) or 0)
		end
		return b:sub(c+1, c+1)
	end) .. ({ '', '==', '=' })[#data % 3 + 1])
end

-- Write image to terminal
function meta:WriteImage(image_data, options)
	options = options or {}
	local terminal_type = self:GetTerminalType()
	
	if terminal_type == "iterm2" or terminal_type == "wezterm" then
		-- iTerm2 inline images protocol
		local b64 = base64_encode(image_data)
		local opts = "inline=1"
		
		if options.width then
			opts = opts .. ";width=" .. tostring(options.width)
		end
		if options.height then
			opts = opts .. ";height=" .. tostring(options.height)
		end
		if options.preserveAspectRatio ~= nil then
			opts = opts .. ";preserveAspectRatio=" .. (options.preserveAspectRatio and "1" or "0")
		end
		
		self:Write(string.format("\27]1337;File=%s:%s\7", opts, b64))
		
	elseif terminal_type == "kitty" or terminal_type == "konsole" then
		-- Kitty graphics protocol
		local b64 = base64_encode(image_data)
		local cmd = "a=T,f=100" -- action=transmit, format=png
		
		if options.width then
			cmd = cmd .. ",c=" .. tostring(options.width)
		end
		if options.height then
			cmd = cmd .. ",r=" .. tostring(options.height)
		end
		
		-- For large images, we should chunk, but for now keep it simple
		self:Write(string.format("\27_G%s;%s\27\\", cmd, b64))
		
	elseif terminal_type == "windows-terminal" or terminal_type == "mintty" then
		-- Sixel graphics (not implemented yet)
		error("Sixel graphics not yet implemented for " .. terminal_type)
		
	elseif terminal_type == "conemu" then
		-- ConEmu inline images
		local b64 = base64_encode(image_data)
		self:Write(string.format("\27]9;4;st=0;sz=%d;%s\27\\", #image_data, b64))
		
	else
		error("Terminal type '" .. terminal_type .. "' does not support image display")
	end
end

return terminal
