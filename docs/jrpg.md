# JRPG mode

A port of the gmod jrpg addon, in the `jrpg` addon (`addons/jrpg/lua/jrpg/` plus its components in `addons/jrpg/lua/components/`), which depends on `game`. `!rpg` toggles it on the local player (`!rpg cheat` pins mana and stamina), `!level <attribute>` spends attribute points (no argument lists them), `!status <name> <amount>` applies a status to yourself.

- Being in rpg mode is having the `rpg` component (mana, stamina, xp, level, attributes; stats persist per player in `data/jrpg/`). `jrpg.SetEnabled(entity, on)` adds it, gives the loadout (sword, offhand shield, one `weapon_magic_<type>` per damage type, potions) and puts the old max health, speeds and weapons back when removed. `RPGEnabled`/`RPGDisabled` events turn the battlecam on and off for the local player.
- Everything that is only presentation (jrpg HUD, damage numbers, npc bars, item highlights, damage flashes) checks `actors.IsLocalRPG()`; the plain HUD hides itself while it is on. Gameplay (statuses, projectiles, npc fights) runs regardless.

## Damage

`damage.Deal(victim, info)` -> `ModifyDamage` (jrpg: attack/defense attributes, heal sign, roll dodge, shield block, the type's `OnDamage`) -> `health:TakeDamage` -> `HealthDamaged` (effects, xp bookkeeping, knockback). `info.Type` is a damage type name (`jrpg/damage_types/*.lua`, listed in `damage_types.Names`), `info.Cancel = true` from a listener drops the hit. Damage dealt by a status sets `info.Status` so its type's `OnDamage` does not apply the status again.

- A damage type is a table: `Color`, `EndColor`, `Particles` (gpu emitter properties for bursts and projectiles), `Glow`, `Light`, `Flicker`, `Knockback`, `Heals`, `HitSounds`, `Adjectives`/`Names`, `Surface` (`{Kind, Radius, Amount}`, a surface effect applied where it hits, see [surface-effects.md](surface-effects.md)), `OnDamage(victim, info)` (authority).
- Status effects (`jrpg/status_effects/*.lua`) live in the `status_effects` component: amounts 0..`Max` decaying by `Decay` per second, `Think` every `Rate` seconds on the authority, `Speed(amount)`, `CanAttack(amount)`, `AnimationSpeed(amount)`, `Particles`, `Fill`, `Orbit`. They replicate as one string (`fire=45 frozen=10`) that clients smooth. Change them only through `status_effects.Set/Add/Remove` on the authority.
- `PlayerMove` listeners may change `move.move`, `move.wish_speed` and `move.jump_pressed`; jrpg uses that for lunges, frozen, confused, blocking and stamina.
- A weapon or component returning false from `OnCanAttack` on the character blocks attacks (frozen, stunned, rolling, blocking).

## Effects and animation

- `jrpg/effects.lua`: functions called on the authority (`Impact`, `Damage`, `Text`, `Block`, `LevelUp`) are `replicated_event`s (`goluwa/network/replicated_event.lua`): broadcast on a server, run directly in a standalone game. Visuals exist only when the renderer is up (`effects.Visual`); headless tests get the routing alone. The look is compositions of the engine layer in [vfx.md](vfx.md) (`effects.vfx` is the module, only set when visual); weapons guard their visual calls with `effects.Visual`.
- Additive glows go through sprite batches, so a pixel's brightness is tint x texture and alpha is passed squared where the old per object materials squared it (`b.flare:Add(..., alpha * alpha)`). The refractive lens is the exception: its batch is keyed by colour and cannot fade, so its radius scales with alpha.
- Materials are registered for good in the scene material list (`render3d/scene/materials.lua` is append only and DDGI reads every entry), so never create or remove materials per hit: effects share tinted materials and pool the rest. A gpu emitter that is `Visible` holds one of `MAX_EMITTERS` slots even when not `Playing`, so hide emitters that are not needed.
- Status particles are one gpu emitter per (entity, status) under a small budget; overlays (rim/fill tint) cache the entity's visuals and only rebuild when its children list changes.
- One-shot character animations are replicated pose actions (`character_pose:PlayAction(name, duration)` on the authority, definitions in `lua/animations/actions.lua` with yaw/pitch `AimKeys` for swings, casts, drink); the base `character_movement` roll (hold crouch while moving on the ground; the `roll` state replicates its kind) rotates the rendered body and the view (`character_pose`), creatures play `source_pose.AttackSequence` during `attack`. These are placeholders meant to be replaced by real animations.
- Npcs fight with a gun (`weapon_holder`), in melee (`ai_controller.MeleeDamage`) or with magic (`MagicElement`).

## Testing

`luajit glw test entities/jrpg.lua`. In-game harnesses need gm_construct for the source models: load it with `engines.Load("gm_construct")`, wait for `static_world.GetActive()`, then `commands.RunLine("rpg")`. Simulate keys with `input.CallOnTable(input, "Key", key, press)` plus `event.Call("KeyInput", key, press)` and `player_input:SetKeyboardMovement(true)`.

- Weapon categories (label, color) are registered in `lua/weapon_categories.lua` (`Register`, `Get`); a weapon only names its `Category`, and an unregistered name falls back to `unknown`. The game addon registers its own, jrpg adds `melee`, `magic` and `defense` from an autorun. The weapon ring colors its wedges from there and separates categories with a glow line.
