# DLSS

NVIDIA DLSS super resolution and ray reconstruction through NGX, bound with ffi (`goluwa/bindings/ngx.lua`), driven by `goluwa/render3d/dlss.lua` and the passes in `goluwa/render3d/passes/dlss.lua`. It is optional: nothing loads until `r_aa` is `dlss` or `dlss_rr`, and it needs an NVIDIA gpu with the DLSS SDK feature libraries. Test: `test/tests/render3d/dlss.lua`.

## Setup

- The driver ships the NGX core (`libnvidia-ngx.so.1`). The feature libraries (`libnvidia-ngx-dlss.so.*`, `libnvidia-ngx-dlssd.so.*`) come from the DLSS SDK (github.com/NVIDIA/DLSS, `lib/Linux_x86_64/rel`) and are not redistributable. `r_dlss_library_directory` (relative to the repository root) says where they are. Streamline is not needed.
- The device needs `VK_NVX_binary_import`, `VK_NVX_image_view_handle`, `VK_KHR_push_descriptor` and `VK_KHR_buffer_device_address`; `vulkan_instance.lua` requests them when available. Without them NGX loads but reports `FeatureInitResult` `PlatformError`.
- `r_dlss_logging` writes NGX's logs to `storage/logs/ngx`, the first place to look when a feature does not initialize.

## NGX on Linux

- The feature library directory is only found through `NVSDK_NGX_FeatureCommonInfo` passed to `NVSDK_NGX_VULKAN_Init_ProjectID_Ext`; a config file or the app directory is not searched (notably on NixOS).
- A valid app id is required: use a GUID-like project id with the custom engine type, not `Init_Ext2` with app id 0.
- Of the discovery functions the driver core implements only `GetFeatureRequirements` and the deprecated `RequiredExtensions`; availability is read from the capability parameters (`SuperSampling.Available`, `SuperSamplingDenoising.Available`).
- `NVSDK_NGX_Parameter` is a vtable; setters and getters are slot calls (see the binding). The binding does not call `NVSDK_NGX_VULKAN_Shutdown1`, which crashed.

## The passes

- `r_aa dlss` replaces taa: jittered color, gbuffer depth (reversed) and velocity in, an output sized image out. With `r_upscale_height` below the window height it also upscales (DLAA when equal). `r_upscale_height` must be set before the pipelines are built (stored pvar or `GOLUWA_PVARS`).
- `r_aa dlss_rr` is ray reconstruction: it also takes diffuse albedo, specular albedo, normal with roughness, specular motion and the reflection hit distance (`dlss_guides`, at the render size) and denoises the color itself.
- Conventions: the jitter is taa's in pixels, the velocity (current minus previous in uv) is scaled by minus the render size; the color is pre-exposed with `Pre.Exposure` 1 and auto exposure.
- A feature is created with the command buffer of the frame that first needs it and recreated (after a device wait) when the render or output size changes.

## Raw samples for ray reconstruction

`render3d.IsDenoisingBypassed()` (true with `dlss_rr`) switches the engine's own denoisers off so the network sees noisy but unbiased light: the screen GI (`radiance`) skips temporal reuse, accumulation and filtering, ray shadows are traced per light in the lighting pass instead of the filtered `ray_shadow_*` passes, caustics drop their temporal history, and the path tracer writes the current frame's samples (`pt_raw`). Probe GI is not bypassed since its probes are already smooth. The principle: the network needs noise that is new every frame; anything carried over frames (reservoirs, history) looks like detail to it and survives as blotches. Judge sampler changes under `dlss_rr` by the output, not by the input's noise.

Inspecting: `lighting_debug_indirect` shows the indirect light times albedo (still a valid input for demodulation); `lighting_debug_reflections` shows the specular the lighting reads; `r_dlss_show_input` makes the post chain show what DLSS is given instead of its output while DLSS keeps running, so toggling it compares the same frame.

## Limitations

- No exposure texture, no transparency, particle or alpha masks are passed.
- The specular motion assumes a static reflected scene.
