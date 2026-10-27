local T = import("test/environment.lua")
local Entity = import("goluwa/entities/entity.lua")
local physics = import("goluwa/physics.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
import("addons/game/lua/autorun/characters.lua")
import("addons/game/lua/autorun/usable.lua")
Entity.RegisterComponent("player_controller", import("lua/components/player_controller.lua"))
Entity.RegisterComponent("character_movement", import("lua/components/character_movement.lua"))
Entity.RegisterComponent("weapon", import("lua/components/weapon.lua"))
Entity.RegisterComponent("weapon_holder", import("lua/components/weapon_holder.lua"))
import("lua/weapons.lua")
import("addons/sandbox/lua/autorun/vehicles.lua")
local vehicles = import("lua/vehicles.lua")
local BUTTON = usercmd.BUTTON

local function create_ground(y)
	return Entity.New{
		transform = {Position = Vec3(0, (y or 0) - 0.5, 0)},
		rigid_body = {
			MotionType = "static",
			Shape = BoxShape.New(Vec3(800, 1, 800)),
			Friction = 0.85,
			WorldGeometry = true,
		},
	}
end

local function create_driver(position)
	local driver = Entity.New{
		ComponentSet = {
			"transform",
			"player_controller",
			"character_movement",
			"character_pose",
			"weapon_holder",
		},
		transform = {Position = position or Vec3(4, 0.1, 4)},
		player_controller = {Source = "queue"},
	}
	driver.player_controller.buffer_target = 1
	driver.player_controller.cmd.mode = "walk"
	return driver
end

local function spawn(name)
	return vehicles.Spawn(name, Vec3(0, 0, 0), -math.pi / 2)
end

local function drive(driver, ticks, setup)
	local controller = driver.player_controller

	for _ = 1, ticks do
		local cmd = usercmd.New()
		controller.next_number = (controller.next_number or 0) + 1
		cmd.number = controller.next_number
		cmd.mode = "walk"
		cmd.buttons = BUTTON.ACTIVE

		if setup then setup(cmd) end

		controller:PushCommands({cmd})
		physics.UpdateFixed(1 / 60)
	end
end

local function forward(cmd)
	cmd.forward = 1
end

local function heading(entity)
	local direction = entity.transform:GetRotation():GetForward()
	return math.atan2(-direction.x, -direction.z)
end

local function speed(entity)
	return entity.rigid_body:GetVelocity():Dot(entity.transform:GetRotation():GetForward())
end

local function up(entity)
	return entity.transform:GetRotation():GetUp().y
end

T.TestPhysics("a seated character follows the seat and stands beside the vehicle after using it again", function()
	create_ground()
	local car = spawn("car")
	local driver = create_driver()
	drive(driver, 30)
	T(car.seat:Enter(driver))["=="](true)
	drive(driver, 10)
	T(driver.character_movement:IsSeated())["=="](true)
	T(driver.rigid_body:IsKinematic())["=="](true)
	local seat_position = car.transform:GetPosition() + car.transform:GetRotation():VecMul(car.seat:GetPosition())
	T((driver.transform:GetPosition() - seat_position):GetLength())["<"](0.05)
	T(car.seat:Enter(create_driver(Vec3(-4, 0.1, 4))))["=="](false)

	drive(driver, 1, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.USE)
	end)

	drive(driver, 30)
	T(driver.character_pose:GetSeat():IsValid())["=="](false)
	T(driver.character_movement:IsSeated())["=="](false)
	T(driver.rigid_body:IsDynamic())["=="](true)
	local offset = driver.transform:GetPosition() - car.transform:GetPosition()
	T(offset:GetLength())[">"](1)
	T(offset:GetLength())["<"](3)
	T(driver.transform:GetPosition().y)["<"](0.2)
end)

T.TestPhysics("the car rests on its wheels, drives, steers with its front wheels and brakes", function()
	create_ground()
	local car = spawn("car")
	local driver = create_driver()
	car.seat:Enter(driver)
	drive(driver, 90)
	local rest = car.transform:GetPosition().y
	T(rest)[">"](0.45)
	T(rest)["<"](0.65)
	T(up(car))[">"](0.999)
	drive(driver, 180, forward)
	T(speed(car))[">"](12)
	T(math.abs(heading(car)))["<"](0.05)
	local lowest = 1

	drive(driver, 120, function(cmd)
		cmd.forward = 1
		cmd.side = 1
		lowest = math.min(lowest, up(car))
	end)

	T(heading(car))["<"](-1)
	T(lowest)[">"](0.85)
	local stopped = math.huge

	drive(driver, 300, function(cmd)
		cmd.forward = -1
		stopped = math.min(stopped, math.abs(speed(car)))
	end)

	T(stopped)["<"](0.5)
	T(speed(car))["<"](-2)
	T(up(car))[">"](0.99)
end)

T.TestPhysics("the motorbike stands up parked and leans into a turn without falling over", function()
	create_ground()
	local bike = spawn("motorbike")
	local driver = create_driver()
	drive(driver, 120)
	T(up(bike))[">"](0.99)
	bike.seat:Enter(driver)
	drive(driver, 150, forward)
	T(speed(bike))[">"](10)
	local leaned = 1
	local lowest = 1

	drive(driver, 180, function(cmd)
		cmd.forward = 1
		cmd.side = 1
		local right = bike.transform:GetRotation():GetRight().y
		leaned = math.min(leaned, right)
		lowest = math.min(lowest, up(bike))
	end)

	T(heading(bike))["<"](-1)
	T(leaned)["<"](-0.15)
	T(lowest)[">"](0.5)
end)

T.TestPhysics("the boat floats and its propeller pushes and turns it", function()
	create_ground(-4)
	Entity.New{
		transform = {Position = Vec3(0, 0, 0)},
		water_volume = {Size = Vec3(400, 4, 400)},
	}
	local boat = spawn("boat")
	local driver = create_driver(Vec3(4, 1, 4))
	drive(driver, 180)
	local height = boat.transform:GetPosition().y
	T(height)[">"](-0.1)
	T(height)["<"](0.4)
	T(up(boat))[">"](0.98)
	boat.seat:Enter(driver)
	drive(driver, 240, forward)
	T(speed(boat))[">"](6)

	drive(driver, 180, function(cmd)
		cmd.forward = 1
		cmd.side = -1
	end)

	T(heading(boat))[">"](1)
	T(up(boat))[">"](0.9)
end)

T.TestPhysics("the plane takes off when it is pulled up at speed", function()
	create_ground()
	local plane = spawn("plane")
	local driver = create_driver()
	plane.seat:Enter(driver)
	drive(driver, 60)
	local ground = plane.transform:GetPosition().y

	drive(driver, 420, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.SPRINT)
	end)

	T(plane.vehicle:GetThrottle())["=="](1)
	T(speed(plane))[">"](22)

	drive(driver, 240, function(cmd)
		cmd.buttons = bit.bor(cmd.buttons, BUTTON.SPRINT)
		cmd.forward = plane.transform:GetPosition().y - ground > 15 and 0 or -0.5
	end)

	T(plane.transform:GetPosition().y - ground)[">"](10)
	T(up(plane))[">"](0.5)
end)
