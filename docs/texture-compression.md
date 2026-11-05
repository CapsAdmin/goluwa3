# Texture compression

`goluwa/render/texture_compress.lua` encodes an r8g8b8a8 image into block compressed mips on the gpu and returns a dds file (dx10 header, `dds.Encode`) as a string. The engine already loads those (`dds.DecodeBuffer`, `Texture:UploadCompressed`), so nothing else is needed to use the result. It needs the gpu device, so it only runs in the `--2d`/`--3d` engine, not `--cli`.

`texture_compress.Compress{pixels, width, height, format, kind, mips, wrap, channel}`

- `format`: `bc7` (rgba), `bc5` (red and green, for normal maps: the shader rebuilds z), `bc4` (one channel, `channel` 0 to 3).
- `kind` picks the mip filter: `srgb` averages in linear light (and marks the dds `BC7_UNORM_SRGB`), `normal` averages the decoded vectors and renormalizes, `linear` is a plain average. `wrap` makes the filter wrap around for tiling textures. `mips = false` writes one level.
- Mips are built on the gpu too: float buffers per level, then one encode dispatch per level.

`texture_compress.Recompress{sources, edit, params, ...the rest as Compress}` modifies compressed textures without leaving the gpu: each source (a dds string, or `{pixels, width, height}`) is decoded by the gpu's own block decoder by sampling it in a compute shader, the `edit` glsl runs per texel, and the result goes straight into the same mip and encode stage, so nothing is decoded in Lua and no float conversion loop runs on the cpu. `edit` defines `vec4 edit(ivec2 position, ivec2 size, vec4 texel)` where `texel` is the first source's raw value (encoded, not linear: an srgb format is read as its unorm twin, use `to_linear`/`from_linear` for light math; a bc5 source has no blue). `fetch(index, position)` and `source_size(index)` reach the other sources (up to four, the output is the size of the first), and `edit_params[i]` holds up to 16 floats from `params`. Pipelines are cached per edit text, so a batch with the same edit compiles once. Every re-encode of bc7 is lossy: re-encoding an unedited bc7 texture stays above 42 dB against the original, but repeated edits should start again from the lossless source and encode once.

Measured on 20 stored textures (7.5 MP, mixed bc7 and bc5): `Compress` after a Lua decode took 85 ms each; `Recompress` takes 18 ms each (21 MP/s), 24 ms with an edit. A 1024x1024 bc7 with a full mip chain is 32 ms, 22 ms for level 0 only.

How it works: buffers in, buffers out. The level is a host visible float storage buffer, a compute shader with one invocation per block fits endpoints and writes the block into a storage buffer, and the result is read back. bc4/bc5 use min/max endpoints refined by least squares. bc7 is mode 6 only (one subset, 7 bit rgba endpoints with a p bit each, 4 bit indices): the axis is the principal component of the block, endpoints are refined by least squares over the real index weights, quantized with the p bit chosen by error (alpha weighted so an opaque block stays exactly 255), indices are searched against the quantized endpoints, and the anchor index is kept below 8 by swapping the endpoints. Blocks of two distinct colors that do not lie on one line are where the other modes (two or three subsets, which need the 64 entry partition tables) would help. If that tier is ever built, the partition tables can be read off the gpu's own decoder instead of typed in.

Verification: `bc.lua` decodes bc4, bc5 and bc7 mode 6 on the cpu, and the test `test/tests/render/texture_compress.lua` uploads the encoded dds as a real texture and compares what the gpu's block decoder returns with the cpu decode (within 1), so the bit packing is checked against the hardware, not only against our own decoder. Measured: 512x512 real textures with a full mip chain take 40 to 80 ms; bc7 albedo came out at 51 to 52 dB psnr and bc5 normals at 47 dB; a 512x512 texture with mips is 342 KB.

Pitfalls:
- dds data is read in buffer order, top row first like a vtf, so (unlike png, which the engine's codec flips) a dds renders correctly on Source geometry as written.
- `bc.Decode` leaves the channels a format does not have at zero (bc4 fills red, bc5 red and green).
- A `config.srgb` texture load turns `_unorm` into `_srgb` by itself, so the format name in the dds does not decide the color space on load.

bc7 mode 6 has one p bit per endpoint shared by all four channels, so values of different parity in one block (a metallic 0 next to an ambient occlusion or alpha of 255) cannot both be exact: one channel is off by one. It is inherent to the mode, not an encoder bug.
