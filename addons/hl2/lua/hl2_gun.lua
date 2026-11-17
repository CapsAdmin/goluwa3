local bullets = import("lua/bullets.lua")
local hl2 = import("lua/hl2.lua")
local damage = import("lua/damage.lua")
local weapon_effects = import("lua/weapon_effects.lua")
local hl2_gun = {}

function hl2_gun.Gun(META, config)
	META:GetSet("Damage", config.Damage or 8)
	META:GetSet("Spread", config.Spread or 0.01)
	META:GetSet("Pellets", config.Pellets or 1)
	META:GetSet("Range", config.Range or 150)
	META:GetSet("Impulse", config.Impulse or 4)

	function META:GetCharacter()
		return self.Owner:GetParent()
	end

	function META:Shoot(cmd, pellets, spread, muzzle)
		local character = self:GetCharacter()
		bullets.Fire{
			Weapon = self.Owner,
			Attacker = character,
			Origin = hl2.GetEye(character),
			Direction = cmd.aim:GetForward(),
			Spread = spread or self.Spread,
			Count = pellets or self.Pellets,
			Range = self.Range,
			Damage = self.Damage,
			Impulse = self.Impulse,
			Muzzle = muzzle or config.Muzzle,
			HoleSize = config.HoleSize,
		}
	end

	function META:OnWeaponPredictPrimary(cmd)
		self:Shoot(cmd)
	end

	function META:OnWeaponPrimary(cmd)
		self:Shoot(cmd)
		self.Owner.weapon:TakePrimaryAmmo(1)
	end

	function META:OnWeaponReload()
		if config.ReloadSound then hl2.Sound(self.Owner, config.ReloadSound, 75, 1) end
	end

	function META:OnWeaponDryFire()
		if config.EmptySound then hl2.Sound(self.Owner, config.EmptySound, 70, 1) end
	end

	return META
end

function hl2_gun.Melee(META, config)
	META:GetSet("Damage", config.Damage)
	META:GetSet("Range", config.Range or 1.5)
	META:GetSet("Impulse", config.Impulse or 8)

	function META:OnWeaponPrimary(cmd)
		local character = self.Owner:GetParent()
		local forward = cmd.aim:GetForward()
		local pose = character.character_pose

		if pose then pose:PlayAction("hl2_swing", 0.35) end

		local hit = damage.Sweep(hl2.GetEye(character), forward * self.Range, character, 0.08)

		if not hit then
			hl2.RandomSound(self.Owner, config.SwingSounds, 70)
			return config.MissDelay
		end

		local force = forward * self.Impulse
		local victim = hl2.DealHit(
			hit,
			{
				Attacker = character,
				Inflictor = self.Owner,
				Damage = self.Damage * self.Owner.weapon:GetDamageScale(),
				Type = config.DamageType or "generic",
				Attributes = self.Owner.weapon.Attributes,
				Force = force,
			}
		)
		local body = hl2.GetDynamicBody(hit)

		if body then body:ApplyImpulse(force, hit.point) end

		weapon_effects.Hit(self.Owner, hit.point, hit.normal, force)
		local sounds = victim and config.FleshSounds or config.HitSounds
		hl2.SoundAt(hit.point, sounds[math.random(#sounds)], 80, math.randomf(0.95, 1.05), nil)

		if config.OnHit then config.OnHit(self, hit) end

		return config.HitDelay
	end

	return META
end

return hl2_gun
