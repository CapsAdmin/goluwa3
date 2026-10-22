# JRPG mode

A port of the gmod jrpg addon, in `addons/game/lua/jrpg/` plus components in `addons/game/lua/components/`. `!rpg` toggles it on the local player (`!rpg cheat` pins mana and stamina), `!level <attribute>` spends attribute points (no argument lists them), `!status <name> <amount>` applies a status to yourself.

- Being in rpg mode is having the `rpg` component (mana, stamina, xp, level, attributes; stats persist per player in `data/jrpg/`). `jrpg.SetEnabled(entity, on)` adds it, gives the loadout (sword, offhand shield, one `weapon_magic_<type>` per damage type, potions) and puts the old max health, speeds and weapons back when removed. `RPGEnabled`/`RPGDisabled` events turn the battlecam on and off for the local player.
- Everything that is only presentation (jrpg HUD, damage numbers, npc bars, item highlights, damage flashes) checks `actors.IsLocalRPG()`; the plain HUD hides itself while it is on. Gameplay (statuses, projectiles, npc fights) runs regardless.

## Damage

`damage.Deal(victim, info)` -> `ModifyDamage` (jrpg: attack/defense attributes, heal sign, roll dodge, shield block, the type's `OnDamage`) -> `health:TakeDamage` -> `HealthDamaged` (effects, xp bookkeeping, knockback). `info.Type` is a damage type name (`jrpg/damage_types/*.lua`, listed in `damage_types.Names`), `info.Cancel = true` from a listener drops the hit. Damage dealt by a status sets `info.Status` so its type's `OnDamage` does not apply the status again.

- A damage type is a table: `Color`, `EndColor`, `Particles` (gpu emitter properties for bursts and projectiles), `Glow`, `Light`, `Flicker`, `Knockback`, `Heals`, `HitSounds`, `Adjectives`/`Names`, `OnDamage(victim, info)` (authority).
- Status effects (`jrpg/status_effects/*.lua`) live in the `status_effects` component: amounts 0..`Max` decaying by `Decay` per second, `Think` every `Rate` seconds on the authority, `Speed(amount)`, `CanAttack(amount)`, `AnimationSpeed(amount)`, `Particles`, `Fill`, `Orbit`. They replicate as one string (`fire=45 frozen=10`) that clients smooth. Change them only through `status_effects.Set/Add/Remove` on the authority.
- `PlayerMove` listeners may change `move.move`, `move.wish_speed` and `move.jump_pressed`; jrpg uses that for rolls, lunges, frozen, confused, blocking and stamina.
- A weapon or component returning false from `OnCanAttack` on the character blocks attacks (frozen, stunned, rolling, blocking).

## Effects and animation

- `jrpg/effects.lua`: functions called on the authority (`Impact`, `Damage`, `Text`, `Block`, `LevelUp`) broadcast a message on a server or show directly in a standalone game. Visuals exist only when the renderer is up (`effects.Visual`); headless tests get the routing alone.
- Materials are registered for good in the scene material list (`render3d/scene/materials.lua` is append only and DDGI reads every entry), so never create or remove materials per hit: effects pool sprites, trails, quads and overlay materials (`Acquire*` / `Release`).
- Gpu emitters share `MAX_EMITTERS` slots; an emitter that is `Visible` holds its slot even when not `Playing`, so hide emitters that are not needed.
- One-shot character animations are replicated pose actions: `character_pose:PlayAction(name, duration)` on the authority, every process reads `pose.action`/`pose.action_fraction`. `aim_pose.Actions` holds yaw/pitch keyframes added to the aim (swings, casts, drink), `roll_*` actions rotate the rendered body (`jrpg/animation.lua` through `transform` overrides), creatures play `source_pose.AttackSequence` during `attack`. These are placeholders meant to be replaced by real animations.
- Npcs fight with a gun (`weapon_holder`), in melee (`ai_controller.MeleeDamage`) or with magic (`MagicElement`).

## Testing

`luajit glw test entities/jrpg.lua`. In-game harnesses need gm_construct for the source models: load it with `engines.Load("gm_construct")`, wait for `static_world.GetActive()`, then `commands.RunLine("rpg")`. Simulate keys with `input.CallOnTable(input, "Key", key, press)` plus `event.Call("KeyInput", key, press)` and `player_input:SetKeyboardMovement(true)`.
