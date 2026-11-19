# Screenshots and cameras

- `luajit glw --2d --background --exit-on-error --screenshot lua "./tmp/script.lua"` runs one frame and saves a screenshot. For more control use the `Screenshot(cb, opt)` global (`goluwa/screenshot.lua`): `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:SaveWithoutAlpha(path)`, `:Save(path)` keeps alpha, `:GetPixel(x, y)`).
- `opt.update_events = n` runs n Update events first (use for UI so layout resolves). With `--hdr` the capture is the encoded HDR layer, so it matches an SDR screenshot and clips at UI white. `opt.midframe = true` captures immediately mid-frame; call it from inside a Draw/Draw2D listener.

```lua
Screenshot(function(texture)
    print(texture:SaveWithoutAlpha()) -- auto path under storage/logs/screenshots/
end, {update_events = 3})
```

## 3D shots and the camera

`Screenshot` captures whatever is being rendered. To capture the 3D scene from a chosen position use `Shot` (`goluwa/render3d/shot.lua`), which holds a view until GI, TAA and auto exposure have settled, then captures.

- CLI: `luajit glw --3d --background --exit-on-error shot tmp/out.png --setup tmp/scene.lua --pos 0,4,18 --ang -10,0,0 --fov 70 --ev 15 --settle 3 --converge 0.5`. Angles are degrees, `--ev` locks exposure at that EV100 (otherwise auto exposure), `--setup` runs a Lua file first to build a scene.
- `Shot.Capture(view_properties, cb, opt)` calls `cb(texture, info)` (`info.seconds`, `info.frames`). `opt.settle` is the minimum seconds held (default 2); `opt.converge = n` keeps capturing until the mean rgb difference (0-255) between captures is at most n or `opt.max_settle` (default 15) passes (`info.converged`, `info.difference`). `opt.wait_loaded = true` first waits until nothing is loading or spawning and the instance set has been unchanged for `opt.loaded_quiet` seconds (1.5), then starts the settle timer; use it after loading a map, since the load returns before models and materials finish. `Shot.Sequence(list, cb, opt, done)` captures several views in turn.

```lua
local Shot = import("goluwa/render3d/shot.lua")
Shot.Capture({Position = Vec3(0, 5, 0), Rotation = QuatDeg3(-30, 0, 0), ExposureLock = 15}, function(texture, info)
    print(texture:SaveWithoutAlpha("tmp/shot.png"), info.seconds)
    system.ShutDown(0)
end, {settle = 3, converge = 0.5})
```

To move the camera do not write to `render3d.GetCamera()` (the player's view overwrites it every frame). Activate a view above the player: `View.New{Priority = 100, Position = ..., Rotation = ..., ExposureLock = 15}:Activate()` with `View = import("goluwa/render3d/view.lua")`. A view hides the local player's body unless it is the player's own camera (`HidePlayer`, default true; the editor's view sets it false). Unset fields are copied from the current camera; `ExposureLock` is an EV100 and exposure fields default to the global `r_exposure_*` settings. `view:Remove()` gives control back.

The camera has a `Scale` (default 1, must be above zero; `View` carries it like `FOV` and `NearZ`) that says how big the observer is. The player's camera component sets it from `character_movement.Scale` times the `r_view_scale` pvar, smoothed over a fraction of a second, and scales its near plane with it. Systems tuned for a 1.8 m observer (audio ears, the battle camera) read `render3d.GetCamera():GetScale()` instead of the player. Shaders read it from the camera block (`view_scale`, any pass that includes `render3d.camera_block`) at runtime, and CPU side caches that must not change every frame use `render3d.GetSnappedViewScale()` (half octave steps with hysteresis) and rebuild on the `ViewScaleChanged` event. The rain box, the shelter map, the third person camera and the froxel fog knee follow it too (drops stay physical, so a large observer sees tiny drops). Only distances that say how far the observer cares or resolves should scale with it (shadow and GI ranges, draw distances, near plane); physical quantities (fog density, atmosphere, light range, material sizes) must stay in meters, and precision epsilons should come from depth or texel size.

A camera that jumps (a cinematic cut) calls `render3d.CutCamera()` in that frame: the previous view and projection read as the current ones, so the jump makes no motion vectors or motion blur, and TAA drops its history.

For A/B comparisons freeze time-driven effects and lock exposure (see performance.md "Measuring correctly"). After a camera change, let temporal history converge before capturing (a few dozen frames).

## Saved views

The `saved_views` addon keeps named views per scene in `addons/saved_views/lua/view_data/<scene>.lua` (luadata: `pos`, `rot`, `fov`, `time`, `latitude`, `longitude`, `ev`, `args`, `note`, and `climate` only for the fields that differ from `climate.DEFAULTS`, see `climate.Capture`). Check `views` (or read that directory; names are unique per map only) before asking for a camera, and add good ones with `saveview <name> [note]` while looking at them. `copyview` still copies the same state as text.

- `view <map> <name>` (or `view <name>` for the current scene) loads the scene if it is not the current one, sets time, location and climate (always the full climate, so a view never inherits the previous weather), freezes the time scale and holds the camera with an active `View`; `viewoff` releases it. `viewshot [map] <name|all> [--out path] [--settle s] [--converge d]` captures views through `Shot.Capture` with `wait_loaded` and `converge` 0.5 (run it as `glw --3d --background --exit-on-error viewshot ...`).
- From a script: `saved_views.Apply(map, name, cb, quiet)` (`map` is the scene key or its short name: `source:a3_hotel_street` or `a3_hotel_street`; view names are per map, so they may repeat across maps) (`import("lua/saved_views.lua")`) loads the scene and sets the world, then calls `cb(view, entry)` once the scene has stopped loading (`Shot.WaitLoaded`, unchanged for `quiet` seconds, default 1.5). `view` is the active `View` at the saved camera, so move it with `view:SetPosition(...)`, `SetRotation`, `SetFOV` between frames (temporal stability, GI settling); `view:SetExposureLock(false)` gives back auto exposure, since a view locks the saved `ev`. Call `saved_views.Release()` or `system.ShutDown(0)` when done. Without `cb` it returns at once, before the scene is ready.
- A scene is `loaders.loaded_map` (`source:gm_construct`) or, for a procedural scene, whatever it passes to `import("lua/saved_views.lua").SetScene({MODE = "ocean"})` at the top of its script (the name is its own path under `lua/`, from `debug.getinfo`, so renaming the file never goes out of sync with the call, only with the data file; the optional table is env vars replayed with `process.setenv` before the script is imported again). `SetScene` is cleared by the next `SceneLoad`.
- Views are good enough, not exact: scenes with randomness or animation do not reproduce pixel for pixel, and surface conditions, fluid volumes, overlays and the eye exposure mode are not part of a view.

## Motion maps

`MotionRecorder` (`goluwa/render/motion_recorder.lua`) debugs motion without saving frames: each frame the swapchain is copied to one of two gpu textures and a compute pass runs your glsl on every block of pixels (`mm.block` wide) of the pair, writing one `vec4` per cell into a single buffer. Nothing is read back until the end, so recording does not stall the frame. It compares what is presented, so it works in 2D and 3D and sees TAA jitter, GI flicker and UI.

The default (`MotionRecorder.Diff`) is the mean signed and absolute luma difference of each 4x4 block, which leaves only what changed. `MotionRecorder.Flow` block matches for a motion vector per cell (radius `p0`; motion beyond it per frame is not tracked). Your own preset is a table:

```lua
MotionRecorder.Record(3, function(map) -- seconds, then one readback
    map:GetStats()                  -- per frame: mean, max, active fraction of the magnitude; z, w mean of channels 3, 4
    map:SaveSheet("tmp/sheet.png")  -- contact sheet of frames
    map:SaveHeatmap("tmp/heat.png") -- where it changed over the whole recording
    map:SaveFrame(i, "tmp/f.png")
end, {
    block = 8, p0 = 2, scale = 0.2, -- p0..p3 are read with param(0..3)
    glsl = [[vec4 analyze(ivec2 cell, ivec2 origin) { return vec4(cur_luma(origin) - prev_luma(origin)); }]],
    magnitude = function(x, y, z, w) return math.abs(x) end, -- stats and heatmap
    draw = function(x, y, z, w, scale) return x / scale, 0, 0 end, -- r, g, b in 0..1 per cell
})
```

The glsl can use `fetch_prev`/`fetch_cur`, `prev_luma`/`cur_luma` (sqrt of luminance) and `mm.block`; unset fields come from `Diff`. Periodic spikes in `active` while the camera is still point at temporal effects updating in bursts. A fixed view repro is the pattern in `tmp/motion/construct.lua`.
