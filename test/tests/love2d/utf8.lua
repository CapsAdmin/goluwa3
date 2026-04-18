local T = import("test/environment.lua")
local fs = import("goluwa/fs.lua")
local line = import("goluwa/love/line.lua")

T.Test2D("love game environment exposes utf8 compatibility helpers", function()
	local game_dir = "test/tmp/love_utf8_env"
	assert(fs.create_directory_recursive(game_dir))
	assert(fs.write_file(game_dir .. "/main.lua", [[
		assert(utf8.codepoint("A") == 65)
		assert(utf8.len("hello") == 5)
		for pos, codepoint in utf8.codes("ab") do
			if pos == 2 then
				assert(codepoint == 98)
			end
		end
		function love.load()
			UTF8_ENV_VALUE = utf8.char(66)
		end
	]]))

	local love = line.RunGame(game_dir)
	T(love._line_env.globals.UTF8_ENV_VALUE)["=="]("B")
	T(love._line_env.globals.utf8.codepoint("~"))["=="](126)
end)