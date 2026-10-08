local vfs = import("goluwa/vfs.lua")
local file_path = import("goluwa/filesystem/path.lua")
local resource = import("goluwa/resource.lua")
local callback = import("goluwa/callback.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function convert_typed_values(tbl)
	for key, val in pairs(tbl) do
		if type(val) == "table" then
			convert_typed_values(val)
		elseif type(val) == "string" then
			local first, last = val:sub(1, 1), val:sub(-1, -1)

			if first == "{" and last == "}" then
				local values = {}

				for v in val:sub(2, -2):trim():gmatch("%S+") do
					table.insert(values, v)
				end

				if #values == 3 or #values == 4 then
					tbl[key] = Color.FromBytes(
						tonumber(values[1]) or 0,
						tonumber(values[2]) or 0,
						tonumber(values[3]) or 0,
						tonumber(values[4]) or 255
					)
				end
			elseif first == "[" and last == "]" then
				local values = {}

				for v in val:sub(2, -2):trim():gmatch("%S+") do
					table.insert(values, v)
				end

				if
					#values == 3 and
					tonumber(values[1]) and
					tonumber(values[2]) and
					tonumber(values[3])
				then
					tbl[key] = Vec3(tonumber(values[1]), tonumber(values[2]), tonumber(values[3]))
				end
			end
		end
	end
end

local vdf = import("goluwa/codecs/vdf.lua")
local surface_properties = import("goluwa/source_engine/surface_properties.lua")
local vmt = {}
vmt.ConvertTypedValues = convert_typed_values

do
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
		normalmap = true,
		refracttinttexture = true,
	}
	local special_textures = {
		_rt_fullframefb = "error",
		[1] = "error",
	}

	function vmt.Load(path, on_load, on_error)
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

			local source_text = vfs.Read(resolved_path)
			local vmt, err = vdf.Decode(source_text, "vmt")

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

			if k == "patch" then
				if not vfs.IsFile(v.include) then
					v.include = vfs.FindMixedCasePath(v.include) or v.include
				end

				local str, err = vfs.Read(v.include)

				if not str then
					on_error("cannot include " .. v.include .. ": " .. err)
					main_cb:Reject(err)
					return
				end

				source_text = source_text .. "\n\n" .. str
				local vmt2, err2 = vdf.Decode(str, "vmt")

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

				vmt2.shader = k2
				table.merge(v2, v.replace or v.insert)
				vmt = vmt2
				v = v2
				k = k2
			else
				vmt.shader = k
			end

			vmt = v
			convert_typed_values(vmt)
			vmt.fullpath = path
			vmt.resolved_path = resolved_path
			vmt.source_text = source_text
			vmt.shader = k

			for k, v in pairs(vmt) do
				if type(v) == "string" and (special_textures[v] or special_textures[v:lower()]) then
					vmt[k] = special_textures[v]
				end
			end

			if not vmt.bumpmap and vmt.basetexture and not special_textures[vmt.basetexture] then
				local new_path = file_path.FixPathSlashes(vmt.basetexture)

				if vfs.IsFile("materials/" .. new_path .. "_normal.vtf") then
					vmt.bumpmap = new_path .. "_normal"
				end
			end

			local pending = 1

			local function check_done()
				if pending == 0 then
					on_load(vmt)
					main_cb:Resolve()
				end
			end

			for k, v in pairs(vmt) do
				if type(v) == "string" and texture_paths[k] then
					if special_textures[v] or special_textures[v:lower()] then

					elseif v == "black" or v == "white" then

					else
						local new_path = file_path.FixPathSlashes("materials/" .. v)

						if not new_path:ends_with(".vtf") then new_path = new_path .. ".vtf" end

						pending = pending + 1
						local cb = resource.Download(new_path, nil, true):Then(function(texture_path)
							vmt[k] = texture_path
							pending = pending - 1
							check_done()
						end)

						cb:Catch(function(reason)
							local mixed_path = vfs.FindMixedCasePath(new_path)

							if mixed_path then
								vmt[k] = mixed_path
							else
								if on_error then
									on_error("texture " .. k .. " " .. new_path .. " not found: " .. reason)
								end

								vmt[k] = nil
							end

							pending = pending - 1
							check_done()
						end)
					end
				elseif k == "surfaceprop" then
					vmt[k] = surface_properties.GetAll()[v:lower()] or v
				else
					if v == "" then vmt[k] = nil end
				end
			end

			pending = pending - 1
			check_done()
		end):Catch(function(reason)
			on_error("material " .. path .. " not found: " .. reason)
			main_cb:Reject(reason)
		end)
		return main_cb
	end
end

return vmt
