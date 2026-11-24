# Screenshots and cameras

- `luajit glw --2d --background --exit-on-error --screenshot lua "./tmp/script.lua"` runs one frame and saves a screenshot.
- For more control use the `Screenshot(cb, opt)` global (`goluwa/screenshot.lua`): `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:SaveWithoutAlpha(path)`, `:Save(path)` keeps alpha, `:GetPixel(x, y)`). `opt.update_events = n` runs n Update events first (so UI layout resolves); `opt.midframe = true` captures immediately from inside a Draw listener. With `--hdr` the capture is the encoded HDR layer, matching an SDR screenshot.

```lua
Screenshot(function(texture)
    print(texture:SaveWithoutAlpha()) -- auto path under storage/logs/screenshots/
end, {update_events = 3})
```

## 3D shots and the camera

`Screenshot` captures whatever is being rendered. To capture the 3D scene from a chosen position use `Shot` (`goluwa/render3d/shot.lua`), which holds a view until GI, TAA and auto exposure have settled, then captures.

- CLI: `luajit glw --3d --background --exit-on-error shot tmp/out.png --setup tmp/scene.lua --pos 0,4,18 --ang -10,0,0 --fov 70 --ev 15 --settle 3 --converge 0.5`. Angles are degrees, `--ev` locks exposure at that EV100, `--setup` runs a Lua file first to build a scene. The command's flags are declared in `shot.lua`.
- `Shot.Capture(view_properties, cb, opt)` calls `cb(texture, info)`. `opt.settle` is the minimum hold time, `opt.converge = n` keeps capturing until consecutive captures differ by at most n (or `opt.max_settle` passes), `opt.wait_loaded = true` first waits until loading has finished and the instance set is quiet (use it after loading a map, which returns before models and materials finish). `Shot.Sequence(list, cb, opt, done)` captures several views in turn.

```lua
local Shot = import("goluwa/render3d/shot.lua")
Shot.Capture({Position = Vec3(0, 5, 0), Rotation = QuatDeg3(-30, 0, 0), ExposureLock = 15}, function(texture, info)
    print(texture:SaveWithoutAlpha("tmp/shot.png"), info.seconds)
    system.ShutDown(0)
end, {settle = 3, converge = 0.5})
```

- To move the camera do not write to `render3d.GetCamera()` (the player's view overwrites it every frame). Activate a view above the player: `View.New{Priority = 100, Position = ..., Rotation = ..., ExposureLock = 15}:Activate()` with `View = import("goluwa/render3d/view.lua")`. Unset fields are copied from the current camera; `ExposureLock` is an EV100. A view hides the local player's body unless `HidePlayer` is false. `view:Remove()` gives control back.
- A camera that jumps (a cut) calls `render3d.CutCamera()` in that frame so the jump makes no motion vectors and TAA drops its history.
- For A/B comparisons freeze time-driven effects and lock exposure (see performance.md "Screenshot A/B"). After a camera change, let temporal history converge before capturing.

### Camera scale

The camera has a `Scale` (how big the observer is; `View` carries it like `FOV`). The player's camera sets it from the character scale and the `r_view_scale` pvar. Systems tuned for a human sized observer read `render3d.GetCamera():GetScale()`; shaders read `view_scale` from the camera block; CPU caches that must not rebuild every frame use `render3d.GetSnappedViewScale()` and rebuild on `ViewScaleChanged`. Only distances about how far the observer cares or resolves scale with it (shadow and GI ranges, draw distances, near plane); physical quantities (fog density, atmosphere, light range, material sizes) stay in meters.

## Saved views

The `saved_views` addon keeps named views per scene in `addons/saved_views/lua/view_data/<scene>.lua` (camera, time, location, exposure, climate differences from `climate.DEFAULTS`, a note). Check `views` (or that directory) before asking for a camera, and save good ones with `saveview <name> [note]`. `copyview` copies the state as text.

- `view <map> <name>` (or `view <name>` for the current scene) loads the scene if needed, sets time, location and the full climate, freezes the time scale and holds the camera with an active `View`; `viewoff` releases it. `viewshot [map] <name|all> [--out path] [--settle s] [--converge d]` captures views through `Shot.Capture` (run it as `luajit glw --3d --background --exit-on-error viewshot ...`).
- From a script: `import("lua/saved_views.lua").Apply(map, name, cb, quiet)` (`map` is the scene key or its short name) loads the scene, sets the world and calls `cb(view, entry)` once loading has settled. `view` is the active `View`, so move it with `SetPosition`/`SetRotation`/`SetFOV`; `view:SetExposureLock(false)` restores auto exposure. Call `saved_views.Release()` or `system.ShutDown(0)` when done.
- A scene is `loaders.loaded_map` or, for a procedural scene script, whatever it passes to `saved_views.SetScene(...)` at the top of its script.
- Views are not exact: randomness and animation do not reproduce pixel for pixel, and surface conditions, fluid volumes, overlays and the eye exposure mode are not part of a view.

## Recording frames

`FrameRecorder` (`goluwa/render/frame_recorder.lua`) records real frames for analysis without stalling: each kept frame is cropped, downscaled and converted by a compute pass inside the frame's own command buffer into buffers allocated at `Start`, and nothing is read back until the clip is analysed. Analysis runs afterwards on the GPU, so it does not affect recorded frame times.

```lua
local FrameRecorder = import("goluwa/render/frame_recorder.lua")
FrameRecorder.Record({
    frames = 300,          -- capacity, allocated up front
    every = 2,             -- or fps = 30; skipping hides flicker that alternates every frame
    fixed_dt = 1 / 60,     -- fixed game step, so two runs line up frame for frame
    channels = {
        {name = "color"},                                                      -- the presented image
        {name = "luma", format = "r8", scale = 0.5, crop = {0.25, 0.25, 0.5, 0.5}},
        {name = "depth", source = "depth", format = "r32f", scale = 0.5},
        {name = "velocity", source = "velocity", format = "rg16f", scale = 0.5}, -- any gbuffer texture name
    },
}, function(clip)
    local diff = clip:Diff("color")
    print(clip:Stats(diff.name)[10].active)
    clip:SaveFrame(clip:Variance("color").name, 1, "tmp/flicker.png", {scale = 10})
    clip:SaveSheet("color", "tmp/sheet.png", {frames = 12})
    clip:SaveVideo("color", "tmp/clip.mkv")       -- lossless, through ffmpeg
    clip:Remove()
end)
```

- `rolling = true` with `recorder = FrameRecorder.New(config):Start()` keeps the last `frames` until `recorder:Stop()` returns the clip: start, reproduce the glitch, stop.
- Sources: `"output"` (default, what is presented), `"scene"` (the HDR image before tonemapping; store it as `r32f` since its pre-exposure scale exceeds fp16 precision), `"depth"`, a gbuffer texture name, a texture or a function returning one. A channel's `glsl` can replace the default downscale.
- `clip:Map{...}` runs GLSL over the clip and stores the result as a new channel, so analyses chain. `Diff`, `Flow` (block matched motion), `Variance`, `Slice` (one row or column over time, for judder and flicker), `Stats` and `Noise` (separates per-pixel flicker from persisting boil, with autocorrelation over lags) are built on it. Read the module for their options.
- Measure noise on `"scene"` as `r32f`: 8-bit output quantization adds fake flicker and hides small changes.
- `clip:ReadFrame(name, i)` copies one frame to the CPU; `clip:GetFrameMeta(i)` has times, frame numbers and whatever `on_frame(meta)` added.
