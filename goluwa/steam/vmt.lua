local vfs = require("vfs")
local resource = require("resource")
local callback = require("callback")
return function(steam)
	local texture_paths = {
		basetexture = true,
		basetexture2 = true,
		texture = true,
		texture2 = true,
		bumpmap = true,
		bumpmap2 = true,
		envmapmask = true,
		phongexponenttexture = true,
		blendmodulatetexture = true,
		selfillummask = true,
	}
	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error", -- huh
	}

	function steam.LoadVMT(path, on_load, on_error)
		on_error = on_error or logn
		local main_cb = callback.Create()
		main_cb.warn_unhandled = false
		local res = resource.Download(path, nil, true):Then(function(resolved_path)
			if resolved_path:ends_with(".vtf") then
				local vmt_data = {shader = "vertexlitgeneric", basetexture = resolved_path}
				on_load(vmt_data)
				main_cb:Resolve()
				return
			end

			local vmt, err = steam.VDFToTable(vfs.Read(resolved_path), function(key)
				return (key:lower():gsub("%$", ""))
			end)

			if err then
				on_error(path .. " steam.VDFToTable : " .. err)
				---main_cb:Reject(err)
				return
			end

			local k, v = next(vmt)

			if type(k) ~= "string" or type(v) ~= "table" then
				on_error("bad material " .. path)
				table.print(vmt)
				--main_cb:Reject("bad material")
				return
			end

			if k == "patch" then
				if not vfs.IsFile(v.include) then
					v.include = vfs.FindMixedCasePath(v.include) or v.include
				end
				
				local str, err = vfs.Read(v.include)

				if not str then
					on_error("cannot include " .. v.include .. ": " .. err)
					--main_cb:Reject(err)
					return 
				end

				local vmt2, err2 = steam.VDFToTable(str, function(key)
					return (key:lower():gsub("%$", ""))
				end)

				if err2 then
					on_error(err2)
					--main_cb:Reject(err2)
					return
				end

				local k2, v2 = next(vmt2)

				if type(k2) ~= "string" or type(v2) ~= "table" then
					on_error("bad material " .. path)
					table.print(vmt)
					--main_cb:Reject("bad material")
					return
				end

				vmt2.shader = k2
				table.merge(v2, v.replace or v.insert)
				vmt = vmt2
				v = v2
				k = k2
			else
				vmt.shader = k
			end

			vmt = v
			vmt.fullpath = path

			for k, v in pairs(vmt) do
				if type(v) == "string" and (special_textures[v] or special_textures[v:lower()]) then
					vmt[k] = special_textures[v]
				end
			end

			-- Auto-discover normal maps - these will be resolved later by the resource.Download loop
			if not vmt.bumpmap and vmt.basetexture and not special_textures[vmt.basetexture] then
				local new_path = vfs.FixPathSlashes(vmt.basetexture)

				if vfs.IsFile("materials/" .. new_path .. "_normal.vtf") then
					vmt.bumpmap = new_path .. "_normal" -- Set without materials/ prefix or .vtf, will be resolved later
				end
			end

			local pending = 1 -- Start at 1 to prevent early resolution
			local function check_done()
				if pending == 0 then
					on_load(vmt)
					main_cb:Resolve()
				end
			end

			for k, v in pairs(vmt) do
				if type(v) == "string" and texture_paths[k] then
					if special_textures[v] or special_textures[v:lower()] then

					-- Keep special textures as-is
					elseif v == "black" or v == "white" then

					-- Keep the value as-is for black/white
					else
						local new_path = vfs.FixPathSlashes("materials/" .. v)

						if not new_path:ends_with(".vtf") then new_path = new_path .. ".vtf" end

						pending = pending + 1
						local cb = resource.Download(new_path, nil, true):Then(function(texture_path)
							vmt[k] = texture_path
							pending = pending - 1
							check_done()
						end)

						cb:Catch(function(reason)
							if on_error then
								on_error("texture " .. k .. " " .. new_path .. " not found: " .. reason)
							end

							vmt[k] = nil -- Remove failed texture from vmt
							pending = pending - 1
							check_done()
						end)
					end
				elseif k == "surfaceprop" then
					vmt[k] = steam.GetSurfaceProps()[v:lower()] or v
				else
					if v == "" then vmt[k] = nil end
				end
			end

			-- Decrement the initial pending count now that loop is complete
			pending = pending - 1
			check_done()
		end):Catch(function(reason)
			on_error("material " .. path .. " not found: " .. reason)
			--main_cb:Reject(reason)
		end)
		return main_cb
	end
end
