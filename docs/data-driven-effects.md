# Data driven effects

An effect is a plain Lua table in a file that `return`s it: numbers, strings, booleans, lists and tables, never functions or cdata, so `table.to_source` can write it back and an editor can edit it. Behaviour an editor cannot express is a named script in code that the data refers to. Add a new look as a file, not as a table inside the code that uses it.

- Colors are `{r, g, b, a}` arrays; `data_files.Realize` (`goluwa/data_files.lua`) turns color and vector keys into `Color`/`Vec3` when a definition is registered. The registry keeps the pure copy in `Source[name]` (`data_files.New(dir)`).
- A registry (`damage_types`, `status_effects`, `movesets`, `emitters`) has `Register`/`Update(name, data)` (live, the game plays the edit at once), `Reload(name)` and `Save(name)`; jrpg clips (`effects.UpdateClip`), overlay kinds (`surface_overlays.UpdateKind`) and vfx textures (`vfx.UpdateFile`) have the same live update. Consumers read the runtime definition, never `Source`.
- Data forms that stand in for functions (damage type `Apply`, status effect `Think`, slopes, `Wobble`, ...) are compiled in `Register`. A definition may still hold a function; the editor then shows it as non editable.
- Clips (`goluwa/render3d/clips.lua`, jrpg ones in `addons/jrpg/lua/jrpg/clips/`): values are numbers, names (a track or a param `p.name`) or expression strings (`"p.spin + v.time * 0.8"`, keys listed in `EXPRESSION_KEYS`). Events burst emitters or debris, flash lights or `Call` a script; `Follow`, a layer's `Script` and `Call` name scripts registered with `clips.RegisterScript`. See [vfx.md](vfx.md).
- Other data files: surface overlay kinds (`lua/surface_overlays/<kind>.lua`, [surface-overlays.md](surface-overlays.md)), vfx textures and flipbooks (`lua/vfx_textures/`), gpu emitters (`lua/emitters/<name>.lua`), particle shaders (`lua/particle_shaders/`) and grenade puff styles (`addons/game/lua/effect_data/grenade_puffs.lua`).

## Effects editor

The `Effects editor` desktop program (`addons/jrpg/lua/jrpg/effects_editor.lua`, `ctrl+z`/`ctrl+y`, `space` plays) edits every category above and plays the selected effect on a stage (`effects_stage.lua`: the local player, a spawned npc, or a gizmo point used as hit position and normal). The stage target is made unkillable for the session. Edits apply to the live registry at once; `FILE > save` writes the file back. An edit that fails to apply (validation, glsl error) is shown in the status line and the registry keeps the last good data.

- An effect file can carry a `Preview` block the editor applies when it is opened (stage, view, exposure, `Params`, a `Drive` from `effects_drive.lua` that sweeps a point or swings a blade); the runtime ignores it.
- Rows are built from the data (`addons/game/lua/data_items.lua`), refined by a schema per category (`addons/jrpg/lua/jrpg/effects_schema.lua`, shape and `data_schema.Check` for dangling references in `addons/game/lua/data_schema.lua`): ranges, enums, `Ref` dropdowns to other categories, list display modes, groups and defaults. Lists are `list` property nodes, see [ui.md](ui.md).
- Structural changes rebuild the rows; a value edit never does, or a drag in a number field would be cut off.
- History is `addons/game/lua/data_history.lua` (snapshots, quick successive edits coalesce).
- Clips get a timeline (`addons/jrpg/lua/jrpg/clip_edit.lua`). Expression tracks have no keys.
- The view flies with `addons/editor/lua/view_camera.lua` (shared with the move editor).
- Reload of the code behind a script goes through `--hot-reload`.

## Emitters

An emitter file (`addons/game/lua/emitters/<name>.lua`, loaded by `addons/game/lua/emitters.lua`, registry in `goluwa/render3d/emitter_data.lua`) is a sparse table of `particle_emitter_gpu` properties: a property equal to the component default is not stored. Code asks for it by name: `emitters.Get(name, inputs)` (a realized copy for `vfx.CreateEmitter`), `emitters.Burst(name, position, direction, count, inputs)`, `emitters.DefineBurst(name, inputs)`. A clip layer or event can name an emitter file or give properties inline.

- Values a caller varies are declared as `Inputs` in the file, each with a default and target properties and a mode (`set`, `scale`, `add`, range and color variants). Passing an undeclared input is an error.
- A burst is fixed when defined, so every distinct input set is its own gpu emitter, and emitter slots are shared and limited: round the values you pass.
- Emitter data is checked against the property lists whenever it is built (`particle_emitter.CheckProperties`), so a bad edit fails in the editor instead of later in entity creation.
- A damage type or status `Particles` block can name a base emitter (`Particles = {Emitter = "frozen_snow"}`); read particle values through `effects.GetParticles(definition)`, which merges type defaults, the emitter file and the block, never from `definition.Particles` directly.
- Range and curve properties (see [particles.md](particles.md)) show one row for their current form, with the other forms in the row's context menu.
- Cpu emitters (solid meshes) have no data files or shaders; they are edited inline, as a damage type's `Debris` block.

## Particle shaders

A gpu emitter can pick a `Shader` (`glow`, `snow`, `puff`, `sprite`, your own) with `ShaderParams`; see [particles.md](particles.md) for the glsl hooks and limits. The `particle shaders` editor category edits the files in `addons/game/lua/particle_shaders/` (library: `addons/game/lua/particle_shader_library.lua`). A change to the glsl or the param layout recompiles the particle compute pipeline; on error the previous version keeps running. Play runs the emitter named by the shader's `Preview.Emitter` (for example `shader_preview`) with the edited shader forced on. Built-in shader files are ordinary files, so duplicate before experimenting.

## Source particles

`addons/game/lua/pcf.lua` reads Source `.pcf` particle files (DMX binary) from mounted games and converts one system at a time into gpu emitter data (`pcf.Parse`, `pcf.Convert(system)` returns the data plus the operators it could not map). It converts units (inches to meters, z up to y up), maps initializers, operators and renderers that have an equivalent, and takes the look from the VMT (`$basetexture` as a sprite or sprite sheet, additive or lit translucent). Control points, children, oscillators and the like are reported in the editor's notes line instead. Textures live in the mounted games, so mount `hl2` next to `gmod`.

The editor's `source particles` category opens a system as an editable gpu emitter; `save` writes it as a new emitter file. Console: `source_particles [text]` lists systems, `source_particle <text>` mounts the games if needed and opens the first match in the editor.

## Tests

`addons/jrpg/tests/render3d/effects_editor.lua`, `addons/game/tests/emitters.lua`, `pcf.lua`, `particle_shader_library.lua`, `data_items.lua`, `data_schema.lua`, `data_history.lua`, and `addons/jrpg/tests/entities/clip_edit.lua`.
