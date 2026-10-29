local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local system = import("goluwa/system.lua")
local Color = import("goluwa/structs/color.lua")
local Beam = import("goluwa/render3d/beam.lua")
local render3d = import("goluwa/render3d/render3d.lua")
local effect_exposure = import("lua/jrpg/effect_exposure.lua")
local surface_overlays = import("goluwa/render3d/surface_overlays.lua")
local visual_bounds = import("lua/visual_bounds.lua")
local weapon_stats = import("lua/jrpg/weapon_stats.lua")
local META = objects.CreateTemplate("item_highlight")
META:StartStorable()
META:GetSet("Color", Color(1, 0.75, 0.2, 1))
META:GetSet("Height", 1)
META:GetSet("Width", 0.06)
META:GetSet("GlowRadius", 0.45)
META:GetSet("FadeTime", 1.2)
META:EndStorable()
local POINTS = 10
local RIBBONS = 3
local bounds
local points = Beam.NewPoints(POINTS)
local glow_points = Beam.NewPoints(2)
local GLOW_STRENGTH = 0.8
local GLOW_SCALES = {1, 0.45}
local glow_color = Color(1, 1, 1, 1)

function META:Initialize()
	if not (CLIENT and RENDER_3D) then return end

	self:AddGlobalEvent("Update")
	self.phase = math.random() * 100
end

function META:GetHighlightColor()
	return weapon_stats.GetColor(self.Owner.weapon.Rarity) or self.Color
end

function META:Build()
	self.rarity = self.Owner.weapon.Rarity
	self.beams = {}
	self.offsets = {}
	local color = self:GetHighlightColor()

	for i = 1, RIBBONS do
		self.beams[i] = Beam.New{
			Points = POINTS,
			Ribbon = true,
			Radius = self.Width,
			RadiusEnd = 0,
			Material = Beam.CreateRibbonMaterial(color, 12, nil, {ExposureCompensation = effect_exposure.trails}),
		}
		self.offsets[i] = math.random() * 2 - 1
	end

	self.fade = 0
	self.glows = {}
	self.glow_materials = {}
	self.overlays = {}

	for i, scale in ipairs(GLOW_SCALES) do
		self.glow_materials[i] = Beam.CreateRibbonMaterial(
			color,
			GLOW_STRENGTH,
			Beam.GetGlowTexture(),
			{
				IgnoreZ = true,
				OcclusionRadius = self.GlowRadius * 1.6,
				OcclusionSoftness = self.GlowRadius,
			}
		)
		self.glows[i] = Beam.New{
			Points = 2,
			Ribbon = true,
			Radius = self.GlowRadius * scale,
			Material = self.glow_materials[i],
		}
	end

	self.emitter = Entity.New{
		Name = "item_highlight_motes",
		transform = {},
		particle_emitter_gpu = {
			MaxParticles = 64,
			Rate = 8,
			Spread = 180,
			SpeedMin = 0.05,
			SpeedMax = 0.3,
			LifetimeMin = 1.5,
			LifetimeMax = 3,
			SizeStart = 0.03,
			SizeEnd = 0,
			Drag = 1,
			Lit = false,
			GravityScale = -0.03,
			Emissive = 2e5,
			ExposureCompensation = effect_exposure.particles,
			ColorStart = Color(color.r, color.g, color.b, 1),
			ColorEnd = Color(color.r, color.g, color.b, 0),
		},
	}
	self.emitter:SetTransient(true)
end

function META:SetOverlayVisible(visible)
	for _, handle in ipairs(self.overlays) do
		handle:Remove()
	end

	table.clear(self.overlays)
	self.overlay_visible = visible

	if not visible then return end

	local color = self:GetHighlightColor()
	local config = {
		ColorA = color,
		ColorB = Color(color.r * 0.4 + 0.6, color.g * 0.4 + 0.6, color.b * 0.4 + 0.6, 1),
	}

	for _, child in ipairs(self.Owner:GetChildrenList()) do
		if child.visual then
			self.overlays[#self.overlays + 1] = surface_overlays.Add(child.visual, "item_highlight", config)
		end
	end
end

function META:OnEntityConstructed()
	if not self.overlays then return end

	self:SetOverlayVisible(self:IsShown())
end

function META:IsDropped()
	return not self.Owner.weapon:IsHeld()
end

function META:IsShown()
	return self:IsDropped()
end

function META:GetAnchor()
	bounds = visual_bounds.Get(self.Owner, bounds)
	return bounds
end

function META:OnUpdate(dt)
	if self.beams and self.rarity ~= self.Owner.weapon.Rarity then self:Destroy() end

	if not self.beams then self:Build() end

	local dropped = self:IsShown() and self:GetAnchor() ~= nil

	if self.overlay_visible ~= dropped then self:SetOverlayVisible(dropped) end

	for _, beam in ipairs(self.beams) do
		beam:SetVisible(dropped)
	end

	for _, glow in ipairs(self.glows) do
		glow:SetVisible(dropped)
	end

	self.emitter.particle_emitter_gpu:SetVisible(dropped)

	if not dropped then
		self.fade = 0
		return
	end

	self.fade = math.min(self.fade + math.min(dt, 0.05) / self.FadeTime, 1)
	local ease = 1 - (1 - self.fade) ^ 3
	local time = system.GetElapsedTime() + self.phase
	local center = bounds:GetCenter()
	local base_y = bounds.min_y
	local height = self.Height * ease
	self.emitter.transform:SetPosition(center)

	for i, beam in ipairs(self.beams) do
		local seed = self.offsets[i]
		local sway = 0.04 + 0.02 * i

		for p = 1, POINTS do
			local f = (p - 1) / (POINTS - 1)
			local angle = time * (0.8 + 0.3 * seed) + seed * 6 + f * 3
			points[p]:Set(
				center.x + math.sin(angle) * sway * f * (1 + seed * 0.5),
				base_y + f * height * (0.75 + 0.25 * math.sin(time * 0.7 + i)),
				center.z + math.cos(angle * 0.8) * sway * f
			)
		end

		beam:SetRibbonPoints(points, 0, 1)
	end

	local up = render3d.GetCamera():GetRotation():GetUp()
	local pulse = 0.75 + 0.25 * math.sin(time * 4)

	for i, glow in ipairs(self.glows) do
		local radius = self.GlowRadius * GLOW_SCALES[i] * (0.4 + 0.6 * ease) * (i == 1 and pulse or 1)
		glow_points[1]:Set(center.x - up.x * radius, base_y + 0.03 - up.y * radius, center.z - up.z * radius)
		glow_points[2]:Set(center.x + up.x * radius, base_y + 0.03 + up.y * radius, center.z + up.z * radius)
		glow:SetRadius(radius)
		glow:SetRibbonPoints(glow_points, 0, 1)
		glow_color.a = GLOW_STRENGTH * ease * (i == 1 and pulse or 1)
		self.glow_materials[i]:SetEmissiveMultiplier(glow_color)
	end
end

function META:OnRemove()
	if self.beams then self:Destroy() end
end

function META:Destroy()
	self:SetOverlayVisible(false)

	for _, beam in ipairs(self.beams) do
		beam:Remove()
	end

	for _, glow in ipairs(self.glows) do
		glow:Remove()
	end

	self.emitter:Remove()
	self.beams = nil
end

return META:Register()
