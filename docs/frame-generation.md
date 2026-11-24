# Frame generation

`r_frame_generation` presents a generated frame between every two rendered ones (FSR3's design). Sources: `goluwa/render/frame_pacer.lua` (present thread), `goluwa/render/vulkan/image_rendertarget.lua` (frame generation mode), `goluwa/render3d/frame_generation.lua` (the composer), `goluwa/render3d/optical_flow.lua`.

## Presentation

- `render.target:SetFrameGeneration(composer)` switches the window target into frame generation mode (nil switches back). The frame renders into a ui layer (`GetTexture()`), cleared to transparent, instead of a swapchain image; render3d skips its blit into it, so the layer holds only what draws after the 3D scene (2D, the forward overlay). At `EndFrame` the composer renders the generated and the real image from the scene and the ui layer into the frame pacer's present images. `GetOutputTexture()` is the composed real frame (screenshots and recorders read it).
- The ui layer is composited premultiplied: `scene * (1 - ui.a) + ui.rgb`. render2d's alpha presets accumulate coverage in alpha for this; `multiply` blending cannot be represented on a transparent layer.
- The main thread never touches the swapchain in this mode. The frame pacer owns a ring of present image pairs and a present thread (its own Lua state, a second queue of the graphics family) that acquires, copies and presents: the generated image when the gpu has finished the frame, the real one half the smoothed rendered interval later. `vkDeviceWaitIdle` needs every queue externally synchronized, so `Device:WaitIdle` pauses the present thread, and `RebuildFramebuffers` stops and restarts it.
- Do not change the swapchain image count at runtime: descriptor set counts of many pipelines are sized from it at creation.
- Measure pacing with `render.target:GetFramePacer():GetPresentIntervals()` (seconds between recent presented images, timed on the gpu) against `GetInterval()` (the smoothed rendered interval).

## Interpolation

`frame_generation.Compose` runs FSR3's frame interpolation between last frame's and this frame's ui free image: depth and motion dilation, depth and motion vector scattering to the interpolated time (packed `r32ui` with `imageAtomicMax`, nearest surface wins), hole inpainting pyramids, disocclusion, interpolation and color inpainting.

- Motion vectors follow FSR's convention (previous minus current, the negated engine velocity) and carry no jitter.
- The camera matrices are captured at `PreRenderPass`, because by the time the composer runs render3d has replaced its previous camera with this frame's.
- Motion blur trails lie outside the moving silhouette over background vectors, so the motion blur pass writes a color-weighted average motion (`blurred_motion`) that dilation prefers where it is longer.
- Integer fields are storage images; textures read through the bindless set must be in a shader read layout first.

Check the result against rendered ground truth: move the camera at a constant speed, capture the generated frame (`frame_generation.GetDebugTextures`), render the same path offset by half a step and compare; the generated frame should be much closer to it than either rendered neighbour or their average.

## Optical flow

`optical_flow.lua` is FSR3's optical flow over the presented image's luma (luma pyramid, coarse to fine block matching, scene change detection from luma histograms, which resets the generated frame to the real one). It runs every rendered frame so its previous luma stays current; `r_frame_generation_optical_flow` turns it off. Interpolation blends it in where it explains the two frames better than the motion vectors (moving shadows, reflections, animated textures). Differences from FSR's source are for portability: wave intrinsics become shared memory reductions, 8 and 16 bit storage formats become 32 bit (universally supported as storage images), and the previous histogram is double buffered because FSR reads and writes it from different workgroups of one dispatch.
