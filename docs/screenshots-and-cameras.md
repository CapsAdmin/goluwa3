# Screenshots and cameras

- Take a screenshot: `luajit glw --2d --screenshot lua "./tmp/path/to/some/render/script.lua"`. this runs for one frame like `--one-frame`. If you need more advanced screenshots, use the Screenshot global.
- The `Screenshot(cb, opt)` global captures the screen. `cb(texture)` receives a `TextureDownloaded` with ready pixels (`:SaveWithoutAlpha(path)`, `:GetPixel(x, y)`). 
- `opt.update_events = n` runs n Update events first. Use this for UI so layout resolves before the capture. 
- `opt.midframe = true` captures immediately mid-frame. Call it from inside a Draw/Draw2D listener, and maybe use `TextureDownloaded:Save(path)` which saves the screenshot with alpha.

Example:
  ```lua
  Screenshot(function(texture)
      print(texture:SaveWithoutAlpha()) -- auto path under storage/logs/screenshots/
  end, {update_events = 3})
  ```

## 3D shots and the camera

`Screenshot` captures whatever is being rendered, so use it for 2D, UI and mid-frame captures. To capture the 3D scene from a chosen position, use `Shot` (`goluwa/render3d/shot.lua`). It holds a view until GI, TAA and auto exposure have settled, then captures.

- CLI: `luajit glw --3d shot tmp/out.png --setup tmp/scene.lua --pos 0,4,18 --ang -10,0,0 --fov 70 --ev 15 --settle 3 --converge 0.5`. Angles are in degrees, `--ev` locks exposure at that EV100, and `--setup` runs a Lua file first, e.g. to build a scene. Without `--ev`, auto exposure is used.
- `Shot.Capture(view_properties, cb, opt)` calls `cb(texture, info)`. `info.seconds` and `info.frames` say how long the view was held.
- `opt.settle` is the minimum number of seconds held (default 2). `opt.converge = n` then keeps capturing until the mean rgb difference (0-255) between captures is at most n, or `opt.max_settle` seconds (default 15) pass. `info.converged` and `info.difference` report the outcome.
- `Shot.Sequence(list_of_view_properties, cb, opt, done)` captures several views in turn without the player's view showing in between.

  ```lua
  local Shot = import("goluwa/render3d/shot.lua")
  Shot.Capture({Position = Vec3(0, 5, 0), Rotation = QuatDeg3(-30, 0, 0), ExposureLock = 15}, function(texture, info)
      print(texture:SaveWithoutAlpha("tmp/shot.png"), info.seconds)
      system.ShutDown(0)
  end, {settle = 3, converge = 0.5})
  ```

To move the camera, don't write to `render3d.GetCamera()` (the player's view overwrites it every frame). Activate a view above the player (priority 0) instead: `local view = View.New{Priority = 100, Position = Vec3(0, 5, 0), Rotation = QuatDeg3(45, 0, 0), ExposureLock = 15}:Activate()` with `View = import("goluwa/render3d/view.lua")`. Unset fields are copied from the current camera, `ExposureLock` is an EV100, and the exposure fields default to the global `r_exposure_*` settings. `view:Remove()` gives control back to the player.

