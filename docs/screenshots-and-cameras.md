# Screenshots and cameras

- `luajit glw --2d --background --validate --screenshot lua "./tmp/script.lua"` runs one frame and saves a screenshot. For more control use the `Screenshot(cb, opt)` global (`goluwa/screenshot.lua`): `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:SaveWithoutAlpha(path)`, `:Save(path)` keeps alpha, `:GetPixel(x, y)`).
- `opt.update_events = n` runs n Update events first (use for UI so layout resolves). `opt.midframe = true` captures immediately mid-frame; call it from inside a Draw/Draw2D listener.

```lua
Screenshot(function(texture)
    print(texture:SaveWithoutAlpha()) -- auto path under storage/logs/screenshots/
end, {update_events = 3})
```

## 3D shots and the camera

`Screenshot` captures whatever is being rendered. To capture the 3D scene from a chosen position use `Shot` (`goluwa/render3d/shot.lua`), which holds a view until GI, TAA and auto exposure have settled, then captures.

- CLI: `luajit glw --3d --background --validate shot tmp/out.png --setup tmp/scene.lua --pos 0,4,18 --ang -10,0,0 --fov 70 --ev 15 --settle 3 --converge 0.5`. Angles are degrees, `--ev` locks exposure at that EV100 (otherwise auto exposure), `--setup` runs a Lua file first to build a scene.
- `Shot.Capture(view_properties, cb, opt)` calls `cb(texture, info)` (`info.seconds`, `info.frames`). `opt.settle` is the minimum seconds held (default 2); `opt.converge = n` keeps capturing until the mean rgb difference (0-255) between captures is at most n or `opt.max_settle` (default 15) passes (`info.converged`, `info.difference`). `Shot.Sequence(list, cb, opt, done)` captures several views in turn.

```lua
local Shot = import("goluwa/render3d/shot.lua")
Shot.Capture({Position = Vec3(0, 5, 0), Rotation = QuatDeg3(-30, 0, 0), ExposureLock = 15}, function(texture, info)
    print(texture:SaveWithoutAlpha("tmp/shot.png"), info.seconds)
    system.ShutDown(0)
end, {settle = 3, converge = 0.5})
```

To move the camera do not write to `render3d.GetCamera()` (the player's view overwrites it every frame). Activate a view above the player: `View.New{Priority = 100, Position = ..., Rotation = ..., ExposureLock = 15}:Activate()` with `View = import("goluwa/render3d/view.lua")`. Unset fields are copied from the current camera; `ExposureLock` is an EV100 and exposure fields default to the global `r_exposure_*` settings. `view:Remove()` gives control back.

For A/B comparisons freeze time-driven effects and lock exposure (see performance.md "Measuring correctly"). After a camera change, let temporal history converge before capturing (a few dozen frames).
