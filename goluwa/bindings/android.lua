local ffi = require("ffi")
local android = {}
android.active = os.getenv("ANDROID_ROOT") ~= nil and os.getenv("ANDROID_DATA") ~= nil
local app_address = os.getenv("GOLUWA_ANDROID_APP")

if not android.active or not app_address then return android end

ffi.cdef[[
	int ALooper_pollOnce(int timeoutMillis, int *outFd, int *outEvents, void **outData);
	int32_t ANativeWindow_getWidth(void *window);
	int32_t ANativeWindow_getHeight(void *window);
	int32_t AInputQueue_getEvent(void *queue, void **outEvent);
	int32_t AInputQueue_preDispatchEvent(void *queue, void *event);
	void AInputQueue_finishEvent(void *queue, void *event, int handled);
	int32_t AInputEvent_getType(const void *event);
	int32_t AInputEvent_getSource(const void *event);
	int32_t AMotionEvent_getAction(const void *event);
	size_t AMotionEvent_getPointerCount(const void *event);
	float AMotionEvent_getX(const void *event, size_t pointer_index);
	float AMotionEvent_getY(const void *event, size_t pointer_index);
	int32_t AMotionEvent_getButtonState(const void *event);
	float AMotionEvent_getAxisValue(const void *event, int32_t axis, size_t pointer_index);
	int32_t AKeyEvent_getAction(const void *event);
	int32_t AKeyEvent_getKeyCode(const void *event);
	int32_t AKeyEvent_getMetaState(const void *event);
	int32_t AKeyEvent_getRepeatCount(const void *event);
	int8_t android_app_read_cmd(void *app);
	void android_app_pre_exec_cmd(void *app, int8_t cmd);
	void android_app_post_exec_cmd(void *app, int8_t cmd);
]]
-- public part of struct android_app from the ndk's android_native_app_glue.h
local android_app_ptr_t = ffi.typeof([[struct {
	void *userData;
	void *onAppCmd;
	void *onInputEvent;
	struct {
		void *callbacks;
		void *vm;
		void *env;
		void *clazz;
		const char *internalDataPath;
		const char *externalDataPath;
		int32_t sdkVersion;
		void *instance;
		void *assetManager;
		const char *obbPath;
	} *activity;
	void *config;
	void *savedState;
	size_t savedStateSize;
	void *looper;
	void *inputQueue;
	void *window;
	int32_t contentRect[4];
	int activityState;
	int destroyRequested;
} *]])

do
	local address = ffi.new("uint64_t", 0)

	for digit in app_address:gsub("^0x", ""):gmatch(".") do
		address = address * 16 + tonumber(digit, 16)
	end

	android.app = ffi.cast(android_app_ptr_t, address)
end

android.lib = ffi.load("android")
android.glue = ffi.load("goluwa")
android.APP_CMD = {
	INPUT_CHANGED = 0,
	INIT_WINDOW = 1,
	TERM_WINDOW = 2,
	WINDOW_RESIZED = 3,
	WINDOW_REDRAW_NEEDED = 4,
	CONTENT_RECT_CHANGED = 5,
	GAINED_FOCUS = 6,
	LOST_FOCUS = 7,
	CONFIG_CHANGED = 8,
	LOW_MEMORY = 9,
	START = 10,
	RESUME = 11,
	SAVE_STATE = 12,
	PAUSE = 13,
	STOP = 14,
	DESTROY = 15,
}
android.INPUT_EVENT_TYPE_KEY = 1
android.INPUT_EVENT_TYPE_MOTION = 2
android.INPUT_SOURCE_MOUSE_BITS = 0x2000
android.MOTION_EVENT_ACTION_MASK = 0xff
android.MOTION_EVENT_ACTION_DOWN = 0
android.MOTION_EVENT_ACTION_UP = 1
android.MOTION_EVENT_ACTION_MOVE = 2
android.MOTION_EVENT_ACTION_CANCEL = 3
android.MOTION_EVENT_ACTION_POINTER_DOWN = 5
android.MOTION_EVENT_ACTION_SCROLL = 8
android.MOTION_EVENT_AXIS_VSCROLL = 9
android.MOTION_EVENT_AXIS_HSCROLL = 10
android.KEY_EVENT_ACTION_DOWN = 0
android.KEY_EVENT_ACTION_UP = 1
android.META_SHIFT_ON = 0x1
android.META_ALT_ON = 0x2
android.META_CTRL_ON = 0x1000
android.META_CAPS_LOCK_ON = 0x100000
android.KEYCODES = {
	[4] = "escape",
	[19] = "up",
	[20] = "down",
	[21] = "left",
	[22] = "right",
	[55] = "comma",
	[56] = "period",
	[57] = "left_alt",
	[58] = "right_alt",
	[59] = "left_shift",
	[60] = "right_shift",
	[61] = "tab",
	[62] = "space",
	[66] = "enter",
	[67] = "backspace",
	[68] = "grave_accent",
	[69] = "minus",
	[70] = "equal",
	[71] = "left_bracket",
	[72] = "right_bracket",
	[73] = "backslash",
	[74] = "semicolon",
	[75] = "apostrophe",
	[76] = "slash",
	[92] = "pageup",
	[93] = "pagedown",
	[111] = "escape",
	[112] = "delete",
	[113] = "left_control",
	[114] = "right_control",
	[115] = "caps_lock",
	[116] = "scroll_lock",
	[117] = "left_super",
	[118] = "right_super",
	[120] = "print_screen",
	[121] = "pause",
	[122] = "home",
	[123] = "end",
	[124] = "insert",
	[143] = "num_lock",
	[158] = "numpad_decimal",
	[160] = "numpad_enter",
}
android.KEY_CHARACTERS = {
	[55] = {",", "<"},
	[56] = {".", ">"},
	[62] = {" ", " "},
	[68] = {"`", "~"},
	[69] = {"-", "_"},
	[70] = {"=", "+"},
	[71] = {"[", "{"},
	[72] = {"]", "}"},
	[73] = {"\\", "|"},
	[74] = {";", ":"},
	[75] = {"'", "\""},
	[76] = {"/", "?"},
	[77] = {"@", "@"},
	[158] = {".", "."},
}

do
	local shifted_digits = {")", "!", "@", "#", "$", "%", "^", "&", "*", "("}

	for i = 0, 9 do
		android.KEYCODES[7 + i] = tostring(i)
		android.KEYCODES[144 + i] = "numpad_" .. i
		android.KEY_CHARACTERS[7 + i] = {tostring(i), shifted_digits[i + 1]}
		android.KEY_CHARACTERS[144 + i] = {tostring(i), tostring(i)}
	end

	for i = 0, 25 do
		local letter = string.char(97 + i)
		android.KEYCODES[29 + i] = letter
		android.KEY_CHARACTERS[29 + i] = {letter, letter:upper()}
	end

	for i = 1, 12 do
		android.KEYCODES[130 + i] = "f" .. i
	end
end

do
	-- indices into the JNINativeInterface and JNIInvokeInterface function tables from jni.h
	local JNI_ATTACH_CURRENT_THREAD = 4
	local JNI_PUSH_LOCAL_FRAME = 19
	local JNI_POP_LOCAL_FRAME = 20
	local JNI_GET_OBJECT_CLASS = 31
	local JNI_GET_METHOD_ID = 33
	local JNI_CALL_OBJECT_METHOD_A = 36
	local JNI_CALL_BOOLEAN_METHOD_A = 39
	local JNI_NEW_STRING_UTF = 167
	local JNI_EXCEPTION_CHECK = 228
	local JNI_EXCEPTION_DESCRIBE = 16
	local JNI_EXCEPTION_CLEAR = 17
	local jvalue_array_t = ffi.typeof("union { void *l; int32_t i; uint8_t z; int64_t j; }[?]")
	local attach_t = ffi.typeof("int (*)(void *, void **, void *)")
	local push_frame_t = ffi.typeof("int (*)(void *, int32_t)")
	local pop_frame_t = ffi.typeof("void *(*)(void *, void *)")
	local object_class_t = ffi.typeof("void *(*)(void *, void *)")
	local method_id_t = ffi.typeof("void *(*)(void *, void *, const char *, const char *)")
	local call_object_t = ffi.typeof("void *(*)(void *, void *, void *, const void *)")
	local call_boolean_t = ffi.typeof("uint8_t (*)(void *, void *, void *, const void *)")
	local new_string_t = ffi.typeof("void *(*)(void *, const char *)")
	local exception_check_t = ffi.typeof("uint8_t (*)(void *)")
	local void_env_t = ffi.typeof("void (*)(void *)")
	local env
	local fns

	local function get_env()
		if env then return env end

		local vm = android.app.activity.vm
		local out = ffi.new("void *[1]")
		assert(
			ffi.cast(attach_t, ffi.cast("void ***", vm)[0][JNI_ATTACH_CURRENT_THREAD])(vm, out, nil) == 0,
			"AttachCurrentThread failed"
		)
		env = out[0]
		fns = ffi.cast("void ***", env)[0]
		return env
	end

	local function call_method(object, name, signature, call_t, ...)
		local method = ffi.cast(method_id_t, fns[JNI_GET_METHOD_ID])(
			env,
			ffi.cast(object_class_t, fns[JNI_GET_OBJECT_CLASS])(env, object),
			name,
			signature
		)
		local count = select("#", ...)
		local args = jvalue_array_t(math.max(count, 1))

		for i = 1, count do
			local value = select(i, ...)

			if type(value) == "number" then
				args[i - 1].i = value
			else
				args[i - 1].l = value
			end
		end

		return ffi.cast(
			call_t,
			fns[call_t == call_object_t and
			JNI_CALL_OBJECT_METHOD_A or
			JNI_CALL_BOOLEAN_METHOD_A]
		)(env, object, method, args)
	end

	local function with_input_method_manager(callback)
		get_env()
		ffi.cast(push_frame_t, fns[JNI_PUSH_LOCAL_FRAME])(env, 16)
		local activity = android.app.activity.clazz
		local decor = call_method(
			call_method(activity, "getWindow", "()Landroid/view/Window;", call_object_t),
			"getDecorView",
			"()Landroid/view/View;",
			call_object_t
		)
		local imm = call_method(
			activity,
			"getSystemService",
			"(Ljava/lang/String;)Ljava/lang/Object;",
			call_object_t,
			ffi.cast(new_string_t, fns[JNI_NEW_STRING_UTF])(env, "input_method")
		)
		callback(imm, decor)

		if ffi.cast(exception_check_t, fns[JNI_EXCEPTION_CHECK])(env) ~= 0 then
			ffi.cast(void_env_t, fns[JNI_EXCEPTION_DESCRIBE])(env)
			ffi.cast(void_env_t, fns[JNI_EXCEPTION_CLEAR])(env)
		end

		ffi.cast(pop_frame_t, fns[JNI_POP_LOCAL_FRAME])(env, nil)
	end

	local function show(imm, decor)
		call_method(imm, "showSoftInput", "(Landroid/view/View;I)Z", call_boolean_t, decor, 0)
	end

	local function hide(imm, decor)
		call_method(
			imm,
			"hideSoftInputFromWindow",
			"(Landroid/os/IBinder;I)Z",
			call_boolean_t,
			call_method(decor, "getWindowToken", "()Landroid/os/IBinder;", call_object_t),
			0
		)
	end

	-- ANativeActivity_showSoftInput targets NativeActivity's content view, which the input method service never serves
	function android.ShowSoftKeyboard()
		with_input_method_manager(show)
	end

	function android.HideSoftKeyboard()
		with_input_method_manager(hide)
	end
end

do
	local LOOPER_ID_MAIN = 1
	local LOOPER_ID_INPUT = 2
	local ALOOPER_POLL_CALLBACK = -2
	local out_events = ffi.new("int[1]")
	local out_data = ffi.new("void *[1]")
	local out_event = ffi.new("void *[1]")
	local lib = android.lib
	local glue = android.glue
	local app = android.app

	function android.Poll(timeout_ms, target)
		while true do
			local id = lib.ALooper_pollOnce(timeout_ms, nil, out_events, out_data)
			timeout_ms = 0

			if id == LOOPER_ID_MAIN then
				local cmd = glue.android_app_read_cmd(app)
				glue.android_app_pre_exec_cmd(app, cmd)
				target:OnAndroidCommand(cmd)
				glue.android_app_post_exec_cmd(app, cmd)
			elseif id == LOOPER_ID_INPUT then
				local queue = app.inputQueue

				while lib.AInputQueue_getEvent(queue, out_event) >= 0 do
					local event = out_event[0]

					if lib.AInputQueue_preDispatchEvent(queue, event) == 0 then
						lib.AInputQueue_finishEvent(queue, event, target:OnAndroidInput(event) and 1 or 0)
					end
				end
			elseif id ~= ALOOPER_POLL_CALLBACK then
				return
			end
		end
	end
end

return android
