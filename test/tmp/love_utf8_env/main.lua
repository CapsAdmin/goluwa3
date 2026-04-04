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
	