local ffi = require("ffi")
local bit = require("bit")
local CTs = {
	[0] = {
		"int",
		"",
		"size",
		false,
		{0x08000000, "bool"},
		{0x04000000, "float", "subwhat"},
		{0x02000000, "const"},
		{0x01000000, "volatile"},
		{0x00800000, "unsigned"},
		{0x00400000, "long"},
	},
	{
		"struct",
		"",
		"size",
		true,
		{0x02000000, "const"},
		{0x01000000, "volatile"},
		{0x00800000, "union", "subwhat"},
		{0x00100000, "vla"},
	},
	{
		"ptr",
		"element_type",
		"size",
		false,
		{0x02000000, "const"},
		{0x01000000, "volatile"},
		{0x00800000, "ref", "subwhat"},
	},
	{
		"array",
		"element_type",
		"size",
		false,
		{0x08000000, "vector"},
		{0x04000000, "complex"},
		{0x02000000, "const"},
		{0x01000000, "volatile"},
		{0x00100000, "vla"},
	},
	{"void", "", "size", false, {0x02000000, "const"}, {0x01000000, "volatile"}},
	{"enum", "type", "size", true},
	{
		"func",
		"return_type",
		"nargs",
		true,
		{0x00800000, "vararg"},
		{0x00400000, "sse_reg_params"},
	},
	{"typedef", "element_type", "", false},
	{"attrib", "type", "value", true},
	{"field", "type", "offset", true},
	{
		"bitfield",
		"",
		"offset",
		true,
		{0x08000000, "bool"},
		{0x02000000, "const"},
		{0x01000000, "volatile"},
		{0x00800000, "unsigned"},
	},
	{"constant", "type", "value", true, {0x02000000, "const"}},
	{"extern", "CID", "", true},
	{"kw", "TOK", "size"},
}
local type_keys = {
	element_type = true,
	return_type = true,
	value_type = true,
	type = true,
}
local CTAs = {
	[0] = function(a, refct)
		error("TODO: CTA_NONE")
	end,
	function(a, refct)
		error("TODO: CTA_QUAL")
	end,
	function(a, refct)
		a = 2 ^ a.value
		refct.alignment = a
		refct.attributes.align = a
	end,
	function(a, refct)
		refct.transparent = true
		refct.attributes.subtype = refct.typeid
	end,
	function(a, refct)
		refct.sym_name = a.name
	end,
	function(a, refct)
		error("TODO: CTA_BAD")
	end,
}
local CTCCs = {[0] = "cdecl", "thiscall", "fastcall", "stdcall"}

local function refct_from_id(id)
	local ctype = ffi.typeinfo(id)
	local CT_code = bit.rshift(ctype.info, 28)
	local CT = CTs[CT_code]
	local what = CT[1]
	local refct = {
		what = what,
		typeid = id,
		name = ctype.name,
	}

	for i = 5, #CT do
		if bit.band(ctype.info, CT[i][1]) ~= 0 then
			if CT[i][3] == "subwhat" then
				refct.what = CT[i][2]
			else
				refct[CT[i][2]] = true
			end
		end
	end

	if CT_code <= 5 then
		refct.alignment = bit.lshift(1, bit.band(bit.rshift(ctype.info, 16), 15))
	elseif what == "func" then
		refct.convention = CTCCs[bit.band(bit.rshift(ctype.info, 16), 3)]
	end

	if CT[2] ~= "" then
		local k = CT[2]
		local cid = bit.band(ctype.info, 0xffff)

		if type_keys[k] then
			if cid == 0 then cid = nil else cid = refct_from_id(cid) end
		end

		refct[k] = cid
	end

	if CT[3] ~= "" then
		local k = CT[3]
		refct[k] = ctype.size or (k == "size" and "none")
	end

	if what == "attrib" then
		local CTA = CTAs[bit.band(bit.rshift(ctype.info, 16), 0xff)]

		if refct.type then
			local ct = refct.type
			ct.attributes = {}
			CTA(refct, ct)
			ct.typeid = refct.typeid
			refct = ct
		else
			refct.CTA = CTA
		end
	elseif what == "bitfield" then
		refct.offset = refct.offset + bit.band(ctype.info, 127) / 8
		refct.size = bit.band(bit.rshift(ctype.info, 8), 127) / 8
		refct.type = {
			what = "int",
			bool = refct.bool,
			const = refct.const,
			volatile = refct.volatile,
			unsigned = refct.unsigned,
			size = bit.band(bit.rshift(ctype.info, 16), 127),
		}
		refct.bool, refct.const, refct.volatile, refct.unsigned = nil
	end

	if CT[4] then
		while ctype.sib do
			local entry = ffi.typeinfo(ctype.sib)

			if CTs[bit.rshift(entry.info, 28)][1] ~= "attrib" then break end

			if bit.band(entry.info, 0xffff) ~= 0 then break end

			local sib = refct_from_id(ctype.sib)
			sib:CTA(refct)
			ctype = entry
		end
	end

	return refct
end

local function sib_iter(s, refct)
	repeat
		local ctype = ffi.typeinfo(refct.typeid)

		if not ctype.sib then return end

		refct = refct_from_id(ctype.sib)	
	until refct.what ~= "attrib"

	return refct
end

local function siblings(refct)
	while refct.attributes do
		refct = refct_from_id(refct.attributes.subtype or ffi.typeinfo(refct.typeid).sib)
	end

	return sib_iter, nil, refct
end

local function collect_siblings(refct)
	local results = {}

	for sib in siblings(refct) do
		table.insert(results, sib)
	end

	return results
end

local function serialize_type_field(refct, visited, depth)
	if not refct then return nil end

	if depth > 50 then
		return {what = refct.what, typeid = refct.typeid, name = refct.name, truncated = true}
	end

	if visited[refct.typeid] then
		return {
			what = refct.what,
			typeid = refct.typeid,
			name = refct.name,
			circular_ref = true,
		}
	end

	visited[refct.typeid] = true
	local result = serialize_refct_internal(refct, visited, depth + 1)
	visited[refct.typeid] = nil
	return result
end

local function serialize_sibling_list(refct, visited, depth)
	local sibs = collect_siblings(refct)
	local results = {}

	for _, sib in ipairs(sibs) do
		table.insert(results, serialize_refct_internal(sib, visited, depth + 1))
	end

	return results
end

function serialize_refct_internal(refct, visited, depth)
	local result = {
		what = refct.what,
		typeid = refct.typeid,
		name = refct.name,
	}

	for k, v in pairs(refct) do
		local vtype = type(v)

		if
			vtype ~= "table" and
			vtype ~= "function" and
			k ~= "what" and
			k ~= "typeid" and
			k ~= "name"
		then
			result[k] = v
		end
	end

	if refct.element_type then
		result.element_type = serialize_type_field(refct.element_type, visited, depth)
	end

	if refct.return_type then
		result.return_type = serialize_type_field(refct.return_type, visited, depth)
	end

	if refct.type then
		result.type = serialize_type_field(refct.type, visited, depth)
	end

	if refct.what == "struct" or refct.what == "union" then
		result.members = serialize_sibling_list(refct, visited, depth)
	elseif refct.what == "func" then
		result.arguments = serialize_sibling_list(refct, visited, depth)
	elseif refct.what == "enum" then
		result.values = serialize_sibling_list(refct, visited, depth)
	end

	if refct.attributes then
		result.attributes = {}

		for k, v in pairs(refct.attributes) do
			result.attributes[k] = v
		end
	end

	return result
end

function serialize_ctype(ct)
	local refct = refct_from_id(tonumber(ffi.typeof(ct)))
	local visited = {}
	return serialize_refct_internal(refct, visited, 0)
end

local mod = {}
mod.typeof = serialize_ctype
return mod
