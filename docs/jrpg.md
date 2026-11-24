# JRPG mode

A port of the gmod jrpg addon in the `jrpg` addon (`addons/jrpg/lua/jrpg/`, components in `addons/jrpg/lua/components/`), which depends on `game`. Console: `!rpg` toggles it on the local player (`!rpg cheat` pins mana and stamina), `!level <attribute>` spends attribute points, `!status <name> <amount>` applies a status to yourself.

- Being in rpg mode is having the `rpg` component (mana, stamina, xp, level, attributes; stats persist per player in `data/jrpg/`). `jrpg.SetEnabled(entity, on)` adds it with the loadout and restores the old health, speeds and weapons when removed. `RPGEnabled`/`RPGDisabled` events drive the battle camera.
- Presentation (jrpg HUD, damage numbers, npc bars, item highlights, damage flashes) only shows for the local player in rpg mode (`jrpg.IsLocalEnabled()`). Gameplay (statuses, projectiles, npc fights) runs regardless.

## Damage

`damage.Deal(victim, info)` (`addons/game/lua/damage.lua`) -> `ModifyDamage` listeners (jrpg: attributes, heals, dodge, guard, the damage type's and every attribute's `OnDamage`) -> `health:TakeDamage` -> `HealthDamaged` (effects, xp, knockback). A listener sets `info.Cancel = true` to drop a hit. God mode (`damage.IsGod`) drops positive damage but not heals.

- `info.Type` is the base type (`generic`, `slash`, `magic`) and `info.Attributes` a list of elements (`damage_types.Names`: fire, poison, ice, heal, ...). Elements are what a hit carries, never what it is: a poison sword deals `slash` with `{"poison"}`, a fire spell `magic` with `{"fire"}`. Never mutate the default attribute list. Only `magic` is magic for defense rules, so an attributed sword hit stays physical.
- Damage types (`lua/jrpg/damage_types/*.lua`) and status effects (`lua/jrpg/status_effects/*.lua`) are pure data files, see [data-driven-effects.md](data-driven-effects.md). Damage a status deals itself sets `info.Status` so it does not re-apply the status; weapon statuses likewise set `info.WeaponStatus`.
- Statuses live in the `status_effects` component: amounts that decay, a periodic `Think` on the authority, speed/attack/animation modifiers, particles and a surface overlay kind. They replicate as one string that clients smooth. Change them only through `status_effects.Set/Add/Remove` on the authority.
- `PlayerMove` listeners may change the move (lunges, frozen, blocking, stamina). A weapon or component returning false from `OnCanAttack` blocks attacks.
- Sword hits go through `slash.Strike` (`lua/jrpg/slash.lua`): each hit of a move has a cut direction, the cut plane gives the hit position and normal on the victim, and an optional target (aim ray or part name) only refines which part is hit, it never turns a hit into a miss. `weapon_debug` (`lua/weapons/debug.lua`) swings at exact angles, picks damage and type, and draws the cut, for testing hit reactions.

## Effects

- `lua/jrpg/effects.lua`: authority side calls (`Impact`, `Damage`, `Text`, `Block`, `LevelUp`, `Stagger`, `HitOverlay`) are `replicated_event`s (`goluwa/network/replicated_event.lua`): broadcast on a server, run directly in a standalone game. Visuals exist only when the renderer is up (`effects.Visual`); headless tests get the routing alone. The look is built from the engine layer in [vfx.md](vfx.md) (clips, sprite batches, gpu emitters, surface overlays).
- Additive glows go through shared sprite batches with per sprite vertex tint, so brightness is tint times texture.
- Materials are registered for good in the scene material list (append only, DDGI reads every entry), so never create or remove materials per hit: share tinted materials and pool the rest. A visible gpu emitter holds one of the limited emitter slots even when not playing, so hide emitters that are not needed.
- Status looks and hit flashes are surface overlay layers on every visual of the entity (`lua/surface_overlays/status_*.lua`, see [surface-overlays.md](surface-overlays.md)); the dropped weapon highlight (`components/item_highlight.lua`) is the `item_highlight` overlay kind plus ribbons and sprites. `lua/examples/overlays_showcase.lua` shows every kind.
- One-shot character animations are replicated pose actions (`character_pose:PlayAction(name, duration)`, see [characters.md](characters.md)). Npcs fight with guns or with moves, see [navigation-and-npcs.md](navigation-and-npcs.md).

## Melee and movesets

Every melee weapon (`sword`, `greatsword`, `rapier`, `reaper`, `shovel`) runs one script, `lua/weapons/melee.lua` (`weapon_melee`), parameterized by script values (`Moveset`, `Damage`, `Range`, ...); the weapon files only describe the model. A moveset (`lua/jrpg/movesets/<name>.lua`, registry in `addons/game/lua/movesets.lua`) is plain data: no `Vec3`, no code, so tools can write it back with `table.to_source`. `movesets.Register` validates it (`movesets.Validate` names each error by path). Npc movesets are `addons/game/lua/npc_movesets/<npc>.lua`.

- Slots: `Combo` (light chain), `Heavy`, `Air`, `Dash`, context slots (`movesets.Slots`, picked by `weapon_melee:PickMove`: crouch, plunge, air heavy, evade, vault), `Guard` (a blocking pose), `Special` (a cinematic move on reload) and `Moves`.
- A move is one timeline on a 0..1 clock (fractions of `Duration`). `Keys` are keyframes for motion and attachment tracks (`addons/game/lua/keyframes.lua`); `motion` orbits and drives the attacker around an anchor fixed when the move starts, through `character_movement:Drive`. `Overlays` are pose blocks on the aim, hand, torso, head and pelvis tracks (static `Poses` or animated `Gestures`, crossfading where they overlap), compiled by `keyframes.CompileOverlays` into plain key rows. `Clips` are model sequence segments, the base layer for creatures. `Locks` pin the victim (`character_movement:Pin`) over phase ranges. `Events` (`hit`, `latch`, `release`, and `strike`/`cast` for creatures) run on the authority only. `Shots` and `Faces` are presentation, read on every client from the replicated pose action phase.
- Events and keys can be linked to a clip or pose block (`movesets.ResolveClipLinks`) so they stay on the same frame of the animation when the block is moved or trimmed.
- Put a `hit` at the time of the move's contact pose key: hitstop freezes the attacker where the hit lands, so an early hit freezes the blade short of the target.
- Guards: holding back and secondary raises a blade guard; the shield blocks with the left hand. Both hand `rpg:SetGuard{...}` a table that `ModifyDamage` reads. A hit shortly after raising a blade guard is a parry.
- Each move is registered as the pose action `<moveset>_<move>`; `movesets.GetMove(action)` maps it back.

## Editors

Desktop programs, all editing the plain data and applying it live through the registry's `Update`, with undo/redo snapshots (`addons/game/lua/data_history.lua`) and `FILE > save` writing the file back with `table.to_source`.

- `Move editor` (`lua/jrpg/move_editor.lua`, logic without ui in `lua/jrpg/move_edit.lua`): a timeline of a move's keys, pose blocks, clips, locks, events, shots and faces, previewed on a stage of puppeted characters (`move_stage.lua`, `move_preview.lua`) in front of the player, with ghosts (`move_ghost.lua`). A failing validation is shown in the status line and leaves the registered moveset as it was. Keep keys by identity, never by row index, across a change, since undo replaces the data.
- `Pose editor` (`lua/jrpg/pose_editor.lua`): edits the static poses gestures and blocks name, on a stage character, with a gizmo handle for the hand.
- `Effects editor`: see [data-driven-effects.md](data-driven-effects.md).

## Stagger, knockdown and hitstop

`lua/jrpg/stagger.lua` grades each hit by the share of the health the victim had before it, so the same blow reacts harder as the victim weakens: a small hit flinches, a larger one staggers (hitstop freeze on both, then a directional stagger action and lunge on the victim), a large one on a victim with a `ragdoll` knocks it down (`ragdoll:Knockdown`). A killing melee hit also throws the corpse. A victim held by a grab only gets hitstop.

- Hitstop is a render hold (`character_pose:Freeze`): the transform and rigs keep returning their frozen state (`transform:SetFrozen`, `Rig:SetHeld`) while movement and physics run underneath, and the drawing snaps to the current state on release.
- Stagger and hit reactions follow `info.Direction` and the hit `info.Part`.
- To test reactions: `weapon_debug`, the npc spawn options (`npcs.Spawn` `Reaction`, `Health`, `God`: `character_pose.ForcedReaction`, `health.Unkillable`), and the `breen` dummy which revives after dying (`RefillDelay`).

## Weapon rarity and statuses

`lua/jrpg/weapon_stats.lua` (from the gmod jrpg `wepstats`): rarities with a damage multiplier, color and status count, and a registry of weapon statuses (every element plus a few special ones) with `OnDamage`/`OnReceiveDamage` hooks called from `ModifyDamage`. `weapon_stats.Roll(weapon, rarity, bonus, names)` rolls rarity, bonus and statuses and builds the title. Weapon categories (label, color) are registered in `addons/game/lua/weapon_categories.lua`.

## Testing

`luajit glw test entities/jrpg.lua`; the jrpg tests are in `addons/jrpg/tests/` (`entities/melee.lua`, `move_edit.lua`, `clip_edit.lua`, `render3d/blade_trail.lua`, ...). In-game harnesses need gm_construct for the source models: `loaders.Load("gm_construct")`, wait for `static_world.GetActive()`, then `commands.RunLine("rpg")`. Simulate keys with `input.CallOnTable(input, "Key", key, press)` plus `event.Call("KeyInput", key, press)` and `player_input:SetKeyboardMovement(true)`.
