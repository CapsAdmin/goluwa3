local args = ...
local config = {commands = {}}
config.commands["build"] = {
	cb = function()
		local nl = require("nattlua")
		local builder = assert(
			nl.File(
				"glw",
				{
					parser = {
						working_directory = "./",
						emit_environment = false,
						cache_imports_like_require = true,
					},
				}
			)
		)
		assert(builder:Lex())
		assert(builder:Parse())
		--assert(builder:Analyze())
		local code, err = builder:Emit{
			pretty_print = true,
			no_newlines = false,
			omit_invalid_code = true,
			comment_type_annotations = true,
			type_annotations = false,
			force_parenthesis = true,
			module_encapsulation_method = "loadstring",
		}
		local file = assert(io.open("out.lua", "w"))
		file:write(code)
		file:close()
	end,
}
config.commands["get-compiler-config"] = {
	cb = function()
		do
			return
		end -- disable for now
		return {
			lsp = {
				entry_point = "glw",
				analyze = false, -- disables Analyze()
			-- parse_only = true, -- alias, same effect
			},
			parser = {
				working_directory = "./",
				emit_environment = false,
			},
			analyzer = {
				working_directory = "./",
			},
		}
	end,
}
return config