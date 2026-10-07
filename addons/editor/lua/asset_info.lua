local vfs = import("goluwa/vfs.lua")
local fs = import("goluwa/filesystem/fs.lua")
local assets = import("goluwa/assets.lua")
local previews = import("lua/asset_preview.lua")
local asset_info = library()

function asset_info.FormatBytes(bytes)
	if not bytes then return "unknown" end

	if bytes < 1024 then return ("%d B"):format(bytes) end

	if bytes < 1024 * 1024 then return ("%.1f KB"):format(bytes / 1024) end

	if bytes < 1024 * 1024 * 1024 then
		return ("%.2f MB"):format(bytes / 1024 / 1024)
	end

	return ("%.2f GB"):format(bytes / 1024 / 1024 / 1024)
end

function asset_info.GetProviders(entry)
	local out = {}

	for _, data in ipairs(vfs.TranslatePath(entry.path)) do
		local context = data.context

		if context:IsFile(data.path_info) then
			local provider = {filesystem = context.Name, path = data.path_info.full_path}

			if context.GetFileTree then
				local tree, relative, archive_path = context:GetFileTree(data.path_info)
				provider.archive = archive_path
				local node = tree and tree:GetEntry(relative)
				provider.size = node and node.size
			else
				local attributes = fs.get_attributes(data.path_info.full_path)
				provider.size = attributes and tonumber(attributes.size)
			end

			out[#out + 1] = provider
		end
	end

	return out
end

function asset_info.ReadSource(entry)
	local file = vfs.Open(entry.path)

	if not file then return nil end

	local data = file:ReadAll()
	file:Close()
	return data
end

function asset_info.GetVMTSummary(source)
	local summary = {}
	summary.shader = source:match("^%s*\"?([%w_%.]+)\"?%s*{")
	summary.keys = {}

	for key, value in source:gmatch("\"?(%$[%w_]+)\"?%s+\"?([^\"\r\n]-)\"?%s*[\r\n]") do
		summary.keys[#summary.keys + 1] = {key = key, value = value}
	end

	return summary
end

-- returns {title = ..., rows = {{label, value}...}} sections, the same data feeds the details panel and the context menu
function asset_info.Get(entry)
	local sections = {}
	local general = {title = "asset", rows = {}}
	sections[1] = general
	local rows = general.rows
	rows[#rows + 1] = {"name", entry.name .. entry.extension}
	rows[#rows + 1] = {"path", entry.path}
	rows[#rows + 1] = {"category", entry.category}
	rows[#rows + 1] = {"kind", entry.kind .. (entry.source == "virtual" and " (virtual)" or "")}
	rows[#rows + 1] = {"root", entry.root}
	local provider_section = {title = "providers", rows = {}}

	if entry.source == "virtual" then
		provider_section.rows[1] = {"source", "registered in code, no file"}
	else
		local providers = asset_info.GetProviders(entry)

		for i, provider in ipairs(providers) do
			local location = provider.archive or provider.path
			local label = i == 1 and "mounted from" or "also in"
			provider_section.rows[#provider_section.rows + 1] = {
				label,
				provider.filesystem .. ": " .. (
					location:match("([^/]+)/*$") or
					location
				),
			}

			if i == 1 then
				provider_section.rows[#provider_section.rows + 1] = {"location", location}

				if provider.size then
					provider_section.rows[#provider_section.rows + 1] = {"file size", asset_info.FormatBytes(provider.size)}
				end
			end
		end

		if #providers == 0 then
			provider_section.rows[1] = {"source", "not found in any mount"}
		end
	end

	sections[#sections + 1] = provider_section
	local state = entry.preview
	local preview_section = {title = "preview", rows = {}}

	if state then
		preview_section.rows[1] = {"status", state.status}

		if state.error then
			preview_section.rows[#preview_section.rows + 1] = {"error", state.error}
		end

		if state.kind == "texture" and state.width then
			preview_section.rows[#preview_section.rows + 1] = {"dimensions", state.width .. " x " .. state.height}
			preview_section.rows[#preview_section.rows + 1] = {"format", tostring(state.format)}
			preview_section.rows[#preview_section.rows + 1] = {"mip levels", tostring(state.mip_levels)}
			preview_section.rows[#preview_section.rows + 1] = {"compressed", tostring(state.compressed == true)}

			if state.bytes and state.bytes > 0 then
				preview_section.rows[#preview_section.rows + 1] = {"vram (estimate)", asset_info.FormatBytes(state.bytes)}
			end
		end

		local info = state.info

		if info then
			preview_section.rows[#preview_section.rows + 1] = {"primitives", tostring(info.primitives)}
			preview_section.rows[#preview_section.rows + 1] = {"vertices", tostring(info.vertices)}
			preview_section.rows[#preview_section.rows + 1] = {"triangles", tostring(math.floor(info.triangles))}
			preview_section.rows[#preview_section.rows + 1] = {
				"size",
				(
					"%.2f x %.2f x %.2f"
				):format(info.size[1], info.size[2], info.size[3]),
			}

			for i, name in ipairs(info.materials) do
				preview_section.rows[#preview_section.rows + 1] = {i == 1 and "materials" or "", name}
			end
		end
	else
		preview_section.rows[1] = {"status", "not requested"}
	end

	sections[#sections + 1] = preview_section

	if entry.category == "materials" and entry.extension == ".vmt" then
		local source = asset_info.ReadSource(entry)

		if source then
			local summary = asset_info.GetVMTSummary(source)
			local vmt_section = {title = "vmt", rows = {}}

			if summary.shader then
				vmt_section.rows[1] = {"shader", summary.shader}
			end

			for _, item in ipairs(summary.keys) do
				vmt_section.rows[#vmt_section.rows + 1] = {item.key, item.value}
			end

			sections[#sections + 1] = vmt_section
		end
	end

	return sections
end

return asset_info
