# Frame generation

`r_frame_generation` presents a generated frame between every two rendered ones (FSR3's design). Sources: `goluwa/render/frame_pacer.lua` (present thread), `goluwa/render/vulkan/image_rendertarget.lua` (frame generation mode), `goluwa/render3d/frame_generation.lua` (the composer).

## Presentation

- `render.target:SetFrameGeneration(composer)` switches the window target into frame generation mode (nil switches back). The frame renders into a ui layer (`GetTexture()`), cleared to transparent, instead of an acquired swapchain image; render3d skips the blit into it, so the layer holds only what draws after the 3D scene (Draw2D, the forward overlay). At `EndFrame` the composer renders both presented images (generated and real) from the scene and the ui layer into the frame pacer's present images, then `PostRenderPass` runs; `GetOutputTexture()` is the composed real frame from then on (screenshots and the motion recorder read it).
- The ui layer is composited as premultiplied: `scene * (1 - ui.a) + ui.rgb`. render2d's alpha presets accumulate coverage in alpha (Porter-Duff over) for this; `multiply` cannot be represented on a transparent layer.
- The main thread never touches the swapchain in this mode. The frame pacer owns a ring of present image pairs, and a present thread (its own Lua state, a second queue of the graphics family, function pointers looked up by the main thread) acquires, submits a pre-recorded copy into the swapchain image and presents: the generated image as soon as the frame arrives, the real one half the smoothed rendered interval after that. The present queue is used only by that thread; `Device:WaitIdle` pauses it, because `vkDeviceWaitIdle` needs every queue externally synchronized. `RebuildFramebuffers` stops the thread before touching the swapchain and starts a new one after.
- Do not change the swapchain image count at runtime: descriptor set counts of many pipelines are sized from it when they are created.
- Measure pacing with `render.target:GetFramePacer():GetPresentIntervals()` (seconds between the last 64 presents) against `GetInterval()` (the smoothed rendered interval).
