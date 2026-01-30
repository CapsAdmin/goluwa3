local LSX = require("lsx")
local ecs = require("ecs.ecs")
local prototype = require("prototype")
local Vec2 = require("structs.vec2")
local DefaultAdapter = {
	GetRoot = function()
		return ecs.Get2DWorld()
	end,
	SetProperty = function(ent, key, value)
		if type(value) == "table" and ent.GetComponent then
			local comp = ent:GetComponent(key)

			if comp then
				for k, v in pairs(value) do
					local setterName = "Set" .. k:sub(1, 1):upper() .. k:sub(2)

					if comp[setterName] then
						local getterName = "Get" .. k:sub(1, 1):upper() .. k:sub(2)
						local getter = comp[getterName]
						local currentVal = getter and getter(comp)

						if currentVal ~= v then comp[setterName](comp, v) end
					else
						comp[k] = v
					end
				end

				return
			end
		end

		local setterName = "Set" .. key:sub(1, 1):upper() .. key:sub(2)
		local getterName = "Get" .. key:sub(1, 1):upper() .. key:sub(2)

		if ent[setterName] then
			local getter = ent[getterName]
			local currentVal = getter and getter(ent)

			if currentVal ~= value then ent[setterName](ent, value) end

			return
		end

		for _, comp in pairs(ent.ComponentsHash) do
			if comp[setterName] then
				local getter = comp[getterName]
				local currentVal = getter and getter(comp)

				if currentVal ~= value then comp[setterName](comp, value) end

				return
			end
		end

		if key:sub(1, 2) == "On" or key:sub(1, 2) == "on" then
			local eventName = "On" .. key:sub(3, 3):upper() .. key:sub(4)

			if ent[eventName] ~= value then ent[eventName] = value end
		end
	end,
	SetLayout = function(ent, layout)
		local comp = ent:GetComponent("layout_2d")

		if comp then comp:SetLayout(layout) end
	end,
	InvalidateLayout = function(ent)
		local comp = ent:GetComponent("layout_2d")

		if comp then comp:InvalidateLayout() end
	end,
	PostRender = function(ent)
		if type(ent) == "table" and ent.IsValid then
			if ent:IsValid() then
				local layout = ent:GetComponent("layout_2d")

				if layout then layout:InvalidateLayout() end
			end
		elseif type(ent) == "table" then
			for _, child in ipairs(ent) do
				if type(child) == "table" and child.IsValid and child:IsValid() then
					local layout = child:GetComponent("layout_2d")

					if layout then layout:InvalidateLayout() end
				end
			end
		end
	end,
}
local lsx = LSX.New(DefaultAdapter)

function lsx:UseAnimation(ref)
	return self:UseCallback(
		function(config)
			if ref.current then
				local anim = ref.current:GetComponent("animations_2d")

				if anim then anim:Animate(config) end
			end
		end,
		{ref}
	)
end

function lsx:UseMouse()
	local pos, set_pos = self:UseState(function()
		local mpos = require("window").GetMousePosition()
		return Vec2(mpos.x, mpos.y)
	end)

	self:UseEffect(
		function()
			return require("event").AddListener("Update", {}, function()
				local mpos = require("window").GetMousePosition()

				set_pos(function(old)
					if old.x == mpos.x and old.y == mpos.y then return old end

					return Vec2(mpos.x, mpos.y)
				end)
			end)
		end,
		{}
	)

	return pos
end

function lsx:UseHover(ref)
	local is_hovered, set_hovered = self:UseState(false)

	self:UseEffect(
		function()
			if not ref.current then return end

			local ent = ref.current
			local cleanup1 = ent:AddLocalListener("OnMouseEnter", function()
				set_hovered(true)
			end)
			local cleanup2 = ent:AddLocalListener("OnMouseLeave", function()
				set_hovered(false)
			end)
			local mpos = require("window").GetMousePosition()
			local gui = ent:GetComponent("gui_element_2d")

			if gui then set_hovered(not not gui:IsHovered(mpos)) end

			return function()
				cleanup1()
				cleanup2()
			end
		end,
		{ref.current}
	)

	return is_hovered
end

function lsx:UseHoverExclusively(ref)
	local is_hovered, set_hovered = self:UseState(false)

	self:UseEffect(
		function()
			if not ref.current then return end

			local ent = ref.current
			local cleanup1 = ent:AddLocalListener("OnMouseEnter", function()
				set_hovered(true)
			end)
			local cleanup2 = ent:AddLocalListener("OnMouseLeave", function()
				set_hovered(false)
			end)
			local mpos = require("window").GetMousePosition()

			if ent.IsHoveredExclusively then
				set_hovered(not not ent:IsHoveredExclusively(mpos))
			end

			return function()
				cleanup1()
				cleanup2()
			end
		end,
		{ref.current}
	)

	return is_hovered
end

function lsx:UseAnimate(ref, config, deps)
	self:UseEffect(
		function()
			if not ref.current then return end

			local anim = ref.current:GetComponent("animations_2d")

			if anim then anim:Animate(config) end
		end,
		deps
	)
end

lsx.Panel = lsx:RegisterElement(require("ecs.entities.2d.panel"))
lsx.Text = lsx:RegisterElement(require("ecs.entities.2d.text"))
return lsx
