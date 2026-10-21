local ffi = require("ffi")
local mod = {}

local cdef_done = false
local lib

function mod.Initialize(shaderc_lib)
	if not cdef_done then
		cdef_done = true
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
		        shaderc_glsl_infer_from_source = 6,
		        shaderc_raygen_shader = 14,
		        shaderc_anyhit_shader = 15,
		        shaderc_closesthit_shader = 16,
		        shaderc_miss_shader = 17,
		        shaderc_intersection_shader = 18,
		        shaderc_callable_shader = 19,
		        shaderc_glsl_task_shader = 31,
		        shaderc_glsl_mesh_shader = 32,
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

		    void shaderc_compile_options_set_target_env(
		        shaderc_compile_options_t options,
		        int target,
		        uint32_t version);

		    typedef enum {
		        shaderc_optimization_level_zero = 0,
		        shaderc_optimization_level_size = 1,
		        shaderc_optimization_level_performance = 2,
		    } shaderc_optimization_level;

		    void shaderc_compile_options_set_optimization_level(
		        shaderc_compile_options_t options,
		        shaderc_optimization_level opt_level);

		    void shaderc_compile_options_set_generate_debug_info(
		        shaderc_compile_options_t options,
		        bool generate_debug_info);

		    void shaderc_compile_options_add_compiler_argv(
		        shaderc_compile_options_t options,
		        const char* const argv[],
		        int argc);
		]]


	end

	if mod.compiler then lib.shaderc_compiler_release(mod.compiler) end

	lib = shaderc_lib
	mod.compiler = lib.shaderc_compiler_initialize()

	if mod.compiler == nil then error("Failed to initialize shaderc compiler") end

	mod.initialized = true
end

mod.identity = ""

function mod.compile(source, shader_type, entry_point)
	assert(mod.initialized, "shaderc is not initialized")
	local options = lib.shaderc_compile_options_initialize()

	if options == nil then
		lib.shaderc_compiler_release(mod.compiler)
		error("Failed to initialize shaderc compile options")
	end

	lib.shaderc_compile_options_set_target_env(options, 0, bit.bor(bit.lshift(1, 22), bit.lshift(3, 12)))
	local shader_kind

	if shader_type == "vertex" or shader_type == "vert" then
		shader_kind = ffi.C.shaderc_glsl_vertex_shader
	elseif shader_type == "fragment" or shader_type == "frag" then
		shader_kind = ffi.C.shaderc_glsl_fragment_shader
	elseif shader_type == "compute" or shader_type == "comp" then
		shader_kind = ffi.C.shaderc_glsl_compute_shader
	elseif shader_type == "geometry" or shader_type == "geom" then
		shader_kind = ffi.C.shaderc_glsl_geometry_shader
	elseif
		shader_type == "tess_control" or
		shader_type == "tesc" or
		shader_type == "tessellation_control"
	then
		shader_kind = ffi.C.shaderc_glsl_tess_control_shader
	elseif
		shader_type == "tess_evaluation" or
		shader_type == "tese" or
		shader_type == "tessellation_evaluation"
	then
		shader_kind = ffi.C.shaderc_glsl_tess_evaluation_shader
	elseif shader_type == "raygeneration" or shader_type == "rgen" or shader_type == "rg" then
		shader_kind = ffi.C.shaderc_raygen_shader
	elseif shader_type == "anyhit" or shader_type == "ahit" then
		shader_kind = ffi.C.shaderc_anyhit_shader
	elseif shader_type == "closesthit" or shader_type == "chit" or shader_type == "ch" then
		shader_kind = ffi.C.shaderc_closesthit_shader
	elseif shader_type == "miss" or shader_type == "m" then
		shader_kind = ffi.C.shaderc_miss_shader
	elseif shader_type == "intersection" or shader_type == "rint" then
		shader_kind = ffi.C.shaderc_intersection_shader
	elseif shader_type == "callable" or shader_type == "rcall" then
		shader_kind = ffi.C.shaderc_callable_shader
	elseif shader_type == "task" or shader_type == "task_ext" then
		shader_kind = ffi.C.shaderc_glsl_infer_from_source
	elseif shader_type == "mesh" or shader_type == "mesh_ext" then
		shader_kind = ffi.C.shaderc_glsl_infer_from_source
	else
		shader_kind = ffi.C.shaderc_glsl_vertex_shader
	end

	local file_name = shader_type

	if file_name and not file_name:find("/") and not file_name:find("%.") then
		file_name = shader_type .. ".glsl"
	end

	local result = lib.shaderc_compile_into_spv(
		mod.compiler,
		source,
		#source,
		shader_kind,
		file_name or "shader.glsl",
		entry_point or "main",
		options
	)
	local status = lib.shaderc_result_get_compilation_status(result)

	if status ~= ffi.C.shaderc_compilation_status_success then
		local error_message = ffi.string(lib.shaderc_result_get_error_message(result))

		if error_message == "" then
			error_message = "empty error message, status: " .. tostring(status) .. " (" .. tostring(tonumber(status)) .. ") result: " .. tostring(result) .. " stage: " .. tostring(shader_type)
		end

		local path = "./storage/logs/last_shader_error.glsl"
		import("goluwa/filesystem/fs.lua").write_file(path, source)
		error_message = error_message:gsub(shader_type .. ":", path .. ":")
		lib.shaderc_result_release(result)
		lib.shaderc_compile_options_release(options)
		error("\n" .. error_message, 2)
	end

	local spirv_size = lib.shaderc_result_get_length(result)
	local spirv_data = lib.shaderc_result_get_bytes(result)
	local spirv_copy = ffi.new("uint8_t[?]", spirv_size)
	ffi.copy(spirv_copy, spirv_data, spirv_size)
	lib.shaderc_result_release(result)
	lib.shaderc_compile_options_release(options)
	return spirv_copy, spirv_size
end

return mod
