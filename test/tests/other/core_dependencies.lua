local T = import("test/environment.lua")
local fs = import("goluwa/filesystem/fs.lua")
local vfs = import("goluwa/vfs.lua")

T.Test("core does not import from the loader addons", function()
	local offenders = {}

	for _, path in ipairs(fs.get_files_recursive("goluwa/")) do
		if path:ends_with(".lua") then
			local file = assert(io.open(path, "rb"))
			local source = file:read("*a")
			file:close()

			for module in source:gmatch("import%(\"([^\"]+)\"%)") do
				if module:find("^addons/") or module:find("^lua/%w+_loader/") then
					offenders[#offenders + 1] = path .. " imports " .. module
				end
			end
		end
	end

	T(table.concat(offenders, "\n"))["=="]("")
end)

T.Test("addon manifests and scanned modules point at files that exist", function()
	local missing = {}

	for key, module in pairs(vfs.GetAddonField("components")) do
		if not vfs.IsFile(module) then missing[#missing + 1] = "components " .. key .. ": " .. module end
	end

	for _, directory in ipairs({"loaders", "model_decoders", "material_loaders"}) do
		for key, module in pairs(vfs.GetAddonModules(directory)) do
			if not vfs.IsFile(module) then missing[#missing + 1] = directory .. " " .. key .. ": " .. module end
		end
	end

	T(table.concat(missing, "\n"))["=="]("")
end)
