local resource = import("goluwa/resource.lua")
local steam = import("goluwa/steam.lua")
local vfs = import("goluwa/vfs.lua")
local render = import("goluwa/render/render.lua")
local render2d = import("goluwa/render2d/render2d.lua")

do
	gine.created_materials = table.weak()
	local texture_extensions = {".vtf", ".png", ".jpg", ".jpeg", ".dds", ".gif"}

	local function material_source_exists(path)
		if type(path) ~= "string" or path == "" then return false end

		return vfs.IsFile("materials/" .. path .. ".vmt") or
			vfs.IsFile("materials/" .. path) or
			vfs.IsFile("materials/" .. path .. ".png") or
			vfs.IsFile("materials/" .. path .. ".jpg") or
			vfs.IsFile("materials/" .. path .. ".jpeg") or
			vfs.IsFile("materials/" .. path .. ".dds") or
			vfs.IsFile("materials/" .. path .. ".gif") or
			vfs.IsFile("materials/" .. path .. ".vtf")
	end

	local function has_known_texture_extension(path)
		if type(path) ~= "string" then return false end

		local lower = path:lower()

		for _, ext in ipairs(texture_extensions) do
			if lower:ends_with(ext) then return true end
		end

		return false
	end

	local function append_texture_candidates(candidates, path)
		if has_known_texture_extension(path) then
			list.insert(candidates, path)

			if path:ends_with(".vtf") then list.insert(candidates, path:sub(1, -5)) end
			return
		end

		if path:ends_with(".vtf") then
			list.insert(candidates, path:sub(1, -5))
			list.insert(candidates, path)
			return
		end

		list.insert(candidates, path)

		if not path:find(".+%.[^/]+$") then
			for _, ext in ipairs(texture_extensions) do
				list.insert(candidates, path .. ext)
			end
		end
	end

	function gine.env.CreateMaterial(name, shader, tbl)
		shader = shader:lower()

		if gine.created_materials[name] then return gine.created_materials[name] end

		local mat = gine.CreateMaterial(shader)
		mat.name = name

		for k, v in pairs(tbl) do
			k = k:lower():sub(2)
			local t = type(v)

			if t == "string" then
				mat:SetString(k, v)
			elseif t == "number" then
				mat:SetNumber(k, v)
			else
				mat:Set(k, v)
			end
		end

		local self = gine.WrapObject(mat, "IMaterial")
		gine.created_materials[name] = self
		return self
	end

	function gine.env.Material(path, flags)
		local cache_key = path:lower()
		local cached = gine.created_materials[cache_key]

		if cached then
			local texture = cached:GetTexture("$basetexture")

			if not (texture and texture:IsError() and material_source_exists(path)) then return cached end
			gine.created_materials[cache_key] = nil
		end

		local mat = gine.CreateMaterial()
		mat.name = path
		local self = gine.WrapObject(mat, "IMaterial")

		if has_known_texture_extension(path) then
			mat:SetShader("unlitgeneric")
			self:SetString("$basetexture", path)
		else
			local vmt_path

			if vfs.IsFile("materials/" .. path .. ".vmt") then
				vmt_path = "materials/" .. path .. ".vmt"
			elseif vfs.IsFile("materials/" .. path) then
				vmt_path = "materials/" .. path
			end

			if vmt_path then
				steam.LoadVMT(
					vmt_path,
					function(vmt)
						if type(vmt.shader) == "string" then
							mat:SetShader(vmt.shader:lower())
						end

						for key, val in pairs(vmt) do
							if key ~= "shader" then
								if type(val) == "boolean" then
									val = val and "1" or "0"
								elseif type(val) == "number" then
									val = tostring(val)
								elseif typex(val) == "vec3" then
									val = ("[%f %f %f]"):format(val:Unpack())
								elseif typex(val) == "color" then
									val = ("[%f %f %f %f]"):format(val:Unpack())
								end

								if type(key) == "string" and type(val) == "string" then
									self:SetString("$" .. key, val)
								end
							end
						end
					end
				)
			else
				mat:SetShader("unlitgeneric")
				self:SetString("$basetexture", path)
			end
		end

		gine.created_materials[cache_key] = self
		return self
	end

	local META = gine.GetMetaTable("IMaterial")

	local function is_texture_key(key)
		return key == "basetexture" or
			key == "basetexture2" or
			key == "detail" or
			key == "bumpmap" or
			key == "normalmap" or
			key == "envmapmask" or
			key == "selfillummask" or
			key == "phongexponenttexture"
	end

	local function resolve_material_texture_path(path)
		if type(path) ~= "string" or path == "" or path == "error" then
			return render.GetErrorTexture()
		end

		path = path:gsub("\\", "/")
		path = path:match("(materials/.+)") or path
		local candidates = {}
		append_texture_candidates(candidates, path)

		for i, candidate in ipairs(candidates) do
			if not candidate:starts_with("/") and candidate:sub(2, 2) ~= ":" and not candidate:starts_with("materials/") then
				candidates[i] = "materials/" .. candidate
			end
		end

		local tex

		for _, candidate in ipairs(candidates) do
			tex = render.CreateTextureFromPath(candidate)
			if tex and tex.GetPath and tex:GetPath() ~= "textures/error.png" then break end
		end

		return tex or render.GetErrorTexture()
	end

	function META:GetColor(x, y)
		local tex = self:GetTexture("$basetexture")

		if tex then return tex:GetColor(x, y) end

		return gine.env.Color(0, 0, 0, 0)
	end

	function META:GetName()
		return self.__obj.name
	end

	function META:GetShader()
		return self.__obj.shader or "vertexlitgeneric"
	end

	function META:Width()
		local tex = self:GetTexture("$basetexture")

		if tex then return tex:Width() end

		return 0
	end

	function META:Height()
		local tex = self:GetTexture("$basetexture")

		if tex then return tex:Height() end

		return 0
	end

	function META:GetKeyValues()
		return table.copy(self.__obj.vars)
	end

	function META:Recompute() end

	function META:SetString(key, val)
		key = key:lower():sub(2)

		if is_texture_key(key) then
			self.__obj.gine_texture_vars = self.__obj.gine_texture_vars or {}
			self.__obj.gine_texture_vars[key] = resolve_material_texture_path(val)
			self.__obj:SetString(key, val)
			return
		end

		self.__obj:SetString(key, val)
	end

	function META:GetString(key)
		key = key:lower():sub(2)
		return self.__obj:GetString(key)
	end

	function META:SetFloat(key, val)
		key = key:lower():sub(2)
		self.__obj:SetNumber(key, val)
	end

	function META:GetFloat(key)
		key = key:lower():sub(2)
		return self.__obj:GetNumber(key)
	end

	function META:SetInt(key, val)
		key = key:lower():sub(2)
		self.__obj:SetNumber(key, math.round(val))
	end

	function META:GetInt(key)
		key = key:lower():sub(2)
		return math.round(self.__obj:GetNumber(key) or 0)
	end

	function META:SetTexture(key, val)
		if key == nil or val == nil then return end -- ?? gmod doesn't error
		key = key:lower():sub(2)
		self.__obj.gine_texture_vars = self.__obj.gine_texture_vars or {}
		self.__obj.gine_texture_vars[key] = val.__obj
		self.__obj:Set(key, val.__obj)
	end

	function META:GetTexture(key)
		key = key:lower():sub(2)
		local cache = self.__obj.gine_texture_vars
		if cache and cache[key] then return gine.WrapObject(cache[key], "ITexture") end

		local val = self.__obj:Get(key)

		if typex(val) == "texture" then return gine.WrapObject(val, "ITexture") end

		if type(val) == "string" and is_texture_key(key) then
			val = resolve_material_texture_path(val)
			self.__obj.gine_texture_vars = self.__obj.gine_texture_vars or {}
			self.__obj.gine_texture_vars[key] = val
			self.__obj:Set(key, val)
			return gine.WrapObject(val, "ITexture")
		end

		return gine.WrapObject(render.GetErrorTexture(), "ITexture")
	end

	META.SetHDRTexture = META.SetTexture
	META.GetHDRTexture = META.GetTexture

	function META:SetVector(key, val)
		key = key:lower():sub(2)
		self.__obj:Set(key, Vec3(val.x, val.y, val.z))
	end

	function META:GetVector(key)
		key = key:lower():sub(2)
		local vec = self.__obj:Get(key:sub(2))

		if vec then return gine.env.Vector(vec:Unpack()) end
	end

	function META:IsError()
		local texture = self:GetTexture("$basetexture")
		return texture and texture:IsError() or false
	end
end

do
	local META = gine.GetMetaTable("ITexture")

	local function get_texture_size(obj)
		if obj.GetSize then
			local size = obj:GetSize()
			if size and size.x and size.y then return size end
		end

		if obj.Size and obj.Size.x and obj.Size.y then return obj.Size end
		return Vec2(0, 0)
	end

	function META:Width()
		return math.pow2round(get_texture_size(self.__obj).x)
	end

	function META:Height()
		return math.pow2round(get_texture_size(self.__obj).y)
	end

	function META:GetColor(x, y)
		local s = get_texture_size(self.__obj)
		if s.x <= 0 or s.y <= 0 then return gine.env.Color(255, 0, 255, 255) end
		x = (x / s.x) * math.pow2round(s.x)
		y = (y / s.y) * math.pow2round(s.y)
		if not self.__obj.GetPixelColor then return gine.env.Color(255, 0, 255, 255) end
		local pixel = self.__obj:GetPixelColor(x, y)
		if not pixel or not pixel.Unpack then return gine.env.Color(255, 0, 255, 255) end
		local r, g, b, a = pixel:Unpack()
		return gine.env.Color(r * 255, g * 255, b * 255, a * 255)
	end

	function META:GetName()
		if self.__obj.GetPath then return self.__obj:GetPath() end
		if self.__obj.path then return self.__obj.path end
		if self.__obj.name then return self.__obj.name end
		return ""
	end

	function META:IsError()
		return self:GetName() == "textures/error.png"
	end
end

if CLIENT then
	do
		local surface = gine.env.surface
		local idmap = {}
		local id = 0

		function surface.GetTextureID(path)
			local tex
			resource.skip_providers = true

			if vfs.IsFile("materials/" .. path) then
				if vfs.IsFile("materials/" .. path .. ".vtf") then
					tex = render.CreateTextureFromPath("materials/" .. path)
				else
					wlog("texture not found %s", path)
				end
			end

			if not tex then tex = render.CreateTextureFromPath("materials/" .. path .. ".vtf") end
			resource.skip_providers = nil
			idmap[id] = tex
			id = id + 1
			return id
		end

		function surface.SetMaterial(mat)
			gine.env.render.SetMaterial(mat)
		end

		function surface.SetTexture(id)
			render2d.SetTexture(idmap[id])
		end
	end

	function gine.env.render.SetMaterial(mat)
		if not mat then
			render2d.SetTexture(render.GetErrorTexture())
			return
		end

		mat = mat.__obj
		local texture = mat.gine_texture_vars and mat.gine_texture_vars.basetexture or mat.vars.basetexture

		if typex(texture) ~= "texture" then
			texture = render.GetErrorTexture()
		end

		render2d.SetTexture(texture)

		if render2d.SetAlphaTestReference then
			if mat.vars.alphatest == 1 then
				render2d.SetAlphaTestReference(mat.vars.alphatestreference)
			else
				render2d.SetAlphaTestReference(0)
			end
		end

		if mat.vars.additive then
			if render2d.SetBlendMode then
				render2d.SetBlendMode("additive", true)
			elseif render.SetPresetBlendMode then
				render.SetPresetBlendMode("additive")
			end
		else
			if render2d.SetBlendMode then
				render2d.SetBlendMode("alpha", true)
			elseif render.SetPresetBlendMode then
				render.SetPresetBlendMode("alpha")
			end
		end
	end

	function gine.env.render.MaterialOverride(mat)
		if mat == 0 then mat = nil end

		gine.env.render.SetMaterial(mat)
	end

	function gine.env.render.ModelMaterialOverride(mat)
		gine.env.render.SetMaterial(mat)
	end
end