local path = ...--[[# as string | nil]]
assert(type(path) == "string", "expected path string")
require("goluwa.global_environment")
_G.test = function(filter)
	require("helpers.test").RunTestsWithFilter(filter, {
		logging = true,
	})
end

do
	local f = io.open(path, "r")

	if f then
		local str = f:read("*a")

		if str then
			if str:find("%-%-%[%[HOTRELOAD") then
				local code = str:match("%-%-%[%[HOTRELOAD(.-)%]%]")

				if code then
					local ok, err = xpcall(assert(load(code)), debug.traceback)

					if not ok then io.write(err, "\n") end
				end
			end
		end

		f:close()
	end
end

local ok, err = xpcall(assert(loadfile("glw")), debug.traceback, "--reload", path)

if not ok then io.write(err, "\n") end
