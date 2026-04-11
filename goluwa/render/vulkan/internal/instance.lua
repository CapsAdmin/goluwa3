local ffi = require("ffi")
local prototype = import("goluwa/prototype.lua")
local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
local PhysicalDevice = import("goluwa/render/vulkan/internal/physical_device.lua")
local Instance = prototype.CreateTemplate("vulkan_instance")
local CallbackState

do
	local ffi = require("ffi")
	local setmetatable = import("goluwa/helpers/setmetatable_gc.lua")
	local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
	CallbackState = {}
	local meta = {}
	meta.__index = meta
	ffi.cdef[[
		typedef struct lua_State lua_State;
		typedef struct lua_Debug {
			int event;
			const char *name;
			const char *namewhat;
			const char *what;
			const char *source;
			int currentline;
			int nups;
			int linedefined;
			int lastlinedefined;
			char short_src[60];
			int i_ci;
		} lua_Debug;
		lua_State *luaL_newstate(void);
		void luaL_openlibs(lua_State *L);
		void lua_close(lua_State *L);
		int luaL_loadstring(lua_State *L, const char *s);
		int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
		void lua_settop(lua_State *L, int index);
		const char *lua_tolstring(lua_State *L, int index, size_t *len);
		const void *lua_topointer(lua_State *L, int index);
		int lua_getstack(lua_State *L, int level, lua_Debug *ar);
		int lua_getinfo(lua_State *L, const char *what, lua_Debug *ar);

		typedef struct {
			lua_State *main_state;
			lua_State *trace_state;
		} goluwa_vk_debug_context;
	]]
	local callback_source = [=[
		jit.off()
		local ffi = require("ffi")

		if rawget(_G, "import") == nil or rawget(_G, "require") == nil then
			require("goluwa.global_environment")
		end

		local vulkan = import("goluwa/render/vulkan/internal/vulkan.lua")
		local VkDebugUtilsMessageTypeFlagBitsEXT = vulkan.vk.str.VkDebugUtilsMessageTypeFlagBitsEXT
		local VkDebugUtilsMessageSeverityFlagBitsEXT = vulkan.vk.str.VkDebugUtilsMessageSeverityFlagBitsEXT
		local ffi_string = ffi.string
		local VK_FALSE = vulkan.vk.VK_FALSE
		local io_write = io.write
		local io_flush = io.flush
		local string_format = string.format
		local table_concat = table.concat
		local ipairs = ipairs
		local ffi_new = ffi.new

		ffi.cdef[[
			typedef struct lua_State lua_State;
			typedef struct lua_Debug {
				int event;
				const char *name;
				const char *namewhat;
				const char *what;
				const char *source;
				int currentline;
				int nups;
				int linedefined;
				int lastlinedefined;
				char short_src[60];
				int i_ci;
			} lua_Debug;
			int lua_getstack(lua_State *L, int level, lua_Debug *ar);
			int lua_getinfo(lua_State *L, const char *what, lua_Debug *ar);

			typedef struct {
				lua_State *main_state;
				lua_State *trace_state;
			} goluwa_vk_debug_context;
		]]

		local suppressed_warnings = {
			"vk_loader_settings.json",
			"Path to given binary",
			"terminator_CreateInstance",
		}

		local function get_traceback(ctx)
			if ctx == nil or ctx.main_state == nil then return nil end

			local frames = {}
			local ar = ffi_new("lua_Debug[1]")
			local level = 0

			while level < 64 and ffi.C.lua_getstack(ctx.main_state, level, ar) ~= 0 do
				if ffi.C.lua_getinfo(ctx.main_state, "Sl", ar) == 0 then break end

				local info = ar[0]
				local short_src = ffi_string(info.short_src)
				local what = info.what ~= nil and ffi_string(info.what) or "?"
				local line = info.currentline >= 0 and info.currentline or info.linedefined
				if what == "Lua" then
					frames[#frames + 1] = string_format("\t%s:%d", short_src, line)
				end
				level = level + 1
			end

			if #frames == 0 then return nil end

			return table_concat(frames, "\n")
		end

		local function debug_callback(messageSeverity, messageType, pCallbackData, pUserData)
			local data = pCallbackData[0]
			local type_flags = table_concat(VkDebugUtilsMessageTypeFlagBitsEXT(messageType), "|")
			local severity_flags = table_concat(VkDebugUtilsMessageSeverityFlagBitsEXT(messageSeverity), "|")
			local msg = ffi_string(data.pMessage)
			
			for _, pattern in ipairs(suppressed_warnings) do
				if msg:find(pattern, nil, true) then return VK_FALSE end
			end

			io_write("\n[" .. severity_flags .. "] [" .. type_flags .. "]\n" .. msg)


			if pUserData ~= nil then
				io_write("Lua stack trace:\n")
				local trace = get_traceback(ffi.cast("goluwa_vk_debug_context*", pUserData))
				io_write(trace)
			end

			io_write("\n")
			io_flush()
			return VK_FALSE
		end

		_G.__goluwa_vk_debug_callback = debug_callback
		_G.__goluwa_vk_debug_callback_ptr = ffi.cast(vulkan.vk.PFN_vkDebugUtilsMessengerCallbackEXT, debug_callback)
		return ffi.new("uintptr_t[1]", ffi.cast("uintptr_t", _G.__goluwa_vk_debug_callback_ptr))
	]=]

	local function check_error(L, ret)
		if ret == 0 then return end

		local chr = ffi.C.lua_tolstring(L, -1, nil)
		local msg = chr ~= nil and ffi.string(chr) or "unknown Lua state error"
		error(msg, 3)
	end

	local function create_state()
		local L = ffi.C.luaL_newstate()

		if L == nil then
			error("Failed to create debug callback Lua state: Out of memory", 3)
		end

		ffi.C.luaL_openlibs(L)
		return L
	end

	local function get_main_lua_state()
		local ptr = rawget(_G, "__goluwa_main_lua_state_ptr")

		if ptr ~= nil then return ffi.cast("lua_State*", ptr) end

		local thread = coroutine.running()

		if thread == nil then return nil end

		local addr = tostring(thread):match("0x%x+")

		if addr == nil then return nil end

		return ffi.cast("lua_State*", tonumber(addr))
	end

	function CallbackState.New()
		local self = setmetatable({}, meta)
		local L = create_state()
		self.lua_state = L
		self.main_state = get_main_lua_state()
		self.context = ffi.new("goluwa_vk_debug_context[1]")
		self.context[0].main_state = self.main_state
		self.context[0].trace_state = nil
		check_error(L, ffi.C.luaL_loadstring(L, callback_source))
		check_error(L, ffi.C.lua_pcall(L, 0, 1, 0))
		local ptr = ffi.C.lua_topointer(L, -1)
		local box = ffi.cast("uintptr_t*", ptr)
		self.debug_callback_ptr = ffi.cast(vulkan.vk.PFN_vkDebugUtilsMessengerCallbackEXT, box[0])
		ffi.C.lua_settop(L, 0)
		return self
	end

	function meta:GetDebugCallbackPointer()
		return self.debug_callback_ptr
	end

	function meta:GetUserDataPointer()
		return self.context
	end

	function meta:Close()
		if not self.lua_state then return end

		self.debug_callback_ptr = nil
		ffi.C.lua_close(self.lua_state)
		self.lua_state = nil
		self.context = nil
		self.main_state = nil
	end

	meta.__gc = meta.Close
end

function Instance:CreateDebugCallback()
	self.debug_callback_state = CallbackState.New()
	return self.debug_callback_state:GetDebugCallbackPointer()
end

function Instance:GetDebugCallbackUserData()
	if not self.debug_callback_state then return nil end

	return self.debug_callback_state:GetUserDataPointer()
end

function Instance.New(extensions, layers)
	local self = Instance:CreateObject({})
	local version = vulkan.vk.VK_API_VERSION_1_4
	local appInfo = vulkan.vk.s.ApplicationInfo{
		pApplicationName = "MoltenVK LuaJIT Example",
		applicationVersion = 1,
		pEngineName = "No Engine",
		engineVersion = 1,
		apiVersion = version,
	}
	-- Add debug utils extension if validation layers are enabled
	local has_validation = layers and #layers > 0

	if has_validation then
		extensions = extensions or {}
		local has_debug_utils = false

		for _, ext in ipairs(extensions) do
			if ext == "VK_EXT_debug_utils" then
				has_debug_utils = true

				break
			end
		end

		if not has_debug_utils then
			local new_extensions = {}

			for i, ext in ipairs(extensions) do
				new_extensions[i] = ext
			end

			table.insert(new_extensions, "VK_EXT_debug_utils")
			extensions = new_extensions
		end
	end

	local extension_names = extensions and
		vulkan.T.Array(ffi.typeof("const char*"), #extensions, extensions) or
		nil
	local layer_names = layers and vulkan.T.Array(ffi.typeof("const char*"), #layers, layers) or nil
	-- Create debug messenger create info
	local debug_create_info

	if has_validation then
		debug_create_info = vulkan.vk.s.DebugUtilsMessengerCreateInfoEXT{
			flags = 0,
			messageSeverity = {"warning_ext", "error_ext"},
			messageType = {"general_ext", "validation_ext", "performance_ext"},
			pfnUserCallback = self:CreateDebugCallback(),
			pUserData = self:GetDebugCallbackUserData(),
		}
		self.debug_create_info_ref = debug_create_info
	end

	-- Only use portability enumeration on macOS
	local instance_flags = 0

	if jit.os == "OSX" then instance_flags = "enumerate_portability_khr" end

	local ptr = vulkan.T.Box(vulkan.vk.VkInstance)()
	vulkan.assert(
		vulkan.lib.vkCreateInstance(
			vulkan.vk.s.InstanceCreateInfo{
				pNext = has_validation and debug_create_info or nil,
				flags = instance_flags,
				pApplicationInfo = appInfo,
				enabledLayerCount = layers and #layers or 0,
				ppEnabledLayerNames = layer_names,
				enabledExtensionCount = extensions and #extensions or 0,
				ppEnabledExtensionNames = extension_names,
			},
			nil,
			ptr
		),
		"failed to create vulkan instance"
	)
	self.ptr = ptr

	-- Create debug messenger
	if has_validation and self:HasExtension("vkCreateDebugUtilsMessengerEXT") then
		local vkCreateDebugUtilsMessengerEXT = self:GetExtension("vkCreateDebugUtilsMessengerEXT")
		local messenger_ptr = vulkan.T.Box(vulkan.vk.VkDebugUtilsMessengerEXT)()
		vulkan.assert(
			vkCreateDebugUtilsMessengerEXT(ptr[0], debug_create_info, nil, messenger_ptr),
			"failed to create debug messenger"
		)
		self.debug_messenger = messenger_ptr
		self.vkDestroyDebugUtilsMessengerEXT = self:GetExtension("vkDestroyDebugUtilsMessengerEXT")
	end

	return self
end

function Instance:OnRemove()
	if self.debug_messenger then
		self.vkDestroyDebugUtilsMessengerEXT(self.ptr[0], self.debug_messenger[0], nil)
	end

	if self.debug_callback_state then
		self.debug_callback_state:Close()
		self.debug_callback_state = nil
	end

	vulkan.lib.vkDestroyInstance(self.ptr[0], nil)
end

function Instance:GetPhysicalDevices()
	local deviceCount = ffi.new("uint32_t[1]", 0)
	vulkan.assert(
		vulkan.lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, nil),
		"failed to enumerate physical devices"
	)

	if deviceCount[0] == 0 then error("no physical devices found") end

	local physicalDevices = vulkan.T.Array(vulkan.vk.VkPhysicalDevice)(deviceCount[0])
	vulkan.assert(
		vulkan.lib.vkEnumeratePhysicalDevices(self.ptr[0], deviceCount, physicalDevices),
		"failed to enumerate physical devices"
	)
	local out = {}

	for i = 0, deviceCount[0] - 1 do
		out[i + 1] = PhysicalDevice.New(physicalDevices[i])
	end

	return out
end

function Instance:HasExtension(name)
	local func_ptr = vulkan.lib.vkGetInstanceProcAddr(self.ptr[0], name)
	return func_ptr ~= nil
end

function Instance:GetExtension(name)
	local func_ptr = vulkan.lib.vkGetInstanceProcAddr(self.ptr[0], name)

	if func_ptr == nil then error("extension function not found", 2) end

	return ffi.cast(vulkan.vk["PFN_" .. name], func_ptr)
end

return Instance:Register()
