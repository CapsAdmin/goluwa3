# Plan: Port Render3D Features from OpenGL to Vulkan

This plan ports features from your old OpenGL-based goluwa render3d system to the new Vulkan-based goluwa3 project. The old system has a full deferred rendering pipeline with PBR, shadows, post-processing, and scene management. The new system has solid Vulkan foundations (bindless textures, push constants, dynamic rendering) but only basic forward rendering with hardcoded lighting.

## Completed Steps

1. ✅ **Created material system** — Added `goluwa/graphics/material.lua` with texture slots (albedo, normal, metallic_roughness, occlusion, emissive), PBR factors, and integration with bindless texture arrays.

2. ✅ **Enhanced render3d with PBR** — Updated `goluwa/graphics/render3d.lua` with:
   - Full PBR shader (Cook-Torrance BRDF, GGX distribution, Fresnel-Schlick, Smith-Schlick geometry)
   - Normal mapping support with TBN matrix
   - Tangent vertex attribute support (12-float stride: pos + normal + uv + tangent)
   - HDR tonemapping (Reinhard) and gamma correction
   - Metallic/roughness workflow (glTF spec compliant)
   - Ambient occlusion support
   - Emissive texture support
   - Simple ambient specular for metals (IBL approximation)
   - **Important:** Uses `GL_EXT_scalar_block_layout` for push constants to match C struct layout

3. ✅ **Updated glTF loader** — Enhanced `goluwa/gltf.lua` to:
   - Load all PBR textures (albedo, normal, metallic/roughness, occlusion, emissive)
   - Create Material objects from glTF materials
   - Include tangent data in interleaved vertices
   - Support all PBR material factors from glTF

4. ✅ **Created light system** — Added `goluwa/graphics/light.lua` with:
   - Light types (directional, point, spot)
   - Scene light management
   - GPU-ready light data structures

5. ✅ **Created shadow map system** — Added `goluwa/graphics/shadow_map.lua` with:
   - Depth-only render pass pipeline
   - Orthographic projection for directional lights
   - Depth bias for shadow acne reduction
   - PCF-ready shadow sampler (compare mode)

## Technical Notes

**Push Constant Alignment:** The fragment shader must use `layout(push_constant, scalar)` with the `GL_EXT_scalar_block_layout` extension. Without this, vec4 fields have 16-byte alignment requirements that don't match C's tightly-packed `float[4]` arrays, causing data corruption and visual artifacts (color shifting based on camera position).

**Coordinate System:** The camera uses Source Engine style coordinates with axis swapping. When passing camera position to shaders, it must be transformed: `vec3(-pos.y, -pos.x, -pos.z)` to match the world space coordinates used in the vertex shader's world position output.

## Remaining Steps (Future Work)

6. **Integrate shadows into main render** — Need to:
   - Add light space matrix to shader (requires UBO due to push constant limits)
   - Add shadow map sampler to descriptor set
   - Implement shadow sampling in PBR shader

7. **Implement G-Buffer deferred rendering** — Create `goluwa/graphics/gbuffer.lua` with:
   - Multiple render targets (albedo, normals, metallic/roughness, depth)
   - Geometry pass shader
   - Lighting pass shader (fullscreen quad)

8. **Add post-processing pipeline** — Create `goluwa/graphics/post_process.lua` with:
   - Offscreen framebuffer chain
   - Bloom via compute shader
   - FXAA pass

9. **Add sky rendering** — Create `goluwa/graphics/sky.lua` with:
   - Cubemap sky texture
   - Atmospheric scattering shaders

## Further Considerations

1. **Start with forward or deferred?** The current system uses forward rendering. Option A: Enhance forward rendering first with PBR + shadows (simpler, iterative). Option B: Jump straight to deferred (more work upfront, but matches old architecture). *Recommend Option A first.*

2. **Light management strategy?** Option A: Push constants for fixed light count (~4-8 lights). Option B: SSBO with dynamic light array (more complex but scalable). Option C: Compute shader light culling (clustered/tiled, most complex).

3. **Which model formats to support?** OBJ is already working. Option A: Add glTF support (modern, PBR-native). Option B: Port Assimp bindings (40+ formats, more dependencies). Option C: Keep OBJ only for now.

---

## Feature Comparison Matrix

| Feature | OLD (goluwa) | NEW (goluwa3) | Priority |
|---------|:------------:|:-------------:|:--------:|
| **Rendering Architecture** |
| Forward Rendering | ✅ | ✅ | - |
| Deferred Rendering (G-Buffer) | ✅ | ❌ | High |
| Dynamic Render Passes | ✅ | ✅ | - |
| **Lighting** |
| Directional Light | ✅ | ✅ | - |
| Point Lights | ✅ | ❌ | High |
| Spot Lights | ✅ | ❌ | Medium |
| Light Attenuation | ✅ | ❌ | High |
| **Shadows** |
| Shadow Maps (2D) | ✅ | ⚠️ (infra only) | High |
| Cascaded Shadow Maps | ✅ | ❌ | High |
| Point Light Shadows (Cubemap) | ✅ | ❌ | Medium |
| **Materials/Shaders** |
| Material System | ✅ | ✅ | - |
| PBR (Metallic/Roughness) | ✅ | ✅ | - |
| Normal Mapping | ✅ | ✅ | - |
| Albedo/Diffuse Maps | ✅ | ✅ | - |
| Metallic Maps | ✅ | ✅ | - |
| Roughness Maps | ✅ | ✅ | - |
| Occlusion Maps | ✅ | ✅ | - |
| Emission/Self-Illumination | ✅ | ✅ | - |
| Alpha Test/Translucency | ✅ | ⚠️ (alpha test) | Medium |
| VMT (Source Engine) Support | ✅ | ❌ | Low |
| **Environment** |
| Sky Rendering | ✅ | ❌ | Medium |
| Atmospheric Scattering | ✅ | ❌ | Low |
| Environment Probes/IBL | ✅ | ⚠️ (approx) | Medium |
| Cubemap Reflections | ✅ | ❌ | Medium |
| **Post-Processing** |
| FXAA | ✅ | ❌ | Medium |
| HDR/Tone Mapping | ✅ | ✅ | - |
| Bloom | ✅ | ❌ | Medium |
| Depth of Field | ✅ | ❌ | Low |
| Chromatic Aberration | ✅ | ❌ | Low |
| **Scene Management** |
| Model Loading (Async) | ✅ | ⚠️ (sync) | Medium |
| Occlusion Culling | ✅ | ❌ | Medium |
| Material Batching | ✅ | ❌ | Medium |
| Distance Sorting | ✅ | ❌ | Medium |
| **Model Formats** |
| OBJ | ✅ | ✅ | - |
| glTF 2.0 | ❌ | ✅ | - |
| Assimp (40+ formats) | ✅ | ❌ | Medium |
| Source Engine BSP | ✅ | ❌ | Low |
| Source Engine MDL | ✅ | ❌ | Low |
| **Camera** |
| Matrix Stack | ✅ | ✅ | - |
| Frustum Culling | ✅ | ✅ | - |
| Depth Linearization | ✅ | ❌ | High |
| World Pos Reconstruction | ✅ | ❌ | High |
| **Vulkan-Specific** |
| Bindless Textures | ❌ (OpenGL) | ✅ | - |
| Push Constants | ❌ (OpenGL) | ✅ | - |
| Dynamic Rendering | ❌ (OpenGL) | ✅ | - |
| Compute Shaders | ? | ✅ | - |
| MSAA | ✅ | ✅ | - |

---

## Key Architectural Differences

| Aspect | OLD (OpenGL) | NEW (Vulkan) |
|--------|--------------|--------------|
| API | OpenGL 4.x | Vulkan 1.x |
| Shader Language | GLSL with runtime injection | GLSL compiled to SPIR-V |
| Uniform System | Global shader variables | Push constants + descriptors |
| Texture Binding | Traditional binding | Bindless (descriptor indexing) |
| Render Passes | FBO-based | Dynamic rendering |
| State Changes | Immediate | Pipeline variants (cached) |
| Synchronization | Implicit | Explicit (semaphores/fences) |
| Frame Management | Single-buffered logic | Multiple frames in flight |

The new Vulkan-based system has a more modern foundation but needs the higher-level rendering features ported from the old OpenGL system. The bindless texture system in goluwa3 is actually more advanced than the old system, making material/texture management potentially cleaner.
