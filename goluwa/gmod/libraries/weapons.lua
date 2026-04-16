do
	local META = prototype.CreateTemplate("gmod_weapon")
	META:Register()

	function gine.CreateWeapon(class_name)
		local self = META:CreateObject()
		self.clip1 = 0
		self.max_clip1 = 1
		self.clip2 = 0
		self.max_clip2 = 1
		self.hold_type = self.hold_type or "pistol"
		self.AnimExtension = self.AnimExtension or {}
		self.ClassName = class_name or self.ClassName or "gmod_tool"
		self.IsValid = self.IsValid or function()
			return true
		end
		return self
	end
end

local function get_weapon_definition(class_name)
	if not class_name then return nil end

	if gine.env.weapons.GetStored then
		local stored = gine.env.weapons.GetStored(class_name)

		if stored then return stored end
	end

	if gine.env.weapons.Get then return gine.env.weapons.Get(class_name) end
end

local function ensure_weapon_wrapper(player, class_name)
	class_name = class_name or player.__obj.gine_active_weapon_class or "gmod_tool"
	player.__obj.gine_weapons = player.__obj.gine_weapons or {}
	player.__obj.gine_active_weapon_class = class_name
	local host_weapon = player.__obj.gine_weapons[class_name]

	if not host_weapon then
		host_weapon = gine.CreateWeapon(class_name)
		host_weapon.owner = player.__obj
		player.__obj.gine_weapons[class_name] = host_weapon
	end

	local wrapped_weapon = gine.WrapObject(host_weapon, "Weapon")

	if not host_weapon.gine_definition_applied then
		local definition = get_weapon_definition(class_name)

		if definition then
			for key, value in pairs(definition) do
				rawset(wrapped_weapon, key, value)
			end

			host_weapon.gine_definition_applied = true
		end
	end

	if
		rawget(wrapped_weapon, "InitializeTools") and
		not host_weapon.gine_tools_initialized
	then
		wrapped_weapon:InitializeTools()
		host_weapon.gine_tools_initialized = true
	end

	return wrapped_weapon
end

do
	local META = gine.GetMetaTable("Weapon")

	function META:SetClip2(num)
		self.__obj.clip2 = num
	end

	function META:Clip2()
		return self.__obj.clip2
	end

	function META:GetMaxClip2()
		return self.__obj.max_clip2
	end

	function META:SetClip1(num)
		self.__obj.clip1 = num
	end

	function META:Clip1()
		return self.__obj.clip1
	end

	function META:GetMaxClip1()
		return self.__obj.max_clip1
	end

	function META:GetPrimaryAmmoType()
		return 0
	end

	function META:GetSecondaryAmmoType()
		return 0
	end

	function META:GetPrintName()
		return self.PrintName or "???"
	end

	function META:SetOwner(owner)
		self.__obj.owner = owner and owner.__obj or owner
	end

	function META:GetOwner()
		local owner = self.__obj.owner or gine.env.LocalPlayer().__obj
		return gine.WrapObject(owner, "Player")
	end

	function META:SetHoldType(hold_type)
		hold_type = hold_type or "pistol"
		self.__obj.hold_type = hold_type
		self.__obj.AnimExtension = self.__obj.AnimExtension or {}

		if self.SetWeaponHoldType then return self:SetWeaponHoldType(hold_type) end

		return hold_type
	end

	function META:GetHoldType()
		return self.__obj.hold_type or "pistol"
	end
end

do
	local META = gine.GetMetaTable("Player")

	function META:SelectWeapon(class_name)
		if class_name then
			self.__obj.gine_active_weapon_class = class_name
			return ensure_weapon_wrapper(self, class_name)
		end
	end

	function META:GetActiveWeapon()
		return ensure_weapon_wrapper(self, self.__obj.gine_active_weapon_class)
	end

	function META:GetWeapons()
		self:GetActiveWeapon()
		local out = {}

		for _, weapon in pairs(self.__obj.gine_weapons or {}) do
			list.insert(out, gine.WrapObject(weapon, "Weapon"))
		end

		return out
	end

	function META:GetWeapon(class_name)
		if not class_name then return self:GetActiveWeapon() end

		return ensure_weapon_wrapper(self, class_name)
	end

	function META:HasWeapon(class_name)
		return self:GetWeapon(class_name) ~= nil
	end

	function META:SetAmmo(count, type) end

	function META:GetAmmoCount(type)
		return 0
	end

	function META:GiveAmmo(type, b) end

	function META:RemoveAllAmmo() end

	function META:SetWeaponColor() end

	function META:ShouldDropWeapon() end
end

function gine.env.game.GetAmmoName(id)
	return "none"
end

function gine.env.game.GetAmmoID(name)
	return 1
end

function gine.env.game.GetAmmoMax(type)
	return 1
end
