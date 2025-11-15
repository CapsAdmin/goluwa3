local timer = require("timer")
local fs = require("fs")
local last_modified_times = {}

timer.Repeat(
	"hotreload",
	0.25,
	math.huge,
	function()
		for name in pairs(package.loaded) do
			local path = package.searchpath(name, package.path)

			if path then
				local modified_time = fs.get_attributes(path).last_modified

				if modified_time then
					local last_time = last_modified_times[path]

					if not last_time then
						last_modified_times[path] = modified_time
					elseif modified_time > last_time then
						local success, result = pcall(dofile, path)

						if success then
							print("reloaded " .. path)
							local tbl = package.loaded[name]

							if type(tbl) == "table" then
								table.clear(tbl)

								for k, v in pairs(result) do
									tbl[k] = v
								end
							end

							last_modified_times[path] = modified_time
						else
							print("reloading " .. path .. " failed:\n" .. result)
						end
					end
				end
			end
		end
	end
)
