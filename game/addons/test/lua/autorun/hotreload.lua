local timer = require("timer")
local fs = require("fs")
local last_modified_times = {}
local map = {}

timer.Repeat(
	"hotreload",
	0.25,
	math.huge,
	function()
		for name in pairs(package.loaded) do
			local path = map[name] or package.searchpath(name, package.path)

			if path and path ~= "INVALID" then
				map[name] = path
				local modified_time = fs.get_attributes(path).last_modified

				if modified_time then
					local last_time = last_modified_times[path]

					if not last_time then
						last_modified_times[path] = modified_time
					elseif modified_time > last_time then
						_G.HOTRELOAD = true
						local success, result = pcall(dofile, path)
						_G.HOTRELOAD = nil

						if success then
							print("reloaded " .. path)
							last_modified_times[path] = modified_time
						else
							print("reloading " .. path .. " failed:\n" .. result)
						end
					end
				end
			else
				map[name] = "INVALID"
			end
		end
	end
)
