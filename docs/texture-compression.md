# Texture compression

`goluwa/render/texture_compress.lua` encodes images into block compressed mips on the gpu and returns a dds file (dx10 header, `dds.Encode`) as a string. The engine loads those directly (`dds.DecodeBuffer`, `Texture:UploadCompressed`). It needs the gpu device, so it only runs in `--2d`/`--3d`, not `--cli`.

## API

- `texture_compress.Compress{pixels, width, height, format, kind, mips, wrap, channel}`
  - `format`: `bc7` (rgba), `bc5` (red and green, for normal maps; the shader rebuilds z), `bc4` (one channel, `channel` 0 to 3).
  - `kind` picks the mip filter: `srgb` averages in linear light and marks the dds srgb, `normal` averages decoded vectors and renormalizes, `linear` is a plain average. `wrap` wraps the filter for tiling textures; `mips = false` writes one level.
- `texture_compress.Recompress{sources, edit, params, ...}` edits compressed textures without leaving the gpu: sources (dds strings or `{pixels, width, height}`) are decoded by sampling them in a compute shader, the `edit` glsl (`vec4 edit(ivec2 position, ivec2 size, vec4 texel)`) runs per texel, and the result goes into the same mip and encode stage. `texel` is the raw encoded value (an srgb source is read as unorm; use `to_linear`/`from_linear` for light math). `fetch(index, position)`, `source_size(index)` and `edit_params[i]` reach other sources and parameters. Pipelines are cached per edit text.
- `texture_compress.CompressLevels` encodes caller-made mips level by level (used for coverage preserving cutout mips, see `goluwa/render/cutout_texture.lua`).

## How it works

One compute invocation per block fits endpoints and writes the block into a storage buffer that is read back. bc4/bc5 use min/max endpoints refined by least squares. bc7 is mode 6 only (one subset, 7 bit rgba endpoints with a p bit each, 4 bit indices): principal axis, least squares refinement, p bit chosen by error, anchor index kept below 8 by swapping endpoints. Blocks of two colours that do not lie on one line are where the multi subset modes would help; if they are ever added, the partition tables can be read off the gpu's own decoder.

## Rules

- Every bc7 re-encode is lossy: repeated edits should start again from the lossless source and encode once.
- bc7 mode 6 has one p bit per endpoint shared by all four channels, so values of different parity in one block (a metallic 0 next to an odd roughness) cannot both be exact: one channel is off by one. This is inherent to the mode.
- dds data is read top row first (like vtf), so unlike png (which the engine's codec flips) a dds renders correctly on Source geometry as written.
- A `config.srgb` texture load turns `_unorm` into `_srgb` by itself; the dds format name does not decide the colour space on load.
- `bc.Decode` leaves channels the format lacks at zero (bc4 fills red, bc5 red and green).

## Verifying

`goluwa/codecs/bc.lua` decodes bc4, bc5 and bc7 mode 6 on the cpu. `test/tests/render/texture_compress.lua` uploads the encoded dds as a real texture and compares the gpu's block decoder with the cpu decode, so the bit packing is checked against the hardware, not only against our own decoder. Measure quality as psnr against the source.
