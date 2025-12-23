local vfs = require("vfs")
local resource = require("resource")
local callback = require("callback")
return function(steam)
	local textures = {
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

	function steam.LoadVMT(path, on_property, on_error, on_shader)
		on_error = on_error or logn
		local main_cb = callback.Create()
		main_cb.warn_unhandled = false
		local res = resource.Download(path, nil, true):Then(function(resolved_path)
			if resolved_path:ends_with(".vtf") then
				on_property("basetexture", resolved_path, resolved_path, {})
				-- default normal map?
				main_cb:Resolve()
				return
			end

			local vmt, err = steam.VDFToTable(vfs.Read(resolved_path), function(key)
				return (key:lower():gsub("%$", ""))
			end)

			if err then
				on_error(path .. " steam.VDFToTable : " .. err)
				main_cb:Reject(err)
				return
			end

			local k, v = next(vmt)

			if type(k) ~= "string" or type(v) ~= "table" then
				on_error("bad material " .. path)
				table.print(vmt)
				main_cb:Reject("bad material")
				return
			end

			if on_shader then on_shader(k) end

			if k == "patch" then
				if not vfs.IsFile(v.include) then
					v.include = vfs.FindMixedCasePath(v.include) or v.include
				end

				local vmt2, err2 = steam.VDFToTable(vfs.Read(v.include), function(key)
					return (key:lower():gsub("%$", ""))
				end)

				if err2 then
					on_error(err2)
					main_cb:Reject(err2)
					return
				end

				local k2, v2 = next(vmt2)

				if type(k2) ~= "string" or type(v2) ~= "table" then
					on_error("bad material " .. path)
					table.print(vmt)
					main_cb:Reject("bad material")
					return
				end

				table.merge(v2, v.replace or v.insert)
				vmt = vmt2
				v = v2
				k = k2
			end

			vmt = v
			local fullpath = path

			for k, v in pairs(vmt) do
				if type(v) == "string" and (special_textures[v] or special_textures[v:lower()]) then
					vmt[k] = special_textures[v]
				end
			end

			if not vmt.bumpmap and vmt.basetexture and not special_textures[vmt.basetexture] then
				local new_path = vfs.FixPathSlashes(vmt.basetexture)

				if not new_path:ends_with(".vtf") then new_path = new_path .. ".vtf" end

				new_path = new_path:gsub("%.vtf", "_normal.vtf")

				if vfs.IsFile("materials/" .. new_path) then
					vmt.bumpmap = new_path
				else
					new_path = new_path:lower()

					if vfs.IsFile("materials/" .. new_path) then vmt.bumpmap = new_path end
				end
			end

			local pending = 0

			local function check_done()
				if pending == 0 then main_cb:Resolve() end
			end

			for k, v in pairs(vmt) do
				if
					type(v) == "string" and
					textures[k] and
					(
						not special_textures[v] and
						not special_textures[v:lower()]
					)
				then
					if v == "black" or v == "white" then
						on_property(k, v, v, vmt)
					else
						local new_path = vfs.FixPathSlashes("materials/" .. v)

						if not new_path:ends_with(".vtf") then new_path = new_path .. ".vtf" end

						pending = pending + 1
						local cb = resource.Download(new_path, nil, true):Then(function(texture_path)
							on_property(k, texture_path, fullpath, vmt)
							pending = pending - 1
							check_done()
						end)

						if on_error then
							cb:Catch(function(reason)
								on_error("texture " .. k .. " " .. new_path .. " not found: " .. reason)
								pending = pending - 1
								check_done()
							end)
						end
					end
				else
					on_property(k, v, fullpath, vmt)
				end
			end

			check_done()
		end):Catch(function(reason)
			on_error("material " .. path .. " not found: " .. reason)
			main_cb:Reject(reason)
		end)
		return main_cb
	end
end
