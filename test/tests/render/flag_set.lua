local T = import("test/environment.lua")
local FlagSet = import("goluwa/render/flag_set.lua")
local glsl_meta = import("goluwa/render/glsl_metadata.lua")

local function names(count)
	local list = {}

	for i = 1, count do
		list[i] = "Flag" .. i
	end

	return list
end

T.Test("flag set fills a word and then starts the next one", function()
	local set = FlagSet.New(names(32))
	T(set:GetWordCount())["=="](1)
	T(set:GetWord("Flag32"))["=="](0)
	T(set:GetMask("Flag32"))["=="](-2147483648)
	set:Add("Flag33")
	T(set:GetWordCount())["=="](2)
	T(set:GetWord("Flag33"))["=="](1)
	T(set:GetMask("Flag33"))["=="](1)
end)

T.Test("flag set refuses duplicate, malformed and unknown names", function()
	local set = FlagSet.New{"A"}
	T(pcall(set.Add, set, "A"))["=="](false)
	T(pcall(set.Add, set, "not valid"))["=="](false)
	T(pcall(set.GetWord, set, "B"))["=="](false)
end)

T.Test("flag set packs words and emits glsl for every word", function()
	local set = FlagSet.New(names(40))
	local words = set:NewWords()
	set:Set(words, "Flag3", true)
	set:Set(words, "Flag35", true)
	T(set:Has(words, "Flag3"))["=="](true)
	T(set:Has(words, "Flag35"))["=="](true)
	T(set:Has(words, "Flag4"))["=="](false)
	T(words[0])["=="](4)
	T(words[1])["=="](4)
	set:Set(words, "Flag3", false)
	T(words[0])["=="](0)
	local glsl = set:BuildGlsl("model.Flags")
	T(glsl:find("#define Flag3 ((model.Flags & 0x4) != 0)", 1, true) ~= nil)["=="](true)
	T(glsl:find("#define Flag32 ((model.Flags & 0x80000000) != 0)", 1, true) ~= nil)["=="](true)
	T(glsl:find("#define Flag35 ((model.Flags1 & 0x4) != 0)", 1, true) ~= nil)["=="](true)
end)

T.Test("pipeline blocks expand a flag set field into one int per word", function()
	local set = FlagSet.New(names(70))
	local flat = glsl_meta.flatten_fields{{"Other", "float"}, {"Flags", set}, {"Tail", "int"}}
	local out = {}

	for i, field in ipairs(flat) do
		out[i] = field[1] .. ":" .. field[2]
	end

	T(table.concat(out, " "))["=="]("Other:float Flags:int Flags1:int Flags2:int Tail:int")
end)
