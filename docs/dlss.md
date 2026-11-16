# DLSS

NVIDIA DLSS super resolution and ray reconstruction through NGX, bound with ffi (`goluwa/bindings/ngx.lua`), driven by `goluwa/render3d/dlss.lua` and the passes in `goluwa/render3d/passes/dlss.lua`. It is optional: nothing loads until `r_aa` is `dlss` or `dlss_rr`, and it needs an NVIDIA gpu with the DLSS SDK feature libraries.

## Setup

- The driver ships the NGX core (`libnvidia-ngx.so.1`). The feature libraries (`libnvidia-ngx-dlss.so.*`, `libnvidia-ngx-dlssd.so.*`) come from the DLSS SDK (github.com/NVIDIA/DLSS, `lib/Linux_x86_64/rel`) and are not redistributable here. `r_dlss_library_directory` (default `local_stuff/DLSS/lib/Linux_x86_64/rel`) says where they are, relative to the repository root. The Streamline repository is Windows only and is not needed.
- The device needs `VK_NVX_binary_import`, `VK_NVX_image_view_handle`, `VK_KHR_push_descriptor` and `VK_KHR_buffer_device_address`; `vulkan_instance.lua` requests them when the gpu has them. Without them NGX loads but reports `FeatureInitResult` `PlatformError`.
- `r_dlss_logging` writes NGX's logs to `storage/logs/ngx`, the first place to look when a feature does not initialize.

## NGX on Linux

- The feature library directory is only found through `NVSDK_NGX_FeatureCommonInfo` in `NVSDK_NGX_VULKAN_Init_ProjectID_Ext` (arguments: project id, engine type, engine version, data path, instance, physical device, device, the two proc addrs, api version, feature info). A config file or the app directory does not work on NixOS.
- The snippets require a valid app id: use a GUID-like project id with the custom engine type, not `Init_Ext2` with app id 0.
- Of the discovery functions only `GetFeatureRequirements` and the deprecated `RequiredExtensions` are implemented by the driver core; the newer extension queries return `NotImplemented`. Availability is read from the capability parameters (`SuperSampling.Available`, `SuperSamplingDenoising.Available`, with `FeatureInitResult` 1).
- `NVSDK_NGX_Parameter` is a vtable; the setters and getters are slot calls (see the binding). `NVSDK_NGX_VULKAN_Shutdown1` crashed in a probe, so the binding does not call it.

## The passes

- `r_aa dlss` replaces taa: jittered color, the gbuffer depth (reversed) and velocity in, an output sized image out. With `r_upscale_height` below the window height the same pass upscales (the feature is created from the color and output texture sizes, DLAA when equal). `r_upscale_height` must be set before the pipelines are built (stored pvar or `GOLUWA_PVARS`), a runtime change leaves the textures at the old size.
- `r_aa dlss_rr` is ray reconstruction: it also takes diffuse albedo, specular albedo and normal with perceptual roughness in alpha (`dlss_guides`, built from the gbuffer at the render size) and denoises the color itself. Feed it noisy radiance: with `dlss_rr` the path tracer writes the current frame's samples instead of its progressive mean (`pt_raw`), the mean keeps accumulating for the views.
- Signs verified against a native resolution render: the jitter is taa's in pixels, the velocity (current minus previous in uv) is scaled by minus the render size to pixels. The color is the pre-exposed scene color with `Pre.Exposure` 1 and the auto exposure flag.
- A feature is created with the command buffer of the frame that first needs it and recreated (after a device wait) when the render or output size changes.

## Raw samples for ray reconstruction

`render3d.IsDenoisingBypassed()` (true with `r_aa dlss_rr`) switches the passes' own denoisers off so the network sees noisy but unbiased light:

- ReSTIR GI keeps its candidate, temporal and spatial resampling (that is the sampler) and skips the accumulation (`accumulation` 1) and the a-trous filters (`filter_enabled` 0).
- reflections keep their tracing resolution and spatial filter (one ray per pixel on rough surfaces is far noisier than the filtered signal the network was fed with, and it boiled) and drop only the temporal history (`history_tex` -1). `lighting_debug_reflections` shows the traced reflection the lighting reads.
- ray shadows: the `ray_shadow_*` passes are disabled and the lighting traces its own ray per light (`ray_shadow_tex` -1).
- caustics keep the spatial photon density filter (it is the estimator) and drop the temporal history (`history_tex` -1).
- DDGI and surfel GI are not bypassed: their probes are already smooth.

The guides also hold the specular motion (the virtual image of the reflection: the surface point pushed along the view ray by the reflection hit distance, reprojected with the previous camera, `dlss_guides` attachment 4) and the reflection trace's hit distance (`RayTracingHitDistance`, only while the reflections pass runs).

## Not done

- no exposure texture (the feature uses its auto exposure on the pre-exposed color), no transparency, particle or alpha masks.
- the specular motion assumes a static reflected scene.
