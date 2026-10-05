--[[HOTRELOAD
os.execute("luajit nattlua.lua test")
]]
local type = _G.type
local table_insert = _G.table.insert
local tostring = _G.tostring
local pairs = _G.pairs
local jit = _G.jit--[[# as jit | nil]]
local jit_options = {}
local GC64 = #tostring({}) == 19
local default_options = {
	maxtrace = 1000,
	maxmcode = 512,
	sizemcode = jit.os == "Windows" or GC64 and 64 or 32,
	maxrecord = 4000,
	maxirconst = 500,
	maxsnap = 500,
	minstitch = 0,
	maxside = 100,
	hotloop = 56,
	hotexit = 10,
	tryside = 4,
	instunroll = 4,
	loopunroll = 15,
	callunroll = 3,
	recunroll = 2,
}
local default_flags = {
	fold = true,
	cse = true,
	dce = true,
	narrow = true,
	loop = true,
	fwd = true,
	dse = true,
	abc = true,
	sink = true,
	fuse = true,
	fma = false,
}
local last_options = {options = {}, flags = {}}

function jit_options.Set(options--[[#: AnyTable | nil]], flags--[[#: AnyTable | nil]])
	if not jit then return end

	options = options or {}
	flags = flags or {}

	do
		for k, v in pairs(options) do
			if default_options[k] == nil then
				error("invalid parameter ." .. k .. "=" .. tostring(v), 2)
			end
		end

		for k, v in pairs(flags) do
			if default_flags[k] == nil then
				error("invalid flag .flags." .. k .. "=" .. tostring(v), 2)
			end
		end
	end

	local p = {}

	for k, v in pairs(default_options) do
		if options[k] == nil then
			p[k] = v
		else
			p[k] = options[k]

			if type(p[k]) ~= "number" then
				error(
					"parameter ." .. k .. "=" .. tostring(options[k]) .. " must be a number or nil",
					2
				)
			end
		end
	end

	local f = {}

	for k, v in pairs(default_flags) do
		if flags[k] == nil then
			f[k] = v
		else
			f[k] = flags[k]

			if type(f[k]) ~= "boolean" then
				error(
					"parameter ." .. k .. "=" .. tostring(options[k]) .. " must be true, false or nil",
					2
				)
			end
		end
	end

	_G.JIT_PARAMS = p
	last_options = {options = p, flags = f}
	local args = {}

	for k, v in pairs(p) do
		table_insert(args, k .. "=" .. tostring(v))
	end

	for k, v in pairs(f) do
		if v then
			table_insert(args, "+" .. k)
		else
			table_insert(args, "-" .. k)
		end
	end

	jit.opt.start(unpack(args))
	jit.flush()
end

function jit_options.Get()
	return last_options
end

function jit_options.SetOptimized()
	jit_options.Set(
		{
			maxtrace = 65535,
			maxmcode = 128000,
			sizemcode = 512 * 10,
			maxrecord = 7000,
			maxirconst = 10000,
			maxsnap = 1500,
			minstitch = 0,
			maxside = 100,
			hotloop = 56,
			hotexit = 10,
			tryside = 4,
			instunroll = 4,
			loopunroll = 40,
			callunroll = 3,
			recunroll = 2,
		},
		{
			fold = true,
			cse = true,
			dce = true,
			narrow = true,
			loop = true,
			fwd = true,
			dse = true,
			abc = true,
			sink = true,
			fuse = true,
			fma = true,
		}
	)
end

return jit_options
