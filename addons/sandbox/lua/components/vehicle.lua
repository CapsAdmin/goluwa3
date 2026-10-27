local objects = import("goluwa/objects/objects.lua")
local event = import("goluwa/event.lua")
local network = import("goluwa/network/network.lua")
local physics = import("goluwa/physics.lua")
local constraints = import("goluwa/physics/constraints.lua")
local fluid = import("goluwa/physics/fluid.lua")
local BoxShape = import("goluwa/physics/shapes/box.lua")
local SphereShape = import("goluwa/physics/shapes/sphere.lua")
local CompoundShape = import("goluwa/physics/shapes/compound.lua")
local Entity = import("goluwa/entities/entity.lua")
local usercmd = import("goluwa/network/usercmd.lua")
local Vec3 = import("goluwa/structs/vec3.lua")
local Quat = import("goluwa/structs/quat.lua")
local vehicles = import("lua/vehicles.lua")
local META = objects.CreateTemplate("vehicle")
META.Network = {
	Kind = {"string", 0.5, "reliable"},
	Steer = {"number", 1 / 30, "sequenced", true},
	Throttle = {"number", 1 / 30, "sequenced", true},
	Pitch = {"number", 1 / 30, "sequenced", true},
	Roll = {"number", 1 / 30, "sequenced", true},
}
META:StartStorable()
META:GetSet("Kind", "car", {enums = vehicles.Names, callback = "Build"})
META:EndStorable()
META:GetSet("Steer", 0)
META:GetSet("Throttle", 0)
META:GetSet("Pitch", 0)
META:GetSet("Roll", 0)
local BUTTON = usercmd.BUTTON
local UP = Vec3(0, 1, 0)
local LEFT = Vec3(-1, 0, 0)
local FORWARD = Vec3(0, 0, -1)
local GRAVITY = 9.81
local AIR_DENSITY = 1.225
local ROLLING_TORQUE = 15
local STEER_GRIP = 1.1
local WHEEL_MAX_SPIN = 400
local controllers = {}

event.AddListener("ResolveUseTarget", "vehicle_wheels", function(entity)
	return entity.vehicle_root
end)

function META:Initialize()
	if self.spin then return end

	self.steer = 0
	self.throttle = 0
	self.spin = {}
	self.propeller = 0
	self:Build()
	self:AddGlobalEvent("PhysicsUpdate")
	self:AddGlobalEvent("Update")
end

-- a client can get the component from the network before the prefab sets its kind
function META:Build()
	local def = vehicles.Definitions[self.Kind]

	if self.def == def then return end

	self.def = def
	self.bases = {}
	self.base_positions = {}
	self:RemoveWheels()
	local front, rear, front_count, rear_count = 0, 0, 0, 0

	for _, wheel in ipairs(def.Wheels or {}) do
		if wheel.Steer then
			front, front_count = front + wheel.Position.z, front_count + 1
		else
			rear, rear_count = rear + wheel.Position.z, rear_count + 1
		end
	end

	self.wheelbase = front_count > 0 and
		rear_count > 0 and
		math.abs(rear / rear_count - front / front_count) or
		1

	for _, part in ipairs(def.Parts) do
		self.bases[part.Name] = part.Rotation or Quat(0, 0, 0, 1)
		self.base_positions[part.Name] = part.Position
	end

	local children = {}

	for i, collider in ipairs(def.Colliders) do
		children[i] = {
			Shape = BoxShape.New(collider.Size),
			Position = collider.Position,
			Rotation = collider.Rotation,
		}
	end

	local body = self.Owner:EnsureComponent("rigid_body")
	body:SetShape(CompoundShape.New(children))
	body:SetMotionType(network.HasAuthority() and "dynamic" or "kinematic")
	body:SetAutomaticMass(false)
	body:SetMass(def.Mass)
	body:SetFriction(0.5)
	body:SetBuoyancyDensity(def.BuoyancyDensity)
	body:SetFluidDrag(def.FluidDrag)
end

function META:GetDriver()
	return self.Owner.seat.Occupant
end

function META:GetForwardSpeed()
	local body = self.Owner.rigid_body

	if body:IsDynamic() then
		return body:GetVelocity():Dot(body:GetRotation():GetForward())
	end

	local transform = self.Owner.transform
	return transform:GetRenderVelocity():Dot(transform:GetRotation():GetForward())
end

function META:BuildWheels()
	local def = self.def
	local body = self.Owner.rigid_body
	local rotation = body:GetRotation()
	local suspension = def.Suspension
	self.wheels = {}

	for i, wheel in ipairs(def.Wheels or {}) do
		local anchor = body:LocalToWorld(wheel.Position)
		local entity = Entity.New{
			Name = "vehicle_wheel",
			Transient = true,
			transform = {Position = anchor:Copy(), Rotation = rotation:Copy()},
			rigid_body = {
				Shape = SphereShape.New(wheel.Radius),
				Mass = wheel.Mass,
				AutomaticMass = false,
				Friction = def.WheelFriction,
				MaxAngularSpeed = WHEEL_MAX_SPIN,
				SpinAxis = LEFT,
				BuoyancyDensity = 1200,
			},
		}
		entity.vehicle_root = self.Owner
		entity.rigid_body.TraceOwner = self.Owner
		local joint = constraints.Wheel(
			body,
			entity.rigid_body,
			anchor,
			rotation:VecMul(UP),
			rotation:VecMul(LEFT),
			{
				Stiffness = wheel.Stiffness or suspension.Stiffness,
				Damping = wheel.Damping or suspension.Damping,
				LowerTranslation = 0,
				UpperTranslation = suspension.Travel,
			}
		)
		self.wheels[i] = {def = wheel, entity = entity, body = entity.rigid_body, joint = joint}
	end

	if def.Balance then
		self.balance = constraints.KeepUpright(
			body,
			{
				LocalAxis = UP,
				LocalRollAxis = FORWARD,
				MaxTorque = def.Balance.MaxTorque,
				Hertz = def.Balance.Hertz,
				DampingRatio = def.Balance.DampingRatio,
			}
		)
	end
end

function META:RemoveWheels()
	for _, wheel in ipairs(self.wheels or {}) do
		wheel.joint:Remove()

		if wheel.entity:IsValid() then wheel.entity:Remove() end
	end

	if self.balance then self.balance:Remove() end

	self.wheels = nil
	self.balance = nil
end

function META:OnRemove()
	self:RemoveWheels()
end

local function ackermann(steer, x, wheelbase)
	local t = math.tan(steer)
	return math.atan2(wheelbase * t, wheelbase + x * t)
end

function META:ApplyWheels(steer, throttle, brake, handbrake)
	local engine = self.def.Engine

	for _, wheel in ipairs(self.wheels) do
		local def = wheel.def
		local joint = wheel.joint

		if def.Steer then
			joint:SetSteerAngle(ackermann(steer, def.Position.x, self.wheelbase))
		end

		if def.Drive then
			if throttle > 0 then
				joint:SetMotor(engine.Speed / def.Radius, engine.Torque * throttle)
			elseif throttle < 0 then
				joint:SetMotor(-engine.ReverseSpeed / def.Radius, -engine.Torque * throttle)
			else
				joint:SetMotor(0, engine.Braking)
			end
		end

		joint:SetBrake(ROLLING_TORQUE + (def.Brake or 0) * brake + (handbrake and def.Handbrake or 0))
	end
end

local function get_inputs(cmd)
	if not (cmd and usercmd.HasButton(cmd, BUTTON.ACTIVE)) then
		return 0, 0, false
	end

	return cmd.forward, cmd.side, true
end

function META:SteerTowards(target, rate, dt)
	self.steer = self.steer + math.clamp(target - self.steer, -rate * dt, rate * dt)
	return self.steer
end

function META:GetMaxSteer(speed)
	return math.min(
		self.def.Steering.Angle,
		math.atan(STEER_GRIP * GRAVITY * self.wheelbase / math.max(speed * speed, 1e-3))
	)
end

function META:ApplyDrag(body, coefficient)
	local velocity = body:GetVelocity()
	local speed = velocity:GetLength()

	if speed < 0.1 then return end

	body:ApplyForce(velocity * (-coefficient * speed))
end

function META:GetDriveInputs(forward_input, forward_speed)
	if forward_input > 0.01 then
		if forward_speed < -1 then return 0, forward_input end

		return forward_input, 0
	elseif forward_input < -0.01 then
		if forward_speed > 1 then return 0, -forward_input end

		return forward_input, 0
	end

	return 0, 0
end

function controllers.car(self, body, cmd, dt)
	local forward_input, side_input, driven = get_inputs(cmd)
	local speed = body:GetVelocity():Dot(body:GetRotation():GetForward())
	local steer = self:SteerTowards(-side_input * self:GetMaxSteer(speed), self.def.Steering.Rate, dt)
	local throttle, brake = self:GetDriveInputs(forward_input, speed)
	local handbrake = not driven or usercmd.HasButton(cmd, BUTTON.JUMP)
	self:ApplyWheels(steer, throttle, brake, handbrake)
	self:ApplyDrag(body, self.def.Drag)
	self.throttle = throttle
	return forward_input ~= 0 or side_input ~= 0
end

do
	local target_axis = Vec3()

	function controllers.bike(self, body, cmd, dt)
		local active = controllers.car(self, body, cmd, dt)
		local balance = self.def.Balance
		local rotation = body:GetRotation()
		local forward = rotation:GetForward()
		local flat = math.sqrt(forward.x * forward.x + forward.z * forward.z)

		if flat < 1e-3 then return active end

		local speed = body:GetVelocity():Dot(forward)
		-- the lean that balances the turn the bike is making, like a rider would hold it
		local lean = math.clamp(
			-math.atan(speed * body:GetAngularVelocity().y / GRAVITY),
			-balance.MaxLean,
			balance.MaxLean
		)
		local right_x, right_z = -forward.z / flat, forward.x / flat
		local s, c = math.sin(lean), math.cos(lean)
		target_axis:Set(right_x * s, c, right_z * s)
		self.balance.TargetAxis:CopyFrom(target_axis)
		return active
	end
end

do
	local direction = Vec3()

	function controllers.boat(self, body, cmd, dt)
		local forward_input, side_input = get_inputs(cmd)
		local thrust = self.def.Thrust
		local steer = self:SteerTowards(-side_input * thrust.Angle, thrust.Rate, dt)
		local throttle = forward_input < 0 and forward_input * 0.5 or forward_input
		self.throttle = throttle

		if throttle == 0 then return side_input ~= 0 end

		local prop = body:LocalToWorld(thrust.Position)
		local depth = fluid.GetDepth(prop.x, prop.y, prop.z)

		if depth and depth > 0 then
			local rotation = body:GetRotation()
			local forward = rotation:GetForward()
			local speed = body:GetVelocity():Dot(forward)
			local force = thrust.Force * throttle * math.max(1 - speed * math.sign(throttle) / thrust.Speed, 0)
			direction:Set(math.sin(steer), 0, -math.cos(steer))
			direction = rotation:VecMul(direction)
			body:ApplyForce(direction * force, prop)
		end

		return true
	end
end

do
	local STALL = 0.28
	local STALL_BLEND = 0.2
	local MIN_SPEED_SQ = 1

	local function lift_coefficient(alpha, slope)
		local magnitude = math.abs(alpha)

		if magnitude <= STALL then return slope * alpha end

		local blend = math.min((magnitude - STALL) / STALL_BLEND, 1)
		return slope * STALL * math.sign(alpha) * (
				1 - blend
			) + 1.1 * math.sin(2 * alpha) * blend
	end

	local point = Vec3()
	local offset = Vec3()
	local normal = Vec3()
	local chord = Vec3()

	function META:ApplySurface(body, surface, deflection)
		local rotation = body:GetRotation()
		local position = body:GetPosition()
		local velocity = body:GetVelocity()
		local angular = body:GetAngularVelocity()
		Quat.SetVecMul(offset, rotation, surface.Position)
		point:Set(position.x + offset.x, position.y + offset.y, position.z + offset.z)
		Quat.SetVecMul(normal, rotation, surface.Normal)
		Quat.SetVecMul(chord, rotation, FORWARD)
		local vx = velocity.x + angular.y * offset.z - angular.z * offset.y
		local vy = velocity.y + angular.z * offset.x - angular.x * offset.z
		local vz = velocity.z + angular.x * offset.y - angular.y * offset.x
		local along_normal = vx * normal.x + vy * normal.y + vz * normal.z
		local along_chord = vx * chord.x + vy * chord.y + vz * chord.z
		local speed_sq = along_normal * along_normal + along_chord * along_chord

		if speed_sq < MIN_SPEED_SQ then return end

		local speed = math.sqrt(speed_sq)
		local alpha = math.atan2(-along_normal, along_chord) + surface.Incidence + deflection
		alpha = (alpha + math.pi) % (math.pi * 2) - math.pi
		local lift = lift_coefficient(alpha, surface.Slope)
		local drag = 0.03 + (
				math.abs(alpha) <= STALL and
				0.05 * lift * lift or
				0
			) + 1.2 * math.sin(alpha) ^ 2
		local pressure = 0.5 * AIR_DENSITY * speed_sq * surface.Area / speed
		local lift_force = pressure * lift
		local drag_force = -pressure * drag
		-- lift is across the airflow in the plane of the chord and the normal, drag along it
		local fx = (
				normal.x * along_chord - chord.x * along_normal
			) * lift_force + (
				normal.x * along_normal + chord.x * along_chord
			) * drag_force
		local fy = (
				normal.y * along_chord - chord.y * along_normal
			) * lift_force + (
				normal.y * along_normal + chord.y * along_chord
			) * drag_force
		local fz = (
				normal.z * along_chord - chord.z * along_normal
			) * lift_force + (
				normal.z * along_normal + chord.z * along_chord
			) * drag_force
		body:ApplyForceAt(fx, fy, fz, point.x, point.y, point.z)
	end
end

function controllers.plane(self, body, cmd, dt)
	local def = self.def
	local pitch_input, roll_input, driven = get_inputs(cmd)
	local thrust = def.Thrust
	local controls = def.Controls

	if driven then
		local change = (
				usercmd.HasButton(cmd, BUTTON.SPRINT) and
				1 or
				0
			) - (
				usercmd.HasButton(cmd, BUTTON.CROUCH) and
				1 or
				0
			)
		self.throttle = math.clamp(self.throttle + change * thrust.Rate * dt, 0, 1)
	else
		self.throttle = 0
	end

	self.pitch_input = pitch_input
	self.roll_input = roll_input
	local rotation = body:GetRotation()
	local speed = body:GetVelocity():Dot(rotation:GetForward())
	local steer = self:SteerTowards(-roll_input * self:GetMaxSteer(speed), def.Steering.Rate, dt)
	self:ApplyWheels(steer, 0, (not driven or usercmd.HasButton(cmd, BUTTON.JUMP)) and 1 or 0, false)
	local aileron = roll_input * controls.Aileron
	local elevator = pitch_input * controls.Elevator
	local rudder = -roll_input * controls.RudderMix * controls.Rudder

	for _, surface in ipairs(def.Surfaces) do
		self:ApplySurface(
			body,
			surface,
			(
					surface.Aileron or
					0
				) * aileron + (
					surface.Elevator or
					0
				) * elevator + (
					surface.Rudder or
					0
				) * rudder
		)
	end

	if self.throttle > 0 then
		local force = thrust.Force * self.throttle * math.max(1 - speed / thrust.Speed, 0)
		body:ApplyForce(rotation:GetForward() * force, body:LocalToWorld(thrust.Position))
	end

	self:ApplyDrag(body, def.Drag)
	return self.throttle > 0 or pitch_input ~= 0 or roll_input ~= 0
end

function META:OnPhysicsUpdate(dt)
	if not network.HasAuthority() then return end

	local body = self.Owner.rigid_body

	if not self.wheels then self:BuildWheels() end

	local driver = self:GetDriver()
	local movement = driver:IsValid() and driver.character_movement
	local cmd = movement and movement:GetCommand()

	if controllers[self.def.Type](self, body, cmd, dt) and cmd then body:Wake() end

	self:SetSteer(self.steer)
	self:SetThrottle(self.throttle)
	self:SetPitch(self.pitch_input or 0)
	self:SetRoll(self.roll_input or 0)
end

local function set_local(node, position, rotation)
	if position then node.transform:SetPosition(position) end

	node.transform:SetRotation(rotation)
end

do
	local spin_rotation = Quat()
	local root_rotation = Quat()
	local wheel_rotation = Quat()
	local ray_origin = Vec3()
	local DOWN_RAY = Vec3()

	function META:UpdateWheelFromBody(node, wheel, root_inverse)
		local world = wheel.entity.transform:GetWorldMatrix()
		root_inverse:GetRotation(root_rotation)
		world:GetRotation(wheel_rotation)
		set_local(
			node,
			Vec3(root_inverse:TransformVectorUnpacked(world.m30, world.m31, world.m32)),
			Quat.SetMul(Quat(), root_rotation, wheel_rotation)
		)
	end

	function META:UpdateWheelFromRay(node, index, def, dt)
		local suspension = self.def.Suspension
		local transform = self.Owner.transform
		local world = transform:GetWorldMatrix()
		local rotation = transform:GetRotation()
		local up = rotation:VecMul(UP)
		local anchor = Vec3(world:TransformVectorUnpacked(def.Position.x, def.Position.y, def.Position.z))
		ray_origin:Set(
			anchor.x + up.x * suspension.Travel,
			anchor.y + up.y * suspension.Travel,
			anchor.z + up.z * suspension.Travel
		)
		DOWN_RAY:Set(-up.x, -up.y, -up.z)
		local reach = suspension.Travel + def.Radius
		local hit = physics.RayCast(ray_origin, DOWN_RAY, reach, self.Owner)
		local lift = hit and math.clamp(reach - hit.distance, 0, suspension.Travel) or 0
		self.spin[index] = ((self.spin[index] or 0) + self:GetForwardSpeed() / def.Radius * dt) % (math.pi * 2)
		local steer = def.Steer and ackermann(self.Steer, def.Position.x, self.wheelbase) or 0
		spin_rotation:Identity():RotateYaw(steer):RotatePitch(-self.spin[index])
		set_local(
			node,
			Vec3(def.Position.x, def.Position.y + lift, def.Position.z),
			spin_rotation:Copy()
		)
	end
end

function META:UpdateNode(name, rotation, position)
	local node = self.Owner:GetNode(name)

	if node then set_local(node, position, self.bases[name] * rotation) end
end

function META:OnUpdate(dt)
	local def = self.def
	local authority = network.HasAuthority()

	if def.Wheels and (self.wheels or not authority) then
		local root_inverse = authority and self.Owner.transform:GetWorldMatrixInverse()

		for i, wheel in ipairs(def.Wheels) do
			local node = self.Owner:GetNode("wheel" .. i)

			if node then
				if authority then
					self:UpdateWheelFromBody(node, self.wheels[i], root_inverse)
				else
					self:UpdateWheelFromRay(node, i, wheel, dt)
				end
			end
		end
	end

	local steering = def.Steering

	if steering and steering.Node then
		self:UpdateNode(steering.Node, Quat():Identity():RotateYaw(self.Steer * steering.Ratio))
	end

	if def.Type == "plane" then
		self:UpdateNode(
			"yoke",
			Quat():Identity():RotateYaw(-self.Roll * 1.2),
			self.base_positions.yoke + self.bases.yoke:VecMul(Vec3(0, -self.Pitch * 0.08, 0))
		)
		local controls = def.Controls
		self:UpdateNode("elevator", Quat():Identity():RotatePitch(-self.Pitch * controls.Elevator * 2))
		self:UpdateNode(
			"rudder",
			Quat():Identity():RotateYaw(self.Roll * controls.RudderMix * controls.Rudder * 2)
		)
		self:UpdateNode("aileron_l", Quat():Identity():RotatePitch(-self.Roll * controls.Aileron * 2))
		self:UpdateNode("aileron_r", Quat():Identity():RotatePitch(self.Roll * controls.Aileron * 2))
	end

	if def.Thrust and def.Thrust.Node then
		self:UpdateNode(def.Thrust.Node, Quat():Identity():RotateYaw(-self.Steer))
	end

	if def.Propeller then
		self.propeller = (
				self.propeller + (
					0.15 + math.abs(self.Throttle)
				) * def.Propeller.Speed * dt
			) % (
				math.pi * 2
			)
		self:UpdateNode(def.Propeller.Node, Quat():Identity():RotateRoll(self.propeller))
	end
end

return META:Register()
