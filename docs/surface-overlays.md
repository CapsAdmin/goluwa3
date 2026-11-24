# Surface overlays

Temporary, animated looks on one visual (magic: crystal, void, gilding, shields, runes, storms, status looks), with no simulation. A layer with `Duration` 0 lasts until removed, so an overlay can also be a lasting state such as `charred`. The conditions of the static world put overlays on things that touch them through exposure ([surface-conditions.md](surface-conditions.md)).

`goluwa/render3d/surface_overlays.lua`. The engine has no kinds of its own: they are files in any addon's `lua/surface_overlays/` (examples in `addons/examples/lua/surface_overlays/`, jrpg statuses in `addons/jrpg/lua/surface_overlays/`). Example scene: `addons/examples/lua/examples/render3d/surface_overlays_demo.lua`.

- `surface_overlays.Add(visual, kind, config)` returns a handle (config: duration, fades, intensity, scale, speed, colors, delay, `UVScale`, plus the kind's params by name). `handle:Remove(fade_out)`, `handle:SetIntensity(v)`, `handle:SetFade(v)` (hold the reveal, what the editor's slider scrubs), `surface_overlays.Clear(visual)`. A visual holds a limited number of layers (the oldest is replaced) and a limited number of visuals carry overlays at once.
- `UVScale` makes a layer take its noise position from the mesh uv instead of object space, so the pattern follows the surface parameterisation (used on the sword trail ribbon, see [vfx.md](vfx.md)).
- Animation is evaluated on the GPU from the layer's start time, so an overlay costs nothing per frame on the CPU; add, remove and expiry write one slot row.
- The carrier is the instance row's `overlay` value (`draw.SetOverlay` / `instances.SetOverlay`, which also selects the overlay pipeline variants, see [render3d-pipeline.md](render3d-pipeline.md)); it indexes a staged table of slots. Visuals the scene store does not draw show no overlays.
- `apply_surface_overlays` runs in the gbuffer after the surface conditions and before the weather stage, so a kind may change albedo, roughness, metallic, normal and emissive and add a clearcoat film. The translucent pass applies them too, and a kind's coverage (`overlay_cover`) raises a pane's alpha and lowers its refraction. The moments pass, reflection rays and DDGI hits do not see overlays.
- Noise is object local (`c.P`), so it sticks to moving visuals.

## Kinds

A kind is one data file, `lua/surface_overlays/<name>.lua`: defaults, up to four `Params` (`{Name, Default, Min, Max}`, read in glsl as a float named in snake case) and `Source`, the glsl body of a function with the surface, weather, layer, context (`P`, `N`, `V`, `height`, `ndv`) and the envelopes `grow`, `outro`, `fade` and time `t`. Reveals use `grow` and `outro`, pulses use `t`. Helpers such as `overlay_noise`, `overlay_cover`, `overlay_hash`, `overlay_reveal` are in `surface_overlays.lua`. Emissive is in absolute units, so a kind's emission is scaled by `surface_overlays.EMISSION`. Kind order sets the glsl case numbers, so a new kind only appends.

- Live editing: `surface_overlays.UpdateKind(name, data)` (called by the effects editor) compiles the kind alone in a standalone preview pipeline (`surface_overlay_preview.lua`) with the same glsl, and restores the previous data on a glsl error (`kind line N: message`).
- The real gbuffer and translucent pipelines are expensive to compile, so after a change to a `Source` or a param name they are rebuilt in the background (`render3d.RebuildPipelinesAsync`) and swapped in when ready, while the old overlay keeps showing. Never swap a pipeline whose compile job is still running, the first draw would block on it. `surface_overlays.IsRebuilding()` says whether a rebuild is pending.

## Tests

`test/tests/render3d/surface_overlays.lua`. Tests that need an overlay to age override `surface_overlays.GetTime`, because the test frame clock does not advance.
