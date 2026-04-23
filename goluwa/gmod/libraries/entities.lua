local vfs = import("goluwa/vfs.lua")
local Vec3 = import("goluwa/structs/vec3.lua")

local function create_host_visual_entity()
	local valid = true
	local position = Vec3()
	return {
		IsValid = function()
			return valid
		end,
		Remove = function(self)
			valid = false
		end,
		SetPosition = function(self, vec)
			position = vec and vec.Copy and vec:Copy() or vec or Vec3()
		end,
		GetPosition = function()
			return position and position.Copy and position:Copy() or position or Vec3()
		end,
	}
end

local function create_entity(class)
	local ent = create_host_visual_entity()
	local self = gine.WrapObject(ent, "Entity")
	self.ClassName = class
	local meta = gine.env.scripted_ents.Get(class)

	if meta then
		self.BaseClass = meta

		for k, v in pairs(self.BaseClass) do
			self[k] = v
		end
	else
		llog("creating non lua registered entity: %s", class)
	end

	gine.env.ents.created = gine.env.ents.created or {}
	list.insert(gine.env.ents.created, self)
	return self
end

gine.env.create_entity = create_entity

function gine.LoadEntities(base_folder, global, register, create_table)
	for file_name in vfs.Iterate(base_folder .. "/") do
		--logn("gine: registering ",base_folder," ", file_name)
		if file_name:ends_with(".lua") then
			local tbl = create_table()
			tbl.Folder = base_folder:sub(0, -5)
			gine.env[global] = tbl
			vfs.RunFile(base_folder .. "/" .. file_name)
			register(gine.env[global], file_name:match("(.+)%."))
		else
			if SERVER then
				if vfs.IsFile(base_folder .. "/" .. file_name .. "/init.lua") then
					local tbl = create_table()
					tbl.Folder = base_folder .. "/" .. file_name:sub(0, -5)
					gine.env[global] = tbl
					gine.env[global].Folder = base_folder:sub(5) .. "/" .. file_name -- weapons/gmod_tool/stools/
					vfs.RunFile(base_folder .. "/" .. file_name .. "/init.lua")
					register(gine.env[global], file_name)
				end
			end

			if CLIENT then
				if vfs.IsFile(base_folder .. "/" .. file_name .. "/cl_init.lua") then
					local tbl = create_table()
					tbl.Folder = base_folder .. "/" .. file_name:sub(0, -5)
					gine.env[global] = tbl
					gine.env[global].Folder = base_folder:sub(5) .. "/" .. file_name
					vfs.RunFile(base_folder .. "/" .. file_name .. "/cl_init.lua")
					register(gine.env[global], file_name)
				end
			end
		end
	end

	gine.env[global] = nil
end

do
	function gine.env.ents.FindByClass(name)
		local out = {}
		local i = 1

		if gine.objectsi.Entity then
			for _, data in ipairs(gine.objectsi.Entity) do
				if data.external.ClassName:find(name, nil, true) then
					out[i] = data.external
					i = i + 1
				end
			end
		end

		return out
	end

	function gine.env.ents.GetByIndex(idx)
		if gine.objectsi.Entity then
			for _, data in ipairs(gine.objectsi.Entity) do
				if data.external:EntIndex() == idx then return data.external end
			end
		end

		return NULL
	end

	gine.env.Entity = gine.env.ents.GetByIndex

	function gine.env.game.GetWorld()
		gine.world_entity = gine.world_entity or
			gine.WrapObject(
				{
					ClassName = "worldspawn",
					gine_is_world = true,
					IsValid = function()
						return true
					end,
				},
				"Entity"
			)
		return gine.world_entity
	end

	function gine.env.ents.FindInSphere(pos)
		return {}
	end
end

do
	if SERVER then
		function gine.env.ents.Create(class)
			create_entity(class)
		end
	end

	do
		local META = gine.EnsureMetaTable("Player")

		function META:Give(class_name)
			llog("give %s", class_name)
		end
	end

	function gine.env.ents.CreateClientProp(mdl)
		--llog("ents.CreateClientProp: %s", mdl)
		local ent = create_entity("class C_PhysPropClientside")

		if mdl then ent:SetModel(mdl) end

		return ent
	end

	function gine.env.ents.GetAll()
		local out = {}
		local i = 1

		for obj, ent in pairs(gine.objects.Entity) do
			list.insert(out, ent)
		end

		return out
	end

	function gine.env.ents.GetCount()
		return #gine.env.ents.GetAll()
	end

	local META = gine.EnsureMetaTable("Entity")

	function META:__newindex(k, v)
		if not rawget(self, "__storable_table") then
			rawset(self, "__storable_table", {})
		end

		self.__storable_table[k] = v
	end

	function META:GetTable()
		if not rawget(self, "__storable_table") then
			rawset(self, "__storable_table", {})
		end

		return self.__storable_table
	end

	function META:SetPos(vec)
		if self.__obj.SetPosition then self.__obj:SetPosition(vec.v) end

		self.__obj.gine_pos = vec
	end

	function META:SetLocalPos(vec)
		if self.__obj.SetPosition then self.__obj:SetPosition(vec.v) end

		self.__obj.gine_pos = vec
	end

	function META:GetPos()
		if self == gine.env.LocalPlayer() then return gine.env.EyePos() end

		if self.__obj.GetPosition then
			return gine.env.Vector(self.__obj:GetPosition())
		end

		return (self.__obj.gine_pos and (self.__obj.gine_pos * 1)) or gine.env.Vector(0, 0, 0)
	end

	function META:GetMaterials()
		return {}
	end

	function META:SetAngles(ang)
		self.__obj.gine_ang = ang
	end

	function META:GetAngles()
		if self == gine.env.LocalPlayer() then return gine.env.EyeAngles() end

		if self.__obj.GetRotation then
			return gine.env.Angle(self.__obj:GetRotation():GetAngles())
		end

		return (self.__obj.gine_ang and (self.__obj.gine_ang * 1)) or gine.env.Angle(0, 0, 0)
	end

	function META:GetForward()
		if self.__obj.GetRotation then
			return gine.env.Vector(self.__obj:GetRotation():GetForward())
		end

		return gine.env.Vector(0, 0, 0)
	end

	function META:GetUp()
		if self.__obj.GetRotation then
			return gine.env.Vector(self.__obj:GetRotation():GetUp())
		end

		return gine.env.Vector(0, 0, 0)
	end

	function META:GetRight()
		if self.__obj.GetRotation then
			return gine.env.Vector(self.__obj:GetRotation():GetRight())
		end

		return gine.env.Vector(0, 0, 0)
	end

	function META:EyePos()
		if self == gine.env.LocalPlayer() then return gine.env.EyePos() end

		return self:GetPos()
	end

	function META:EyeAngles()
		if self == gine.env.LocalPlayer() then return gine.env.EyeAngles() end

		return self:GetAngles()
	end

	function META:InvalidateBoneCache() end

	function META:GetBoneCount()
		return 0
	end

	function META:WaterLevel()
		return 0
	end

	function META:LookupBone(name)
		return 0
	end

	function META:GetBoneName()
		return "none"
	end

	function META:SetupBones() end

	function META:GetBonePosition()
		return self:GetPos(), self:GetAngles()
	end

	function META:GetBoneParent()
		return -1
	end

	function META:GetParentAttachment()
		return 0
	end

	function META:GetAttachments()
		return {
			{
				id = 1,
				name = "none",
			},
		}
	end

	function META:EntIndex()
		return tonumber(("%p"):format(self)) % 2048
	end

	function META:GetBoneMatrix() end

	function META:GetName()
		if self.MetaName == "Player" then return self:Nick() end

		return ""
	end

	function META:GetNetworkedString(what)
		if what == "UserGroup" then return "Player" end
	end

	function META:IsNextBot()
		return false
	end

	function META:GetNumBodyGroups()
		return 1
	end

	function META:GetBodygroupCount()
		return 1
	end

	function META:SkinCount()
		return 1
	end

	function META:LookupSequence()
		return -1
	end

	function META:DrawModel() end

	function META:FrameAdvance() end

	function META:GetClass()
		return self.ClassName or self.MetaName
	end

	function META:IsWorld()
		return self:GetClass() == "worldspawn" or self.__obj.gine_is_world == true
	end

	function META:OnGround()
		return false
	end

	function META:SetColor4Part(r, g, b, a)
		self.__obj.gine_color = {r, g, b, a}
	end

	function META:GetColor4Part()
		if not self.__obj.gine_color then return 255, 255, 255, 255 end

		return self.__obj.gine_color[1],
		self.__obj.gine_color[2],
		self.__obj.gine_color[3],
		self.__obj.gine_color[4]
	end

	gine.GetSet(META, "Material", "")

	gine.GetSet(META, "Velocity", function()
		return gine.env.Vector(0, 0, 0)
	end)

	gine.GetSet(META, "Model")
	gine.GetSet(META, "ModelScale")
	gine.GetSet(META, "IK", true)
	gine.GetSet(META, "LOD", 0)
	gine.GetSet(META, "Skin", 0)
	gine.GetSet(META, "Owner", NULL)

	gine.GetSet(META, "MoveType", function()
		return gine.env.MOVETYPE_NONE
	end)

	gine.GetSet(META, "MoveType", function()
		return gine.env.MOVETYPE_NONE
	end)

	gine.GetSet(META, "NoDraw", false)
	gine.GetSet(META, "MaxHealth", 100)
	gine.GetSet(META, "Health", 100)
	META.Health = META.GetHealth

	function META:IsFlagSet()
		return false
	end

	function META:EnableMatrix() end

	function META:GetSequenceActivity()
		return 0
	end

	function META:IsDormant()
		return true
	end

	function META:IsInWorld()
		return true
	end

	function META:GetSpawnEffect()
		return false
	end

	function META:BoundingRadius()
		return 1
	end

	function META:GetModelScale()
		return 1
	end

	function gine.env.ClientsideModel(path)
		--llog("ClientsideModel: %s", path)
		local ent = create_entity("prop_physics")
		ent:SetModel(path)
		return ent
	end

	function META:LocalToWorld()
		return gine.env.Vector()
	end

	function META:OBBCenter()
		return gine.env.Vector()
	end

	function META:OBBMins()
		return gine.env.Vector()
	end

	function META:OBBMaxs()
		return gine.env.Vector()
	end

	function META:WorldSpaceCenter()
		return gine.env.Vector()
	end

	function META:NearestPoint()
		return gine.env.Vector()
	end

	function META:SetKeyValue(key, val)
		self.__obj.keyvalues = self.__obj.keyvalues or {}
		self.__obj.keyvalues[key] = val
	end

	function META:GetKeyValues()
		self.__obj.keyvalues = self.__obj.keyvalues or {}
		return table.copy(self.__obj.keyvalues)
	end

	function META:DeleteOnRemove() end

	function META:Spawn()
		self:InstallDataTable()

		if self.SetupDataTables then self:SetupDataTables() end

		if self.Initialize then self:Initialize() end
	end

	function META:Activate() end

	function META:SetParent() end

	function META:GetParent()
		return NULL
	end

	function META:AddEffects() end

	function META:SetShouldServerRagdoll() end

	function META:SetNotSolid(b) end

	function META:DrawShadow(b) end

	function META:SetTransmitWithParent() end

	function META:SetBodygroup() end
end
