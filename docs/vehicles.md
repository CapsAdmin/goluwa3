# Vehicles and seats

Vehicles live in the sandbox addon: definitions and prefabs in `addons/sandbox/lua/vehicles.lua` (`car`, `motorbike`, `boat`, `plane`, the Vehicles tab of the spawn menu, `spawn_requests` kind `vehicle`), the behaviour in the `vehicle` component (`lua/components/vehicle.lua`). Seating is generic and lives in the game addon: the `seat` component, the `seat` animation state and the seat camera. Tests: `luajit glw test addons/sandbox/tests/entities/vehicles.lua`, `luajit glw test physics/wheel.lua`.

## Physics, no hacks

Vehicles are simulated with ordinary bodies and joints; nothing holds them level or on the road except physics.

- The prefab root is the chassis: one dynamic body whose origin is its centre of mass (colliders are placed around it, so a low origin gives a low centre of mass).
- Every wheel is its own sphere body joined with `constraints.Wheel` (`goluwa/physics/constraints/wheel.lua`): a sprung slider along the suspension axis, an axle steered by `SetSteerAngle`, and `SetMotor`/`SetBrake` on the spin. Steering turns the real wheel bodies.
- Wheel bodies set `SpinAxis` (their local axle) so the integrator spins them exactly about it, see [physics.md](physics.md).
- Wheels are authority only and not networked; `TraceOwner` and `ResolveUseTarget` map them to the vehicle. Clients see a kinematic chassis and place visual wheels from a ray per wheel and the replicated `Steer`.
- The motorbike stays up with `constraints.KeepUpright` in roll mode, targeting the lean that balances its turn (`atan(v * yaw_rate / g)`).
- The boat floats on the buoyancy of its hull colliders, `FluidDrag` (per body axis) gives it keel behaviour, and its propeller pushes only while `fluid.GetDepth` says it is under water.
- The plane gets lift and drag per aerodynamic surface from the local airflow and angle of attack; stability comes from its geometry (tail behind the centre of mass).
- Rollover is physical: a car rolls when lateral acceleration exceeds `track / (2 * centre of mass height)` g, so keep the centre of mass low and limit steering by speed (`GetMaxSteer`).

## Seats

- A `seat` component on an entity (`Pose` = `drive`/`ride`/`pilot`, a pelvis `Position`, exit and camera settings, and prefab node names for hand and foot targets). `OnUsed` enters on the authority; use again leaves.
- The seat is the replicated `character_pose.Seat`. `character_movement` makes the capsule kinematic and collisionless, places it on the seat every tick, skips movement and reconcile, and on leaving puts the character at `seat:FindExit`. Weapons are neither thought, posed nor shown while seated (`weapon_holder:IsSeated`).
- The `seat` state draws the character at the seat's render transform (so it never lags the interpolated vehicle). `source_pose` plays the pose's Source sequence and solves legs and arms to the seat's foot and grip nodes (`leg_pose.SolveFoot`, `aim_pose.SolveGrip`); grip nodes parented to a turning part (steering wheel, handlebar) carry the hands.
- The seat camera (`lua/seat_camera.lua`) chases the seat; the mouse wheel zooms into first person, where the look is relative to the vehicle.
