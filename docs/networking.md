# Networking

Server authoritative, Source/GMod style. Server: `luajit glw --server` (physics on, `host` runs automatically; `GOLUWA_PORT` overrides the port). Client: `luajit glw --3d` then `connect 127.0.0.1`, or headless `luajit glw --cli --physics`. Tests: `luajit glw test network/` (includes two-process e2e tests using `test/network_e2e/`).

- Transport: `goluwa/network/connection.lua` (handshake, reliable ordered channels, fragmentation, sequenced/unreliable, pings, timeouts) over `transport_layer.lua` (UDP). `GOLUWA_NET_LATENCY`, `GOLUWA_NET_JITTER` (ms) and `GOLUWA_NET_LOSS` (%) simulate bad connections.
- Replication: give an entity the `network` component (`shapes.Box{Network = true}` or `Entity.New{network = {}}`). Each component declares what replicates in `META.Network = {Key = {type, rate, flags, interp}}`. The spawn packet carries the component list and values and the client builds the entity through `Entity.New`. Models replicate as paths the client already knows. Non-owned bodies are kinematic on clients.
- Players: input is a `usercmd` (`network/usercmd.lua`) produced once per physics tick by `player_controller` (from `player_input` locally, the network on the server, or a `CreateMove` hook for bots). `player_movement` only consumes the command, so the same code predicts on the client and simulates on the server. The client reconciles against `player_ack`; the server relays commands to other players; the physgun runs on the server from the command buttons.
- The NETWORK tab of PERF (`perf network`, `net_stats`) shows stats.
- Sessions: client-pushed scene entities and prefabs live in server memory for the session only (like pac3). Do not add server-side saving to `scene_sync` handlers; per-player content (outfit) is a local file sent on connect.

# Players

A player is one entity with `transform`, `rigid_body`, `player_controller`, `player_movement`, `weapon_holder`, `player_avatar` and, for the local one, `camera` and `player_input`. The player entity is deliberately not a prefab: remote clients only get `transform`, `rigid_body`, `network` and `player_avatar` from the spawn packet.

- Rotation is the view yaw (`player_movement:SetBodyYaw` every tick from the command, so server and prediction agree; pitch is only in the head). Origin is the feet in both modes. `rigid_body.CenterOffset` is the body center relative to the entity origin: everything physics does (solver, sweeps, prediction, `processed.position` of acks) stays in center space. Place players by eye with `player_movement:SetEyePosition`, and by feet with `spawn:GetPlacement(0)`.
- `armature` (client side) holds a rig made from a registered skeleton (`Armature.RegisterSkeleton`); whatever animates it calls `SetBone(name, matrix, "local"|"model")`. `transform.Attachment` attaches a transform to a bone of the nearest ancestor armature (`world = local * bone * parent_world`); an attached transform is always dynamic.
- The look of a player is its outfit (`addons/game/lua/outfit.lua`, a prefab; default has a crouch-squashed body and a visor on the `head` bone). `player_avatar` builds the armature on clients, adds the outfit as a child and animates bones each frame. The outfit is hidden in first person via `outfit.visibility:AddHider("first_person")`. Weapons are built-in data-only prefabs (`addons/game/lua/weapons.lua`, definitions in `weapons/*.lua`: model nodes plus a `script` component whose source holds the behaviour and `OnWeapon*` hooks); `weapon_holder:Give(name)` instantiates one. `player_outfit_source` (`outfit_source.lua`, pvar `cl_outfit`) uses a gmod player model driven by a script from `transform:GetRenderVelocity()` (smoothed world-position velocity; `rigid_body` velocity is only real on the predicting client and is not replicated). Scripts in a pushed outfit are dropped by a server without `sv_client_scripts`.
- The editor window owns an editor camera `View` above the player's; Ctrl+E (`editor_window:SetPlaying`) hands input back to the player while the editor camera stays.
- Do not use `ffi.copy` (`Vec3:CopyFrom`) into a vector that is read in the same trace (miscompile, see `RigidBody:SynchronizeFromTransform`).

# Visibility

The `visibility` component (`goluwa/entities/components/visibility.lua`) works like hiding a part in pac3: an entity is hidden when it or any ancestor is, and descendants keep their own state. `Visible` is the stored flag, `AddHider(name)`/`RemoveHider(name)` are stacking named reasons (first person, editor, script). Every entity has `entity.visibility_hidden` kept current (`Visibility.Refresh`) and receives `OnHide`/`OnShow` local events (not while being built: use `OnEntityConstructed`). `visual` follows them; `light` and `water_volume` keep their own `Visible`. Tests: `luajit glw test entities/visibility.lua`.

# Ownership and permissions

Every entity has an owner, `entity:GetOwnedBy()`: a client or a world (`Entity.World`, `Panel.World`). It is not `component.Owner` (the entity a component sits on). An entity without an explicit owner inherits its parent's, so code creating entities needs no ownership code; only player content sets one (`SetOwnedBy`). The server sets a pushed entity's owner from the sender, never from the payload.

- `Transient` means derived/runtime, never saved or synced. `entity:IsRuntime()` is transient and world-owned. `scene.Serialize` leaves out what other clients own; a joiner snapshot includes everything. Do not revert `Transient` to ownership-only.
- `goluwa/entities/permissions.lua`: `permissions.Can(client, "create"|"modify"|"remove", entity)` and `CanPushPrefab(client, name)`, asked by `scene_sync` handlers. An `EntityPermission` event listener answers first. Pvar `sv_entity_permissions` is `all` (default) or `owner`.
- The entity tree groups children of a root under their owner when `GroupByOwner` is set (the editor does).
- Tests: `luajit glw test entities/ownership.lua entities/permissions.lua panel/entity_tree_owner.lua`.
