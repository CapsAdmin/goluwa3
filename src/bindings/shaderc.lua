local ffi = require("ffi")
local mod = {}

function mod.find_library()
	-- Internal helper function to attempt loading from a list of names/paths.
	-- It returns the first one that succeeds.
	local function try_load(tbl)
		local errors = {}

		for _, name in ipairs(tbl) do
			local status, lib = pcall(ffi.load, name)

			if status then
				return lib
			else
				-- Store the error message for a comprehensive final error.
				table.insert(errors, "  - tried '" .. name .. "': " .. tostring(lib))
			end
		end

		return nil,
		"Could not load shaderc shared library.\n" .. table.concat(errors, "\n")
	end

	if ffi.os == "OSX" then
		local paths = {}
		local home = os.getenv("HOME")

		if home then
			table.insert(paths, home .. "/VulkanSDK/1.4.328.1/macOS/lib/libshaderc_shared.dylib")
		end

		local vulkan_sdk = os.getenv("VULKAN_SDK")

		-- 1. Prioritize the VULKAN_SDK environment variable, as it's explicit.
		if vulkan_sdk then
			table.insert(paths, vulkan_sdk .. "/lib/libshaderc_shared.dylib")
		end

		-- 2. Check standard Homebrew path for Apple Silicon.
		table.insert(paths, "/opt/homebrew/lib/libshaderc_shared.dylib")
		-- 3. Check standard Homebrew path for Intel Macs.
		table.insert(paths, "/usr/local/lib/libshaderc_shared.dylib")
		-- 4. As a fallback, try loading directly in case it's in the system's default search path.
		table.insert(paths, "libshaderc_shared.dylib")
		return assert(try_load(paths))
	elseif ffi.os == "Windows" then
		-- For Windows, lib.dll is usually in the Vulkan SDK's Bin directory.
		local vulkan_sdk = os.getenv("VULKAN_SDK")
		local paths = {}

		if vulkan_sdk then
			table.insert(paths, vulkan_sdk .. "/Bin/shaderc_shared.dll")
		end

		table.insert(paths, "shaderc_shared.dll") -- Fallback
		return assert(try_load(paths))
	else -- Assuming Linux
		return assert(try_load({"libshaderc_shared.so", "libshaderc_shared.so.1"}))
	end
end

-- Define the shaderc C API for LuaJIT
ffi.cdef[[
    // Opaque handles
    typedef struct shaderc_compiler* shaderc_compiler_t;
    typedef struct shaderc_compile_options* shaderc_compile_options_t;
    typedef struct shaderc_compilation_result* shaderc_compilation_result_t;

    // Enums for shader kind and compilation status
    typedef enum {
        shaderc_glsl_vertex_shader = 0,
        shaderc_glsl_fragment_shader = 1,
        shaderc_glsl_compute_shader = 2,
        shaderc_glsl_geometry_shader = 3,
        shaderc_glsl_tess_control_shader = 4,
        shaderc_glsl_tess_evaluation_shader = 5,
        // ... other shader types
    } shaderc_shader_kind;

    typedef enum {
        shaderc_compilation_status_success = 0,
        shaderc_compilation_status_invalid_stage = 1,
        shaderc_compilation_status_compilation_error = 2,
        shaderc_compilation_status_internal_error = 3,
        // ... other statuses
    } shaderc_compilation_status;

    // Core functions from the shaderc library
    shaderc_compiler_t shaderc_compiler_initialize(void);
    void shaderc_compiler_release(shaderc_compiler_t);

    shaderc_compile_options_t shaderc_compile_options_initialize(void);
    void shaderc_compile_options_release(shaderc_compile_options_t options);

    shaderc_compilation_result_t shaderc_compile_into_spv(
        const shaderc_compiler_t compiler,
        const char* source_text,
        size_t source_text_size,
        shaderc_shader_kind shader_kind,
        const char* input_file_name,
        const char* entry_point_name,
        const shaderc_compile_options_t additional_options);

    void shaderc_result_release(shaderc_compilation_result_t result);
    size_t shaderc_result_get_length(const shaderc_compilation_result_t result);
    const char* shaderc_result_get_bytes(const shaderc_compilation_result_t result);
    shaderc_compilation_status shaderc_result_get_compilation_status(const shaderc_compilation_result_t result);
    const char* shaderc_result_get_error_message(const shaderc_compilation_result_t result);
]]
local lib = mod.find_library()

local function initialize()
    if mod.compiler then return end
	mod.compiler = lib.shaderc_compiler_initialize()

	if mod.compiler == nil then error("Failed to initialize shaderc compiler") end
end

function mod.compile(source, shader_type, entry_point)
    initialize()

	-- Initialize shaderc
	local options = lib.shaderc_compile_options_initialize()

	if options == nil then
		lib.shaderc_compiler_release(mod.compiler)
		error("Failed to initialize shaderc compile options")
	end

	-- Determine shader kind
	local shader_kind
	if shader_type == "vertex" or shader_type == "vert" then
		shader_kind = ffi.C.shaderc_glsl_vertex_shader
	elseif shader_type == "fragment" or shader_type == "frag" then
		shader_kind = ffi.C.shaderc_glsl_fragment_shader
	elseif shader_type == "compute" or shader_type == "comp" then
		shader_kind = ffi.C.shaderc_glsl_compute_shader
	elseif shader_type == "geometry" or shader_type == "geom" then
		shader_kind = ffi.C.shaderc_glsl_geometry_shader
	elseif shader_type == "tess_control" or shader_type == "tesc" then
		shader_kind = ffi.C.shaderc_glsl_tess_control_shader
	elseif shader_type == "tess_evaluation" or shader_type == "tese" then
		shader_kind = ffi.C.shaderc_glsl_tess_evaluation_shader
	else
		-- Default to vertex shader if not specified or use as filename
		shader_kind = ffi.C.shaderc_glsl_vertex_shader
	end

	-- Compile the GLSL shader to SPIR-V
	local result = lib.shaderc_compile_into_spv(
		mod.compiler,
		source,
		#source,
		shader_kind,
		shader_type or "shader.glsl", -- input file name (for error messages)
		entry_point or "main", -- entry point
		options
	)


	-- Check for compilation errors
	local status = lib.shaderc_result_get_compilation_status(result)

	if status ~= ffi.C.shaderc_compilation_status_success then
		local error_message = ffi.string(lib.shaderc_result_get_error_message(result))
		lib.shaderc_result_release(result)
		lib.shaderc_compile_options_release(options)
		lib.shaderc_compiler_release(mod.compiler)
		error(error_message, 2)
	end

	local spirv_size = lib.shaderc_result_get_length(result)
	local spirv_data = lib.shaderc_result_get_bytes(result)

	-- Copy the SPIR-V data before releasing the result
	local spirv_copy = ffi.new("uint8_t[?]", spirv_size)
	ffi.copy(spirv_copy, spirv_data, spirv_size)

    lib.shaderc_result_release(result)
    lib.shaderc_compile_options_release(options)
    --lib.shaderc_compiler_release(mod.compiler)

	return spirv_copy, spirv_size
end

return mod
