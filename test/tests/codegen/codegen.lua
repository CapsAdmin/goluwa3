local T = import("test/environment.lua")
local codegen = import("goluwa/codegen.lua")

T.Test("codegen.render plain substitution", function()
	local out = codegen.render("local a = {{NAME}}\nreturn a", { NAME = "42" })
	T(out)["=="]("local a = 42\nreturn a")
end)

T.Test("codegen.render multiple occurrences", function()
	local out = codegen.render("{{X}} + {{X}}", { X = "1" })
	T(out)["=="]("1 + 1")
end)

T.Test("codegen.render join", function()
	local out = codegen.render("f({{ARG}})", { ARG = codegen.join({"x", "y", "z"}, ", ") })
	T(out)["=="]("f(x, y, z)")
end)

T.Test("codegen.render join transform", function()
	local out = codegen.render("{{ARG}}", {
		ARG = codegen.join({"a", "b"}, ", ", function(v)
			return v .. "!"
		end),
	})
	T(out)["=="]("a!, b!")
end)

T.Test("codegen.render each repeats line", function()
	local out = codegen.render("a.{{KEY}} = 0", { KEY = codegen.each({"x", "y"}, ", ") })
	T(out)["=="]("a.x = 0, \na.y = 0\n")
end)

T.Test("codegen.render each multiple tokens on line", function()
	local out = codegen.render("self.{{KEY}} == {{KEY}}", { KEY = codegen.each({"x", "y"}, " and ") })
	T(out)["=="]("self.x == x and \nself.y == y\n")
end)

T.Test("codegen.render each transform overrides line", function()
	local out = codegen.render("-a.{{KEY}}", {
		KEY = codegen.each({"x", "y"}, ", ", function(name, line)
			if name == "y" then return "a." .. name end
			return line
		end),
	})
	T(out)["=="]("-a.x, \na.y\n")
end)

T.Test("codegen.render each with other tokens on line", function()
	local out = codegen.render("{{CTOR}}(a.{{KEY}})", {
		KEY = codegen.each({"x", "y"}, ", "),
		CTOR = "Vec3",
	})
	T(out)["=="]("Vec3(a.x), \nVec3(a.y)\n")
end)

T.Test("codegen.render missing env value errors", function()
	local ok, err = pcall(codegen.render, "{{MISSING}}", {})
	T(not ok)["=="](true)
	T(tostring(err):find("MISSING", nil, true) ~= nil)["=="](true)
end)

T.Test("codegen.render unclosed token errors", function()
	local ok, err = pcall(codegen.render, "a {{UNCLOSED", {})
	T(not ok)["=="](true)
	T(tostring(err):find("unclosed", nil, true) ~= nil)["=="](true)
end)

T.Test("codegen.run returns chunk results", function()
	local result = codegen.run("local a = {{A}}\nreturn a + 1", "test", { A = "41" })
	T(result)["=="](42)
end)

T.Test("codegen.run forwards call args", function()
	local got = codegen.run("local x, y = ...\nreturn x + y", "test", nil, 20, 22)
	T(got)["=="](42)
end)

T.Test("codegen.run binds values at runtime not render time", function()
	local fn = codegen.run("local f = ...\nreturn function() return f() end", "test", nil, function()
		return "ok"
	end)
	T(fn())["=="]("ok")
end)

T.Test("codegen.compile caches identical sources", function()
	local a = codegen.compile("return 1", "test")
	local b = codegen.compile("return 1", "test")
	T(a == b)["=="](true)
end)

T.Test("codegen.compile name appears in load error", function()
	local ok, err = pcall(codegen.compile, "local x = (", "my_special_label")
	T(not ok)["=="](true)
	T(tostring(err):find("my_special_label", nil, true) ~= nil)["=="](true)
end)

T.Test("codegen.compile name includes caller location", function()
	codegen.compile("return 1", "loc_check")
	local ok, err = pcall(codegen.compile, "syntax error here", "loc_check")
	T(not ok)["=="](true)
	T(tostring(err):find("codegen", nil, true) ~= nil or tostring(err):find("%.lua", nil, true) ~= nil)["=="](true)
end)
