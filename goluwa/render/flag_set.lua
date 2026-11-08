local bit = require("bit")
local FlagSet = {}
FlagSet.__index = FlagSet
local BITS_PER_WORD = 32

function FlagSet.New(names)
	local self = setmetatable({names = {}, word_of = {}, mask_of = {}, word_count = 1}, FlagSet)

	for _, name in ipairs(names) do
		self:Add(name)
	end

	return self
end

function FlagSet:Add(name)
	assert(
		type(name) == "string" and name:find("^[%a_][%w_]*$"),
		"flag names must be glsl identifiers: " .. tostring(name)
	)
	assert(not self.word_of[name], "duplicate flag " .. name)
	local index = #self.names
	local word = math.floor(index / BITS_PER_WORD)
	self.names[index + 1] = name
	self.word_of[name] = word
	self.mask_of[name] = bit.lshift(1, index % BITS_PER_WORD)
	self.word_count = word + 1
end

function FlagSet:GetWordCount()
	return self.word_count
end

function FlagSet:GetWord(name)
	return assert(self.word_of[name], "unknown flag " .. tostring(name))
end

function FlagSet:GetMask(name)
	return assert(self.mask_of[name], "unknown flag " .. tostring(name))
end

function FlagSet.GetFieldName(base, word)
	return word == 0 and base or base .. word
end

function FlagSet:GetBlockFields(base)
	local fields = {}

	for word = 0, self.word_count - 1 do
		fields[word + 1] = {FlagSet.GetFieldName(base, word), "int"}
	end

	return fields
end

function FlagSet:Set(words, name, value)
	local word = self:GetWord(name)

	if value then
		words[word] = bit.bor(words[word], self.mask_of[name])
	else
		words[word] = bit.band(words[word], bit.bnot(self.mask_of[name]))
	end
end

function FlagSet:Has(words, name)
	return bit.band(words[self:GetWord(name)], self.mask_of[name]) ~= 0
end

function FlagSet:NewWords()
	local words = {}

	for word = 0, self.word_count - 1 do
		words[word] = 0
	end

	return words
end

function FlagSet:BuildGlsl(base)
	local lines = {}

	for _, name in ipairs(self.names) do
		lines[#lines + 1] = string.format(
			"#define %s ((%s & 0x%x) != 0)",
			name,
			FlagSet.GetFieldName(base, self.word_of[name]),
			self.mask_of[name] % 4294967296
		)
	end

	return table.concat(lines, "\n") .. "\n"
end

return FlagSet
