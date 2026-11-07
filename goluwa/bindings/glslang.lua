local ffi = require("ffi")
local fs = import("goluwa/filesystem/fs.lua")
local mod = {}
local lib
local resource_lib
local resource
local cdef_done = false
local glslang_input_t
local glslang_spv_options_t
local VULKAN_1_3 = bit.bor(bit.lshift(1, 22), bit.lshift(3, 12))
local SPV_1_6 = bit.bor(bit.lshift(1, 16), bit.lshift(6, 8))
local MSG_SPV_RULES = bit.lshift(1, 3)
local MSG_VULKAN_RULES = bit.lshift(1, 4)
local MSG_DEBUG_INFO = bit.lshift(1, 10)
local SOURCE_GLSL = 1
local CLIENT_VULKAN = 1
local TARGET_SPV = 1
local PROFILE_CORE = 2
local DEFAULT_VERSION = 450
local stages = {
	vertex = 0,
	vert = 0,
	tess_control = 1,
	tesc = 1,
	tessellation_control = 1,
	tess_evaluation = 2,
	tese = 2,
	tessellation_evaluation = 2,
	geometry = 3,
	geom = 3,
	fragment = 4,
	frag = 4,
	compute = 5,
	comp = 5,
	raygeneration = 6,
	rgen = 6,
	rg = 6,
	intersection = 7,
	rint = 7,
	anyhit = 8,
	ahit = 8,
	rahit = 8,
	closesthit = 9,
	chit = 9,
	ch = 9,
	rchit = 9,
	miss = 10,
	m = 10,
	rmiss = 10,
	callable = 11,
	rcall = 11,
	task = 12,
	task_ext = 12,
	mesh = 13,
	mesh_ext = 13,
}
mod.identity = ""
mod.debug_info = os.getenv("GOLUWA_SHADER_DEBUG") == "1"

function mod.Initialize(glslang_lib, limits_lib)
	if not cdef_done then
		cdef_done = true
		ffi.cdef[[
			typedef struct glslang_shader_s glslang_shader_t;
			typedef struct glslang_program_s glslang_program_t;
		]]
		glslang_input_t = ffi.typeof([[struct {
			int language;
			int stage;
			int client;
			int client_version;
			int target_language;
			int target_language_version;
			const char *code;
			int default_version;
			int default_profile;
			int force_default_version_and_profile;
			int forward_compatible;
			int messages;
			const void *resource;
			void *include_system;
			void *include_local;
			void *free_include_result;
			void *callbacks_ctx;
		}]])
		glslang_spv_options_t = ffi.typeof([[struct {
			bool generate_debug_info;
			bool strip_debug_info;
			bool disable_optimizer;
			bool optimize_size;
			bool optimize_performance;
			bool disassemble;
			bool validate;
			bool emit_nonsemantic_shader_debug_info;
			bool emit_nonsemantic_shader_debug_source;
			bool compile_only;
			bool optimize_allow_expanded_id_bound;
			const char *compiler_signature;
			const char *command_line_arguments;
			const char *current_working_directory;
		}]])
		ffi.cdef[[
			typedef struct { int major, minor, patch; const char *flavor; } glslang_version_t;
			void glslang_get_version(glslang_version_t *version);
			int glslang_initialize_process(void);
			glslang_shader_t *glslang_shader_create(const void *input);
			void glslang_shader_delete(glslang_shader_t *shader);
			int glslang_shader_preprocess(glslang_shader_t *shader, const void *input);
			int glslang_shader_parse(glslang_shader_t *shader, const void *input);
			const char *glslang_shader_get_info_log(glslang_shader_t *shader);
			const char *glslang_shader_get_info_debug_log(glslang_shader_t *shader);
			glslang_program_t *glslang_program_create(void);
			void glslang_program_delete(glslang_program_t *program);
			void glslang_program_add_shader(glslang_program_t *program, glslang_shader_t *shader);
			int glslang_program_link(glslang_program_t *program, int messages);
			const char *glslang_program_get_info_log(glslang_program_t *program);
			const char *glslang_program_get_info_debug_log(glslang_program_t *program);
			void glslang_program_SPIRV_generate_with_options(glslang_program_t *program, int stage, const void *options);
			size_t glslang_program_SPIRV_get_size(glslang_program_t *program);
			void glslang_program_SPIRV_get(glslang_program_t *program, unsigned int *out);
			const char *glslang_program_SPIRV_get_messages(glslang_program_t *program);
			const void *glslang_default_resource(void);
		]]
	end

	assert(glslang_lib.glslang_initialize_process() ~= 0, "glslang_initialize_process failed")
	lib = glslang_lib
	resource_lib = limits_lib
	resource = resource_lib.glslang_default_resource()
	local version = ffi.new("glslang_version_t")
	lib.glslang_get_version(version)
	mod.identity = string.format("glslang %d.%d.%d", version.major, version.minor, version.patch)
	mod.initialized = true
end

do
	local function log_text(shader_or_program, get_log, get_debug_log)
		local text = ffi.string(get_log(shader_or_program))
		local debug_text = ffi.string(get_debug_log(shader_or_program))

		if debug_text ~= "" then text = text .. "\n" .. debug_text end

		return text
	end

	local function fail(source, text)
		local path = "./storage/logs/last_shader_error.glsl"
		fs.write_file(path, source)
		error("\n" .. text:gsub("(%u+): %d+:(%d+):", "%1: " .. path .. ":%2:"), 3)
	end

	local options

	function mod.compile(source, shader_type)
		assert(mod.initialized, "glslang is not initialized")
		local stage = assert(stages[shader_type], "unknown shader type " .. tostring(shader_type))
		local messages = bit.bor(MSG_SPV_RULES, MSG_VULKAN_RULES)

		if mod.debug_info then messages = bit.bor(messages, MSG_DEBUG_INFO) end

		local code = ffi.new("char[?]", #source + 1)
		ffi.copy(code, source, #source)
		local input = glslang_input_t()
		input.language = SOURCE_GLSL
		input.stage = stage
		input.client = CLIENT_VULKAN
		input.client_version = VULKAN_1_3
		input.target_language = TARGET_SPV
		input.target_language_version = SPV_1_6
		input.code = code
		input.default_version = DEFAULT_VERSION
		input.default_profile = PROFILE_CORE
		input.messages = messages
		input.resource = resource
		local shader = lib.glslang_shader_create(input)

		if
			lib.glslang_shader_preprocess(shader, input) == 0 or
			lib.glslang_shader_parse(shader, input) == 0
		then
			local text = log_text(
				shader,
				lib.glslang_shader_get_info_log,
				lib.glslang_shader_get_info_debug_log
			)
			lib.glslang_shader_delete(shader)
			fail(source, text)
		end

		local program = lib.glslang_program_create()
		lib.glslang_program_add_shader(program, shader)

		if lib.glslang_program_link(program, messages) == 0 then
			local text = log_text(
				program,
				lib.glslang_program_get_info_log,
				lib.glslang_program_get_info_debug_log
			)
			lib.glslang_program_delete(program)
			lib.glslang_shader_delete(shader)
			fail(source, text)
		end

		options = options or glslang_spv_options_t()
		options.disable_optimizer = true
		options.generate_debug_info = mod.debug_info
		options.emit_nonsemantic_shader_debug_info = mod.debug_info
		options.emit_nonsemantic_shader_debug_source = mod.debug_info
		lib.glslang_program_SPIRV_generate_with_options(program, stage, options)
		local size = tonumber(lib.glslang_program_SPIRV_get_size(program)) * 4
		local spirv = ffi.new("uint8_t[?]", size)
		lib.glslang_program_SPIRV_get(program, ffi.cast("unsigned int *", spirv))
		lib.glslang_program_delete(program)
		lib.glslang_shader_delete(shader)
		return spirv, size
	end
end

return mod
