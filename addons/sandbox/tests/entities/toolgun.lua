local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local event = import("goluwa/event.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local objects = import("goluwa/objects/objects.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
import("addons/game/lua/autorun/characters.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/damage.lua")
import("lua/weapons.lua")
import("addons/sandbox/lua/autorun/weapons.lua")
local toolgun = import("lua/toolgun.lua")
local history = import("lua/game_history.lua").history

local function create_world_box(position, size)
	return Entity.New{
		transform = {Position = position},
		rigid_body = {MotionType = "static", Shape = BoxShape.New(size), WorldGeometry = true},
	}
end

local function create_box(position)
	return Entity.New{
		Name = "box",
		Transient = false,
		transform = {Position = position},
		rigid_body = {
			MotionType = "dynamic",
			Shape = BoxShape.New(Vec3(0.5, 0.5, 0.5)),
			Mass = 10,
			AutomaticMass = false,
		},
	}
end

local function create_holder()
	local holder = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
			"health",
		},
		transform = {Position = Vec3(0, 0.05, 0)},
		player_controller = {Source = "queue"},
	}
	holder.player_controller.cmd.mode = "walk"
	local gun = holder.weapon_holder:FindWeapon("weapon_toolgun") or
		holder.weapon_holder:Give("weapon_toolgun")
	holder.weapon_holder:Equip(gun, "right")
	return holder, gun.weapon_toolgun:GetContext()
end

local function click(holder, context, point, action)
	local eye = holder.transform:GetPosition() + holder.character_movement:GetViewOffset()
	local cmd = usercmd.New()
	cmd.view = Quat():SetLookDirection((point - eye):GetNormalized())
	cmd.buttons = usercmd.BUTTON.ACTIVE
	return toolgun.Fire(context, cmd, action or "LeftClick")
end

local function step(seconds)
	for _ = 1, math.max(math.floor(seconds * 60), 1) do
		physics.UpdateFixed(1 / 60)
		event.Call("Update", 1 / 60)
	end
end

local function get_constraints(kind)
	local found = {}

	for _, component in ipairs(import("lua/components/constraint.lua").Instances) do
		if component:IsValid() and component.Kind == kind then
			found[#found + 1] = component
		end
	end

	return found
end

local function setup()
	history:Clear()
	create_world_box(Vec3(0, -0.5, 0), Vec3(100, 1, 100))
	return create_holder()
end

T.TestPhysics("toolgun welds two objects in two clicks and undo and redo remove and restore the weld", function()
	local holder, context = setup()
	local a = create_box(Vec3(-1, 0.25, -3))
	local b = create_box(Vec3(1, 0.25, -3))
	toolgun.Select("weld")
	T(click(holder, context, Vec3(-1, 0.25, -3)))["=="](true)
	T(context:GetStage())["=="](1)
	T(click(holder, context, Vec3(-1, 0.25, -3)))["=="](false)
	T(click(holder, context, Vec3(1, 0.25, -3)))["=="](true)
	T(context:GetStage())["=="](0)
	local welds = get_constraints("weld")
	T(#welds)["=="](1)
	local weld = welds[1]
	local guid = weld.Owner:GetGUID()
	T(weld.Entity0)["=="](a:GetGUID())
	T(weld.Entity1)["=="](b:GetGUID())
	step(0.1)
	T(weld:IsBuilt())["=="](true)
	T(list.has_value(physics.GetConstraints(), weld:GetPhysicsConstraint()) ~= false)["=="](true)
	local built = weld:GetPhysicsConstraint()
	history:Undo()
	T(objects.GetObjectByGUID(guid):IsValid())["=="](false)
	T(list.has_value(physics.GetConstraints(), built))["=="](false)
	history:Redo()
	local restored = objects.GetObjectByGUID(guid)
	T(restored:IsValid())["=="](true)
	step(0.1)
	T(restored.constraint:IsBuilt())["=="](true)
	T(restored.constraint.Entity1)["=="](b:GetGUID())
end)

T.TestPhysics("a weld to the world holds an object in the air", function()
	local holder, context = setup()
	local box = create_box(Vec3(0, 2, -3))
	toolgun.Select("weld")
	click(holder, context, Vec3(0, 2, -3))
	click(holder, context, Vec3(0, 0, -1.5))
	T(get_constraints("weld")[1].Entity1)["=="]("")
	step(1)
	T(box.transform:GetPosition().y)[">"](1.9)
end)

T.TestPhysics("a rope holds an object below a ceiling and goes when the object is removed", function()
	local holder, context = setup()
	create_world_box(Vec3(0, 6.5, -4), Vec3(10, 1, 10))
	local box = create_box(Vec3(0, 2.75, -4))
	toolgun.Select("rope")
	toolgun.SetSetting("rope", "AddLength", 0.5)
	click(holder, context, Vec3(0, 2.75, -4))
	click(holder, context, Vec3(0, 6, -4))
	local rope = get_constraints("rope")[1]
	T(rope.Length)[">"](3.8)
	T(rope.Length)["<"](3.9)
	step(1.5)
	T(box.transform:GetPosition().y)[">"](2)
	T(box.transform:GetPosition().y)["<"](2.75)
	local owner = rope.Owner
	box:Remove()
	T(owner:IsValid())["=="](false)
	toolgun.SetSetting("rope", "AddLength", 0)
end)

T.TestPhysics("reload removes the constraints of the selected kind and undo brings them back", function()
	local holder, context = setup()
	local a = create_box(Vec3(-1, 0.25, -3))
	local b = create_box(Vec3(1, 0.25, -3))
	toolgun.Select("no_collide")
	click(holder, context, Vec3(-1, 0.25, -3))
	click(holder, context, Vec3(1, 0.25, -3))
	toolgun.Select("weld")
	click(holder, context, Vec3(-1, 0.25, -3))
	click(holder, context, Vec3(1, 0.25, -3))
	T(#toolgun.GetConstraints(a))["=="](2)
	T(click(holder, context, Vec3(1, 0.25, -3), "Reload"))["=="](true)
	T(#get_constraints("weld"))["=="](0)
	T(#get_constraints("no_collide"))["=="](1)
	history:Undo()
	T(#get_constraints("weld"))["=="](1)
	history:Redo()
	T(#get_constraints("weld"))["=="](0)
	toolgun.Select("remover")
	T(click(holder, context, Vec3(1, 0.25, -3), "Reload"))["=="](true)
	T(#toolgun.GetConstraints(b))["=="](0)
	history:Undo()
	T(#get_constraints("no_collide"))["=="](1)
end)

T.TestPhysics("weight and physical properties change the body and undo restores it", function()
	local holder, context = setup()
	local box = create_box(Vec3(0, 0.25, -3))
	local body = box.rigid_body
	toolgun.Select("weight")
	toolgun.SetSetting("weight", "Mass", 123)
	T(click(holder, context, Vec3(0, 0.25, -3)))["=="](true)
	T(body:GetMass())["=="](123)
	toolgun.Select("physical_properties")
	toolgun.SetSetting("physical_properties", "Material", "ice")
	toolgun.SetSetting("physical_properties", "Gravity", false)
	T(click(holder, context, Vec3(0, 0.25, -3)))["=="](true)
	T(body:GetFriction())["<"](0.05)
	T(body:GetGravityScale())["=="](0)
	history:Undo()
	T(body:GetGravityScale())["=="](1)
	T(body:GetFriction())["=="](0)
	history:Undo()
	T(body:GetMass())["=="](10)
	history:Redo()
	history:Redo()
	T(body:GetMass())["=="](123)
	T(body:GetGravityScale())["=="](0)
	toolgun.SetSetting("physical_properties", "Gravity", true)
end)

T.TestPhysics("switching tools drops a half made constraint and the primary attack fires the tool", function()
	local holder, context = setup()
	create_box(Vec3(-1, 0.25, -3))
	create_box(Vec3(1, 0.25, -3))
	toolgun.Select("weld")
	click(holder, context, Vec3(-1, 0.25, -3))
	T(context:GetStage())["=="](1)
	toolgun.Select("axis")
	context:Refresh()
	T(context:GetStage())["=="](0)
	local gun = holder.weapon_holder:GetWeapon("right")
	local eye = holder.transform:GetPosition() + holder.character_movement:GetViewOffset()
	local cmd = usercmd.New()
	cmd.view = Quat():SetLookDirection((Vec3(-1, 0.25, -3) - eye):GetNormalized())
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.ATTACK1
	cmd.pressed = usercmd.BUTTON.ATTACK1
	gun.weapon:Think(1, cmd, usercmd.BUTTON.ATTACK1, usercmd.BUTTON.ATTACK2)
	T(context:GetStage())["=="](1)
	cmd.buttons = usercmd.BUTTON.ACTIVE + usercmd.BUTTON.RELOAD
	cmd.pressed = usercmd.BUTTON.RELOAD
	gun.weapon:Think(1, cmd, usercmd.BUTTON.ATTACK1, usercmd.BUTTON.ATTACK2)
	T(context:GetStage())["=="](0)
end)

T.TestPhysics("a motor spins an object around the normal of the clicked face", function()
	local holder, context = setup()
	local box = create_box(Vec3(0, 2, -3))
	box.rigid_body:SetGravityScale(0)
	toolgun.Select("motor")
	toolgun.SetSetting("motor", "Speed", 4)
	click(holder, context, Vec3(0, 2, -3))
	create_world_box(Vec3(2, 2, -3), Vec3(1, 1, 1))
	T(click(holder, context, Vec3(1.5, 2, -3)))["=="](true)
	step(1)
	local angular = box.rigid_body:GetAngularVelocity()
	T(math.abs(angular.z))[">"](3.5)
	T(math.abs(angular.x) + math.abs(angular.y))["<"](0.5)
	T(box.transform:GetPosition():Distance(Vec3(0, 2, -3)))["<"](0.1)
	toolgun.SetSetting("motor", "Speed", 6)
end)

T.TestPhysics("every constraint tool builds a joint that keeps the simulation stable", function()
	local holder, context = setup()

	for _, kind in ipairs{
		"weld",
		"axis",
		"ball_socket",
		"rope",
		"elastic",
		"slider",
		"motor",
		"no_collide",
	} do
		local a = create_box(Vec3(-1, 0.25, -3))
		local b = create_box(Vec3(1, 0.25, -3))
		toolgun.Select(kind)
		click(holder, context, Vec3(-1, 0.25, -3))
		T(click(holder, context, Vec3(1, 0.25, -3)))["=="](true)
		step(0.5)
		local constraint = get_constraints(kind)[1]
		T(constraint:IsBuilt())["=="](true)

		for _, box in ipairs{a, b} do
			local position = box.transform:GetPosition()
			T(position.x == position.x and position:Distance(Vec3(0, 0.25, -3)) < 3)["=="](true)
		end

		a:Remove()
		b:Remove()
		T(get_constraints(kind)[1])["=="](nil)
	end

	local box = create_box(Vec3(0, 0.25, -3))
	toolgun.Select("keep_upright")
	T(click(holder, context, Vec3(0, 0.25, -3)))["=="](true)
	T(click(holder, context, Vec3(0, 0.25, -3)))["=="](false)
	step(0.2)
	T(get_constraints("keep_upright")[1]:IsBuilt())["=="](true)
end)

T.TestPhysics("the toolgun trace hits a body that is kinematic on a client but dynamic on the server", function()
	local holder = setup()
	local box = create_box(Vec3(0, 0.25, -3))
	local eye = holder.transform:GetPosition() + holder.character_movement:GetViewOffset()
	local view = Quat():SetLookDirection((Vec3(0, 0.25, -3) - eye):GetNormalized())
	box.rigid_body:SetMotionType("kinematic")
	T(toolgun.Trace(holder, view).entity)["=="](nil)
	box.rigid_body:SetServerDynamic(true)
	T(toolgun.Trace(holder, view).entity)["=="](box)
end)
