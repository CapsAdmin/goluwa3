# Navigation and NPCs

Source `.nav` meshes, pathfinding over them, and NPC prefabs that walk a map with the animations of their Source model.

## Pieces

- `goluwa/codecs/nav.lua`: Source `.nav` decoder/encoder (versions 5-16). `nav.Decode(str)` returns plain tables in Source units and axes (north is -y, east +x). Visibility lists, encounter paths and approach areas are skipped; `nav.Encode` writes the current version without them (tests use it).
- `goluwa/navigation/navmesh.lua`: generic mesh of convex areas seen from above (engine space, y up) with one-way links: `AddArea`, `Connect(from, to, a, b)` (a, b are the ends of the shared edge), `Build`, `GetAreaAt`, `GetNearestArea`, `GetHeight`, `GetRandomPoint`, `GetReachableAreas`, `FindPath`.
- `goluwa/source_engine/nav_mesh.lua`: `FromData`/`Load` turn Source areas into a navmesh (`CROUCH`/`JUMP` areas blocked, `AVOID` costs more; areas under more than 0.6 m of water are blocked by `BlockFlooded`, rerun when the water volume count changes).
- `goluwa/entities/components/nav_mesh.lua`: the world's mesh (`Path`, `nav_mesh.GetMesh()`, `SetMesh`). `map_scene.Translate` puts it on the map root when `maps/<name>.nav` exists. `nav_show` draws areas near the camera.
- `addons/game/lua/components/ai_controller.lua` (the npc brain: a command source for `character_movement`, like `player_controller`), `locomotion.lua` (animation from movement), `addons/game/lua/npcs.lua` (prefabs: `npcs.Definitions`, `Register`, `Spawn(name, position, yaw)`, `SpawnOnMesh`). Example: `addons/examples/lua/examples/render3d/npc_walkers.lua`.
- Tests: `luajit glw test navigation/navmesh.lua`, `source_engine/nav.lua`, `entities/npc.lua` (one file per call).

## Pathfinding

- `FindPath(from, to, options)` options: `Radius` (insets portal ends), `MaxClimb`/`MaxDrop` (meters per connection), `Blocked` (table keyed by areas/links), `SnapDistance`. Returns nil plus a reason, or `{points, areas, links, length}`.
- A* over areas (connection cost = distance between portal midpoints times area `Cost`), then funnel through the portals. Left/right of a portal use a frame with x right and z up; getting that wrong sends paths through the far end of every portal.
- Real nav files have islands and connections needing jumps: pick destinations from `GetReachableAreas` (flood fill with the same limits), not from the whole mesh.

## NPCs

An npc prefab is a model, `animator`, `locomotion` and `ai_controller` on the root: `Entity.New{prefab = {Path = "npc_zombie"}}` or `npcs.Spawn`. Inputs: `Wander`, `WanderRadius`, `Running`, `WalkSpeed`, `RunSpeed`. Console `npc_spawn <name>[,count]`. A definition is the model, idle/walk/run sequence names and walk/run speed in Source units per second (what `GetGroundSpeed` reports; `entities/npc.lua` checks them within 3%).

- `ai_controller` has no physics of its own: it adds a `character_movement` in `walk` mode and is its controller (controllers register with `character_movement.RegisterController`; read the current command with `character_movement:GetCommand()`) (`NextCommand(dt)` returns a `usercmd` once per physics tick), only where `network.HasAuthority()`; elsewhere the transform replicates.
- API: `MoveTo(position, running)`, `Stop()`, `Teleport(position, yaw)` (use it to place one: setting the transform does not move a dynamic body), `GetGoal/GetPath/IsMoving`; events `OnNPCArrived`, `OnNPCPathFailed`. Stuck detection blocks the current connection/area for a while and repaths; repeated failures give up. An npc off the mesh is put back on the closest point.
- `character_movement` friction removes `StopSpeed * Friction * dt` per tick, so slow characters never get going unless `StopSpeed` is lowered (the npc sets it to half its walk speed).
- Simulation LOD: a dynamic capsule on a brush world is expensive, so only the nearest `simulation_lod.MaxSimulated` (`addons/game/lua/simulation_lod.lua`) npcs within `PhysicsDistance` of a camera or player keep a body; the rest are in `fly` mode (collision off, `MoveBodyBy` over the mesh height) and cost almost nothing. With no camera or player everything is simulated.
- Combat: an npc whose definition has a `Weapon` gets a `weapon_holder` (`HoldOffset` places the held model, npcs have no armature hand) and is given the weapon on spawn. `ai_controller` rescans every 0.25 s for the nearest living `player_controller` entity within `AttackRange` with a clear sweep from its eye, stops pathing, turns at `TurnSpeed` and pulses `ATTACK1` every `FireInterval` (randomized) once aligned, with `AimError` radians of jitter on the shot. There are no factions: only players are targeted. Far (not simulated) npcs never fight. Tests: `entities/npc_combat.lua`.
- `locomotion` reads `transform:GetRenderVelocity()` (works for replicated npcs): idle/walk/run thresholds, `animator:SetSpeed(speed / ground speed)` so feet do not slide, `move_yaw` is the velocity angle against the facing.

## Pitfalls

- `Entity.New{...}` initializes every component a second time at the end of construct, including ones a prefab added. Components that create things in `Initialize` and can sit on a prefab root (`visual`, `ai_controller`, `locomotion`) must skip the second Initialize, or they discard e.g. a model load already started.
- `Entity.New{prefab = ..., transform = {Position = p}}` builds the prefab before the position applies and dynamic bodies do not follow transforms: `npcs.Spawn` calls `Teleport`.

Not done: ladders and jump connections, crouch areas, doors/dynamic obstacles, attack/turn animations, an activity table, meshes generated from world geometry.
