return {
	Source = [=====[
local objects = import("goluwa/objects/objects.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local slash = import("lua/jrpg/slash.lua")
local movesets = import("lua/movesets.lua")
local damage_types = import("lua/jrpg/damage_types.lua")
local actors = import("lua/actors.lua")
local grab = import("lua/grab.lua")
local damage = import("lua/damage.lua")
local effects = import("lua/jrpg/effects.lua")
local sounds = import("lua/sounds.lua")
local flow_ribbons = import("goluwa/render3d/flow_ribbons.lua")
local effect_exposure = import("lua/jrpg/effect_exposure.lua")
local META = objects.CreateTemplate("weapon_melee")
META:StartStorable()
META:GetSet("Moveset", "sword")
META:GetSet("Damage", 22)
META:GetSet("Range", 1.7)
META:GetSet("SwingPitch", 1)
META:GetSet("TrailColor", Color(0.85, 0.92, 1, 1))
META:EndStorable()
local SLASH = {"slash"}
local BUTTON = usercmd.BUTTON
local DASH_SPEED = 3
local HOLD_HEAVY = 0.3
local MAX_COMMAND_GAP = 30
local PULL_GAP = 1.4
local PULL_TIME = 0.35
local NO_STAMINA = Color(1, 0.8, 0.3, 1)
local TRAIL_POINTS = 18
local TRAIL_FADE_RATE = 1
local TRAIL_STRENGTH = 0.1
local TRAIL_OVERLAY_CONFIG = {FadeIn = 0.05, FadeOut = 0.05, Scale = 1.5, UVScale = {0.8, 1}, UVStretch = 40}
local SPARK_LINGER = 0.15
local LINE_STRENGTH = 6
local LINE_RADIUS = 0.03
local LINE_POINTS = 48
local LINE_SUBDIVISIONS = 4
local LINE_END_TAPER = 0.8
local SPARK_DENSITY = 20
local WHITE = Color(1, 1, 1, 1)
local SWING_SOUNDS = {"npc/zombie/claw_miss1.wav", "npc/zombie/claw_miss2.wav"}

function META:Initialize()
	self.combo = 0
	self.idle = 0
	self.hold = 0
	self.last_number = 0
	self.fading_trails = {}
	self:AddGlobalEvent("Update")
end

function META:GetHolder()
	return self.Owner:GetParent()
end

function META:GetRunner()
	return self:GetHolder():EnsureComponent("move_runner")
end

function META:StartMove(move, authority)
	local holder = self:GetHolder()
	local pose = holder.character_pose

	if pose:IsStunned() or holder:CallLocalEvent("OnCanAttack") == false then
		return false
	end

	local rpg = holder.rpg

	if rpg then
		if not authority then
			if not rpg:IsCheat() and rpg:GetStamina() < move.Stamina then return false end
		elseif not rpg:DrainStamina(move.Stamina) then
			effects.Text(holder, "NO STAMINA", NO_STAMINA)
			return false
		end
	end

	local weapon = self.Owner.weapon
	weapon:SetDrawn(true)
	self.queued = nil
	self:GetRunner():Begin(move, move.Duration / weapon.RateMultiplier, self, authority)
	return true
end

function META:Request(kind, cmd, authority)
	if self:GetRunner():IsPlaying() then
		self.queued = kind
		return
	end

	local holder = self:GetHolder()
	local set = movesets.Get(self.Moveset)

	if not holder.rigid_body:GetGrounded() and set.Air then
		self.combo = 0
		self:StartMove(set.Air, authority)
		return
	end

	if kind == "heavy" then
		self.combo = 0
		self:StartMove(set.Heavy, authority)
		return
	end

	local velocity = holder.rigid_body:GetVelocity()

	if
		set.Dash and
		usercmd.HasButton(cmd, BUTTON.SPRINT) and
		velocity.x * velocity.x + velocity.z * velocity.z > DASH_SPEED * DASH_SPEED
	then
		self.combo = 0
		self:StartMove(set.Dash, authority)
		return
	end

	self.combo = self.idle < set.ComboWindow and self.combo % #set.Combo + 1 or 1
	self:StartMove(set.Combo[self.combo], authority)
end

function META:OnWeaponPrimary(cmd)
	self:Request("light", cmd, true)
	return false
end

function META:OnWeaponSecondary(cmd)
	self:Request("heavy", cmd, true)
	return false
end

function META:OnWeaponPredictPrimary(cmd)
	self:Request("light", cmd, false)
	return false
end

function META:OnWeaponPredictSecondary(cmd)
	self:Request("heavy", cmd, false)
	return false
end

function META:Hit(hit, forward)
	local weapon = self.Owner.weapon
	local holder = self:GetHolder()
	local types = weapon:GetDamageTypes(SLASH)
	local _, _, hits = slash.Strike(
		holder,
		self.Owner,
		forward,
		hit.Cut,
		self.Damage * hit.Damage * weapon:GetDamageScale(),
		hit.Damage,
		hit.Range or self.Range,
		types
	)

	local knock = hit.Knock

	for _, victim_hit in ipairs(hits) do
		local victim = victim_hit.victim

		if victim:IsValid() then
			for _, type_name in ipairs(types) do
				effects.HitOverlay(victim, type_name)
			end
		end

		local body = victim:IsValid() and victim.rigid_body

		if knock and body and not victim.health:IsDead() then
			local push = knock.z

			if push < 0 then
				local gap = actors.GetCenter(victim) - actors.GetCenter(holder)
				gap.y = 0
				push = -math.min(-push, math.max(gap:GetLength() - PULL_GAP, 0) / PULL_TIME)
			end

			body:SetVelocity(
				body:GetVelocity() + Vec3(-forward.z, 0, forward.x) * knock.x + Vec3(0, knock.y, 0) + forward * push
			)
		end
	end
end

function META:EndGrab(velocity)
	local victim = self.grabbed
	self.grabbed = nil

	if victim:IsValid() and grab.IsHeld(victim) then grab.Release(victim, velocity) end
end

function META:Latch(move, event)
	local holder = self:GetHolder()
	local runner = self:GetRunner()
	local target = runner.frame.target

	if
		not target or
		not actors.IsAlive(target) or
		(
			actors.GetCenter(target) - actors.GetCenter(holder)
		):GetLength() > event.Range
	then
		target = movesets.FindTarget(holder, actors.GetCenter(holder), actors.GetForward(holder), event.Range)
	end

	if target and not grab.IsHeld(target) then
		if grab.Latch(holder, target, {Def = move, Bones = target.source_pose.bones}) then
			self.grabbed = target
			holder.character_pose:SetFocusOn(nil, runner.frame.point)
		end
	end
end

function META:Throw(event, f)
	local victim = self.grabbed

	if not victim then return end

	local holder = self:GetHolder()
	local forward = actors.GetForward(holder)
	local throw = grab.Get(victim):GetVelocity(f, self:GetRunner().duration) * event.Inherit + Vec3(-forward.z, 0, forward.x) * event.Throw.x + Vec3(0, event.Throw.y, 0) + forward * event.Throw.z
	local weapon = self.Owner.weapon

	for i, type_name in ipairs(weapon:GetDamageTypes(SLASH)) do
		if not victim.health:IsDead() then
			damage.Deal(
				victim,
				{
					Attacker = holder,
					Inflictor = self.Owner,
					Damage = self.Damage * event.Damage * weapon:GetDamageScale(),
					Type = type_name,
					Secondary = i > 1,
					Position = actors.GetCenter(victim),
					Direction = throw:GetNormalized(),
				}
			)
		end
	end

	self:EndGrab(throw)
end

function META:Chain(move, authority)
	local set = movesets.Get(self.Moveset)
	local queued = self.queued
	self.idle = 0

	if queued == "heavy" then
		self.combo = 0
		self:StartMove(move.Branch or set.Heavy, authority)
	elseif queued == "light" then
		if move.Next then
			self:StartMove(move.Next, authority)
		else
			self.combo = self.combo % #set.Combo + 1
			self:StartMove(set.Combo[self.combo], authority)
		end
	end
end

function META:OnMoveEvent(move, event, f)
	if event.Type == "hit" then
		self:Hit(event, self:GetRunner():GetStrikeForward())
	elseif event.Type == "latch" then
		self:Latch(move, event)
	else
		self:Throw(event, f)
	end
end

function META:OnMoveInterrupted()
	if self.grabbed then self:EndGrab(Vec3()) end

	self.queued = nil
end

function META:Step(dt, cmd, authority)
	local ticks = cmd.number - self.last_number
	self.last_number = cmd.number

	if ticks < 0 or ticks > MAX_COMMAND_GAP then ticks = 1 end

	dt = dt * ticks
	local runner = self:GetRunner()

	if not runner:IsPlaying() then
		self.idle = self.idle + dt
		self.hold = 0
		return
	end

	if self.Owner.weapon:IsPrimaryDown(cmd) then
		self.hold = self.hold + dt

		if self.hold >= HOLD_HEAVY and not self.queued then
			self.queued = "heavy"
			self.hold = -math.huge
		end
	else
		self.hold = 0
	end

	local state, move = runner:Step(dt, authority, self.queued)

	if state == "finished" then self:Chain(move, authority) end
end

function META:OnWeaponThink(dt, cmd)
	self:Step(dt, cmd, true)
end

function META:OnWeaponPredictThink(dt, cmd)
	self:Step(dt, cmd, false)
end

function META:OnWeaponHolster()
	if self.grabbed then self:EndGrab(Vec3()) end

	self:GetRunner():Cancel()
	self.queued = nil
end

local function get_world_position(node)
	return Vec3(node.transform:GetWorldMatrix():GetTranslation())
end

function META:OnUpdate(dt)
	if not effects.Visual then return end

	local holder = self:GetHolder()
	local pose = holder:IsValid() and holder.character_pose
	local weapon = self.Owner.weapon
	local name, phase

	if pose and weapon:IsEquipped() and not weapon:IsSheathed() then
		name, phase = pose:GetActiveAction()
	end

	local move = name and movesets.GetMove(name)
	local swing = move and movesets.IsSwinging(move, phase)

	if swing and swing ~= self.swing then
		sounds.PlayRandom(SWING_SOUNDS, holder.transform:GetPosition(), 0.7, math.randomf(1, 1.3) * self.SwingPitch)
	end

	if self.swing and swing ~= self.swing then self:EndTrail() end

	self.swing = swing
	local fading = self.fading_trails

	for i = #fading, 1, -1 do
		local entry = fading[i]
		entry.fade = entry.fade - dt * TRAIL_FADE_RATE

		if entry.fade <= 0 then
			entry.trail:Release()
			table.remove(fading, i)
		else
			entry.trail:SetAlpha(entry.fade)
		end
	end

	local instance = self.Owner.prefab

	if not swing then
		if self.sparks then
			self.linger = self.linger - dt

			if self.linger > 0 then
				local tip = get_world_position(instance:GetNode("blade_tip"))
				self.sparks:Move(tip.x, tip.y, tip.z)
			else
				self.sparks:Release()
				self.sparks = nil
			end
		end

		return
	end

	local base = get_world_position(instance:GetNode("blade_base"))
	local tip = get_world_position(instance:GetNode("blade_tip"))

	if not self.trail then
		if self.sparks then
			self.sparks:Release()
			self.sparks = nil
		end

		local attributes = weapon.Attributes
		self.color = #attributes > 0 and damage_types.MixColor(attributes) or self.TrailColor
		local overlay = damage_types.Get(attributes[1] or "slash")
		local overlay_config = TRAIL_OVERLAY_CONFIG

		if #attributes > 0 then
			overlay_config = table.shallow_copy(TRAIL_OVERLAY_CONFIG)
			overlay_config.ColorA = self.color
		end

		self.trail = effects.vfx.AcquireSlashTrail(self.color, TRAIL_STRENGTH, TRAIL_POINTS, overlay.Overlay, overlay_config)
		self.line = effects.vfx.AcquireTrail(self.color, LINE_STRENGTH, LINE_POINTS, LINE_RADIUS, nil, LINE_SUBDIVISIONS, LINE_END_TAPER)
	end

	if not self.sparks then
		self.sparks = flow_ribbons.AcquireEmitter{
			color = self.color,
			core = WHITE,
			density = SPARK_DENSITY,
			exposure_compensation = effect_exposure.particles,
		}
	end

	self.sparks:Move(tip.x, tip.y, tip.z)
	self.trail:Push(base, tip)
	self.line:Push(tip)
end

function META:EndTrail()
	if not self.trail then return end

	local fading = self.fading_trails
	fading[#fading + 1] = {trail = self.trail, fade = 1}
	fading[#fading + 1] = {trail = self.line, fade = 1}
	self.trail = nil
	self.line = nil
	self.linger = SPARK_LINGER
end

function META:OnRemove()
	if self.trail then self.trail:Release() end

	if self.line then self.line:Release() end

	for _, entry in ipairs(self.fading_trails) do
		entry.trail:Release()
	end

	if self.sparks then self.sparks:Release() end
end

return META:Register()
]=====],
}
