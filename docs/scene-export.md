# Saving scenes with their assets

A scene is a directory: `storage/scenes/<name>/scene.scene` (`scene.GetSceneDirectory`, `scene.GetPath`). `scene_export.Save(name, options)` (`goluwa/render3d/scene_export.lua`; editor FILE > save scene, the checkboxes are the options) writes the scene and optionally the assets it uses next to it. `textures` and `models` need `materials`. The save is written to `<name>.saving` and replaces `<name>` only once everything is written, so a failed save leaves the old scene.

An asset path property (a storable variable with the `asset` category) that starts with `./` refers to the scene's own directory; `scene.Load` resolves it when the scene is read. Nothing probes the disk for it. Every property holding a model path needs the `asset` category, or its `./` is never resolved and the model load never completes and never fails.

## Options

- `materials`: every material the scene draws with goes to `materials/<id>/material.mat` (format in [material-baking.md](material-baking.md)). Every file is loaded back and compared with what was written; the returned stats list failures, mismatches and materials with unserialized properties.
- Material lookups by path (brush sides, displacements, decals, static meshes naming a vmt; Crysis `.mtl` paths and sub material slots) are redirected, not rewritten: `materials/index.lua` (`material_file.AliasFileName`) maps the original path to the exported `.mat`. On `scene.Load` the `SceneReading` event lets `material_file` install it as `Material.path_aliases`, which the material lookups consult first. Materials the world asked for but never draws (tool textures) are written too so those lookups resolve.
- `terrain`: the data of a `terrain` component that is not editable goes to `terrain/` (`heightmap_file.lua`) and the component's `Path` becomes `./terrain/terrain.lua` (an editable terrain's maps are already in the scene; see [terrain-streaming.md](terrain-streaming.md)). The terrain's own tile materials are not exported; the terrain rebuilds them.
- `textures`: the materials' textures are copied next to the `.mat` (baked cache files and originals out of archives) so references are relative. Without it the file keeps the textures' original paths.
- `models`: loaded models go to `models/<id>/model.mesh` and model path properties (`visual`/`model` `ModelPath`, `rigid_body` `ShapeModelPath`, `scatter_placements` `Model`) are rewritten to point there. Unloaded and procedural (`.lua`) models stay as they are (`stats.skipped_models`).

## What a scene does not carry

- The local player and its weapons: a scene's roots are the world and the map; players are created at runtime.
- `cry_level` is saved as it is: when the game is installed it builds what the level needs and skips the terrain if its entity already has a saved terrain; without the game it logs and builds nothing.
- Generated textures without a file (other than the terrain's) are listed in `Meta.unserialized`. A texture that is the shared fallback texture is written as `{fallback = true}` and loads as the fallback again.

## Model file

`goluwa/render3d/model_file.lua`, extension `.mesh`, decoded by `model_decoders/mesh.lua`: a magic, a luadata header and a blob of raw data (packed vertices in `vertex_layout`, indices, skins, skeleton, mesh colliders). The header holds per mesh metadata (counts, offsets, bounds, bend height, root chain, material slot, LOD), the material file path relative to the model file (the scene's shared `materials/` directory), the skeleton and the physics (convex hulls via `convex_hull.ToPlain`, mesh colliders in the blob). One file serves both rendering and physics. Geometry is read from the mesh's own CPU buffers, so a mesh without them is not written. A different header version or vertex stride is refused on read.

Not in the file, counted in `stats.dropped` (`model_file.GetDropped`): animation clips, pose parameters, flexes and ragdolls. A skinned model loaded from a file is in bind pose and cannot play clips.
