# Networking

Server authoritative, Source/GMod style. Server: `luajit glw --server` (physics on, `host` runs automatically; `GOLUWA_PORT` overrides the port). Client: `luajit glw --3d` then `connect 127.0.0.1`, or headless `luajit glw --cli --physics`. Tests: `luajit glw test network/` (includes two-process e2e tests using `test/network_e2e/`).

- `--server-client` (with `--3d`): the client runs the server in a second lua state of the same process (`goluwa/network/server_process.lua`, listens on 127.0.0.1) and connects once it is ready. The command after the flags (`map gm_construct`) runs on the server, not the client, and chat `!commands` run on the server too. The worker state has `_WORKER_THREAD`; `os.exit` there ends the whole process.
- Transport: `goluwa/network/connection.lua` (handshake, reliable ordered channels, fragmentation, sequenced/unreliable, pings, timeouts) over `transport_layer.lua` (UDP), with the reliable sender state (round trip estimate, retransmit, congestion window) in `reliable_send.lua`. `GOLUWA_NET_LATENCY`, `GOLUWA_NET_JITTER` (ms) and `GOLUWA_NET_LOSS` (%) simulate bad connections.
  - Sends and acks are batched into the current datagram, which goes out when full, at the end of `transport_layer.Update` and in `transport_layer.Flush`. Code that pumps a connection by hand must call `Update` or `Flush` for anything to leave.
  - The receiver only acks reliable records it keeps, and the sender never runs further ahead than the receive window, so a lost record cannot be skipped.
  - Between frames the limiter sleeps through the `FrameSleep` event, which the transport answers by polling its sockets so acks go out immediately; game callbacks still only run in `Update`.
- Replication: give an entity the `network` component (`shapes.Box{Network = true}` or `Entity.New{network = {}}`). Each component declares what replicates in `META.Network = {Key = {type, rate, flags, interp}}`. Clients interpolate `interp` vars a fixed delay behind their estimate of the server clock. A component only joins the spawn packet if it has a `Network` table, so a component that must exist on clients but replicates nothing declares `META.Network = {}`. The client builds spawned entities through `Entity.New`. Models replicate as paths the client already knows. Non-owned bodies are kinematic on clients.
- Players: input is a `usercmd` (`network/usercmd.lua`) produced once per physics tick by `player_controller` (from `player_input` locally, the network on the server, or a `CreateMove` hook for bots). `character_movement` only consumes the command, so the same code predicts on the client and simulates on the server. The server consumes commands from a jitter buffer; the client reconciles against `player_ack`.
- Debugging: `net_prediction_debug` (addons/debug) toggles an overlay comparing the owner's predicted state with the server's at the last acked command, the colliders of nearby networked bodies on both sides (`prediction_debug_server.lua`) and the last physgun/toolgun traces (`addons/game/lua/trace_debug.lua`). Identical client and server shapes that still look wrong mean the model's physics data is wrong. The NETWORK tab of PERF (`perf network`, `net_stats`) shows stats.
- Sandbox: spawning goes through the server (`addons/sandbox/lua/spawn_requests.lua`), which validates the request and owns the result to the sender; with no server it spawns locally. Undo is per client on the server (`addons/sandbox/lua/game_history.lua`).
- Sessions: client-pushed scene entities and prefabs live in server memory for the session only (like pac3). Do not add server-side saving to `scene_sync` handlers; per-player content (outfit) is a local file sent on connect.

# Players

Find players with `players` (`goluwa/network/players.lua`), never a global: `players.Get(client)`, `players.GetLocal()` (this process's own rig, nil on a dedicated server), `players.IsLocal(entity)` and `players.GetClient(entity)`. Code that runs on the server must go through the entity or the client, not `GetLocal`.

A player is one entity with `transform`, `rigid_body`, `player_controller`, `character_movement`, `character_pose`, `weapon_holder`, `player_avatar` and related components, plus `camera` and `player_input` for the local one. It is deliberately not a prefab: remote clients only get the replicated components from the spawn packet. Network setup lives in `addons/game/lua/autorun/network_players.lua` and `addons/game/lua/spawning.lua`.

- The owner's rig is the same entity as the server's player: `player_start` carries the server player's network id and the client links its predicted rig to it (`NetworkComponent.Link`). The owner never receives the player root itself (it is predicted) but receives everything the server makes under it. Entities whose `network` has `SendToOwner` (weapons) replicate to their owner too. A client must not create networked children itself while linked.
- Vars with `to_owner = true` in their `Network` info (health, status effects, server-only pose state) are sent to the owner even on the root; everything else on the root is owner-authored or predicted. A component with `NetworkOwnerExcluded` is left out for its owner so predicted state is not overwritten.
- Effects are predicted by the owner and sent by the server to everyone else. A weapon implements `OnWeaponPredictThink/Primary/Secondary` (effects only, never state), and the server's effect events skip the owner.
- To see exactly what other players get, start with `GOLUWA_PVARS="net_prediction=false"` on both sides (`--server-client` shares the environment): the owner stops predicting movement and weapons and is replicated like anyone else.
- Rotation is the view yaw (pitch is only in the head). Origin is the feet. `rigid_body.CenterOffset` is the body center relative to the entity origin: everything physics does stays in center space. Place players by eye with `character_movement:SetEyePosition`.
- The look of a player is its outfit (`addons/game/lua/outfit.lua`, a prefab named by pvar `cl_outfit`), added by `player_avatar` on clients; see [characters.md](characters.md) and [prefabs-and-scripts.md](prefabs-and-scripts.md). Weapons are data-only prefabs, see [weapons.md](weapons.md).
- Do not use `ffi.copy` (`Vec3:CopyFrom`) into a vector that is read in the same trace (LuaJIT miscompile, see `RigidBody:SynchronizeFromTransform`).

# Visibility

The `visibility` component (`goluwa/entities/components/visibility.lua`) works like hiding a part in pac3: an entity is hidden when it or any ancestor is, and descendants keep their own state. `Visible` is the stored flag, `AddHider(name)`/`RemoveHider(name)` are stacking named reasons. Every entity has `entity.visibility_hidden` kept current and receives `OnHide`/`OnShow` local events (not while being built: use `OnEntityConstructed`). Tests: `luajit glw test entities/visibility.lua`.

# Ownership and permissions

Every entity has an owner, `entity:GetOwnedBy()`: a client or a world (`Entity.World`, `Panel.World`). It is not `component.Owner` (the entity a component sits on). An entity without an explicit owner inherits its parent's, so only player content sets one (`SetOwnedBy`). The server sets a pushed entity's owner from the sender, never from the payload.

- `Transient` means derived/runtime, never saved or synced; it is independent of ownership. `scene.Serialize` leaves out what other clients own; a joiner snapshot includes everything.
- `goluwa/entities/permissions.lua`: `permissions.Can(client, "create"|"modify"|"remove", entity)` and `CanPushPrefab(client, name)`, asked by `scene_sync` handlers. An `EntityPermission` event listener answers first. Pvar `sv_entity_permissions` is `all` or `owner`.
- Tests: `luajit glw test entities/ownership.lua entities/permissions.lua panel/entity_tree_owner.lua`.
