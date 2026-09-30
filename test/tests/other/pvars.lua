local test = import("goluwa/test.lua")
local attest = import("goluwa/attest.lua")
local pvars = import("goluwa/cli/pvars.lua")
local calls

local function setup(info)
	info.store = false
	return pvars.Setup2(info)
end

test.Test("pvars get returns the default and set changes it", function()
	local var = setup{key = "__test_pvar_basic", default = 3}
	attest.equal(var:Get(), 3)
	var:Set(5)
	attest.equal(var:Get(), 5)
	attest.equal(pvars.Get("__test_pvar_basic"), 5)
	var:Set(nil)
	attest.equal(var:Get(), 3)
end)

test.Test("pvars false is a value and not a missing one", function()
	local var = setup{key = "__test_pvar_false", default = true}
	var:Set(false)
	attest.equal(var:Get(), false)
	attest.equal(pvars.GetString("__test_pvar_false"), "false")
end)

test.Test("pvars set rejects the wrong type", function()
	local var = setup{key = "__test_pvar_type", default = 1}
	attest.equal(pcall(var.Set, var, "nope"), false)
	attest.equal(var:Get(), 1)
end)

test.Test("pvars set rejects unknown keys", function()
	attest.equal(pcall(pvars.Set, "__test_pvar_unknown", 1), false)
end)

test.Test("pvars enums restrict values", function()
	local var = setup{key = "__test_pvar_enum", default = "b", enums = {"a", "b", "c"}}
	var:Set("c")
	attest.equal(var:Get(), "c")
	attest.equal(pcall(var.Set, var, "d"), false)
	attest.equal(var:Get(), "c")
end)

test.Test("pvars enums must contain the default", function()
	attest.equal(
		pcall(pvars.Setup2, {key = "__test_pvar_bad_enum", default = "z", enums = {"a"}}),
		false
	)
end)

test.Test("pvars numbers are clamped and rounded", function()
	local var = setup{key = "__test_pvar_range", default = 5, min = 1, max = 10, integer = true}
	var:Set(100)
	attest.equal(var:Get(), 10)
	var:Set(-4)
	attest.equal(var:Get(), 1)
	var:Set(2.6)
	attest.equal(var:Get(), 3)
end)

test.Test("pvars without a default need a type and can be unset", function()
	attest.equal(pcall(pvars.Setup2, {key = "__test_pvar_no_type"}), false)
	local var = setup{key = "__test_pvar_nilable", type = "number"}
	attest.equal(var:Get(), nil)
	var:Set(7)
	attest.equal(var:Get(), 7)
	var:Set(nil)
	attest.equal(var:Get(), nil)
end)

test.Test("pvars callbacks get the new value", function()
	calls = {}
	local var = setup{
		key = "__test_pvar_callback",
		default = 1,
		callback = function(value, is_init)
			if not is_init then calls[#calls + 1] = value end
		end,
	}
	var:Set(2)
	var:Set(3)
	attest.equal(#calls, 2)
	attest.equal(calls[1], 2)
	attest.equal(calls[2], 3)
end)

test.Test("pvars set from strings parses booleans and numbers", function()
	setup{key = "__test_pvar_str_bool", default = false}
	setup{key = "__test_pvar_str_num", default = 0}
	setup{key = "__test_pvar_str_str", default = "x"}
	pvars.SetString("__test_pvar_str_bool", "on")
	attest.equal(pvars.Get("__test_pvar_str_bool"), true)
	pvars.SetString("__test_pvar_str_bool", "0")
	attest.equal(pvars.Get("__test_pvar_str_bool"), false)
	pvars.SetString("__test_pvar_str_num", "2.5")
	attest.equal(pvars.Get("__test_pvar_str_num"), 2.5)
	pvars.SetString("__test_pvar_str_str", "hello world")
	attest.equal(pvars.Get("__test_pvar_str_str"), "hello world")
	attest.equal(pcall(pvars.SetString, "__test_pvar_str_num", "abc"), false)
	attest.equal(pcall(pvars.SetString, "__test_pvar_str_bool", "maybe"), false)
end)

test.Test("pvars groups are applied and friendly names strip the prefix", function()
	pvars.StartGroup("__test_group", {store = false})
	local a = pvars.Setup2{key = "__test_group_alpha_beta", default = 1}
	local b = pvars.Setup2{key = "r___test_group_gamma", default = 1, group = "other_group"}
	pvars.EndGroup()
	local c = setup{key = "__test_lonely", default = 1}
	attest.equal(a:GetGroup(), "__test_group")
	attest.equal(a:GetInfo().friendly, "alpha beta")
	attest.equal(a:GetInfo().store, false)
	attest.equal(b:GetGroup(), "other_group")
	attest.equal(pvars.GetCurrentGroup(), nil)
	attest.equal(c:GetGroup(), "other")
	local found

	for _, group in ipairs(pvars.GetGroups()) do
		if group.name == "__test_group" then found = group end
	end

	attest.equal(#found.infos, 1)
	attest.equal(found.infos[1].key, "__test_group_alpha_beta")
end)

test.Test("pvars set errors are raised at the caller and keep the old value", function()
	local var = setup{key = "__test_pvar_keep", default = 1, min = 0, max = 3}
	var:Set(2)
	local ok, err = pcall(var.Set, var, {})
	attest.equal(ok, false)
	attest.equal(type(err), "string")
	attest.equal(var:Get(), 2)
end)

test.Test("pvars session values are not written to disk", function()
	local var = pvars.Setup2{key = "__test_pvar_session", default = 1}
	var:Set(2)
	var:SetSession(9)
	attest.equal(var:Get(), 9)
	attest.equal(pvars.session["__test_pvar_session"], 2)
	var:Set(4)
	attest.equal(pvars.session["__test_pvar_session"], nil)
	pvars.infos["__test_pvar_session"] = nil
	pvars.vars["__test_pvar_session"] = nil
end)
