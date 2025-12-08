require("goluwa.global_environment")
local test = require("test.gambarina")
local fs = require("bindings.filesystem")
local files = fs.get_files("test/")
table.sort(files)

for _, file in ipairs(files) do
	if file:match("%.lua$") and file ~= "run.lua" and file ~= "gambarina.lua" then
		local module_name = "test." .. file:gsub("%.lua$", "")
		print("\n=== Running " .. module_name .. " ===\n")
		require(module_name)
	end
end

test:report()
