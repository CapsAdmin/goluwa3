local objects = import("goluwa/objects/objects.lua")
local Entity = import("goluwa/entities/entity.lua")
local bsp = import("goluwa/source_engine/bsp.lua")
local game = import("goluwa/source_engine/game.lua")
local units = import("goluwa/source_engine/units.lua")
local scene = import("goluwa/entities/scene.lua")
local model_loader = import("goluwa/render3d/model_loader.lua")
local VisibilityGroup = import("goluwa/entities/components/visibility_group.lua")
local file_path = import("goluwa/filesystem/path.lua")
local timer = import("goluwa/timer.lua")
local Color = import("goluwa/structs/color.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local META = objects.CreateTemplate("bsp_world")
META:StartStorable()
META:GetSet("Path", "", {callback = "Load"})
META:EndStorable()

function META:Clear()
	local owner = self.Owner

	for _, child in ipairs(owner:GetChildren()) do
		if child.bsp_generated then child:Remove() end
	end

	if owner:HasComponent("rigid_body") then owner:RemoveComponent("rigid_body") end

	VisibilityGroup.SetLocator(nil)
	VisibilityGroup.SetActive(nil)
	self.groups = {}
	self.sub_groups = {}
end

function META:Load()
	self:Clear()

	if self.Path == "" then return end

	game.EnsureMounted(self.Path)
	self.load_id = (self.load_id or 0) + 1
	local load_id = self.load_id
	local path = self.Path

	scene.WhenIdle(function()
		timer.Delay(0, function()
			if self:IsValid() and self.load_id == load_id then self:Start(path, load_id) end
		end)
	end)
end

function META:Start(path, load_id)
	model_loader.LoadModel(
		path,
		function()
			if not self:IsValid() or self.load_id ~= load_id then return end

			timer.Delay(0, function()
				if self:IsValid() and self.load_id == load_id then self:Build(path) end
			end)
		end,
		nil,
		function(err)
			if self:IsValid() and self.load_id == load_id then self:Fail(path, err) end
		end
	)
end

function META:Fail(path, err)
	wlog("bsp_world: failed to load %s: %s", path, tostring(err))
	local shapes = import("goluwa/render3d/shapes.lua")
	local placeholder = shapes.Box{
		Name = "missing " .. path,
		Collision = false,
		RigidBody = false,
		Material = {Color = Color(1, 0, 1, 1)},
	}
	placeholder:SetParent(self.Owner)
	placeholder:SetTransient(true)
	placeholder.bsp_generated = true
end

function META:GetContainer(id)
	if not id then return self.Owner end

	local group = self.groups[id]

	if group then return group end

	local name = "visibility_group_" .. id

	for _, child in ipairs(self.Owner:GetChildren()) do
		if child:GetName() == name then
			group = child

			break
		end
	end

	group = group or Entity.New{Name = name, Parent = self.Owner}

	if not group:HasComponent("transform") then group:AddComponent("transform") end

	if not group:HasComponent("visibility_group") then
		group:AddComponent("visibility_group")
	end

	group.spawned_from_bsp = true
	self.groups[id] = group
	return group
end

function META:GetSubGroup(container, name)
	local sub_groups = self.sub_groups[container]

	if not sub_groups then
		sub_groups = {}
		self.sub_groups[container] = sub_groups

		for _, child in ipairs(container:GetChildren()) do
			sub_groups[child:GetName()] = child
		end
	end

	local sub_group = sub_groups[name]

	if not sub_group then
		sub_group = Entity.New{Name = name, Parent = container}
		sub_group.spawned_from_bsp = true
		sub_groups[name] = sub_group
	end

	return sub_group
end

function META:Build(path)
	local owner = self.Owner
	local data = bsp.resolved[path]

	if not data then
		self:Fail(path, "map data was not produced")
		return
	end

	local worlds = {}

	if RENDER_2D then
		for _, prim in ipairs(data.render_meshes) do
			local container = self:GetContainer(prim.visibility_group)
			local world = worlds[container]

			if not world then
				world = Entity.New{Name = "world", Parent = container}
				world:SetTransient(true)
				world:AddComponent("transform")
				world:AddComponent("visual")
				world.bsp_generated = true
				world.spawned_from_bsp = true
				worlds[container] = world
			end

			world.visual:CreatePrimitiveEntity(
				prim.mesh,
				prim.material,
				file_path.RemoveExtensionFromPath(file_path.GetFileNameFromPath(prim.material:GetName()))
			)
		end

		for _, world in pairs(worlds) do
			world.visual:BuildAABB()
		end
	end

	if data.physics_body then
		bsp.BindOwner(data, owner)
		owner:AddComponent("rigid_body", data.physics_body)
	end

	if data.visibility.group_count > 0 then
		local point_leaf = data.visibility.point_leaf
		local area_groups = data.visibility.area_groups
		local group_bounds = data.visibility.group_bounds
		local group_ids = {}

		for id = 1, data.visibility.group_count do
			group_ids[self:GetContainer(id).visibility_group] = id
		end

		local groups = self.groups

		VisibilityGroup.SetLocator(function(pos)
			local source = units.PositionFromEngine(pos)
			local area = point_leaf(source).area

			if area ~= 0 then
				local id = area_groups[area]
				return id and groups[id].visibility_group or false
			end

			local active = VisibilityGroup.GetActive()
			local bounds = active and group_bounds[group_ids[active]]

			if
				bounds and
				source.x >= bounds.min.x and
				source.y >= bounds.min.y and
				source.z >= bounds.min.z and
				source.x <= bounds.max.x and
				source.y <= bounds.max.y and
				source.z <= bounds.max.z
			then
				return nil
			end

			return false
		end)
	end
end

function META:OnRemove()
	VisibilityGroup.SetLocator(nil)
	VisibilityGroup.SetActive(nil)
end

return META:Register()
