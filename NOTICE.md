# What the licence covers

This repository's own code is MIT-licensed (`LICENSE`): `Sources/`,
`Resources/`, `scripts/`, `tests/` and `docs/`, except for the third-party
files listed below.

It does NOT cover Blender's `bpy`, which builds of this app may bundle from
[python-ios-lib](https://github.com/yu314-coder/python-ios-lib). Blender is
copyright the Blender Foundation and its contributors and is licensed
GPL-2.0-or-later; that licence governs it and any binary that includes it,
regardless of who compiled it.

Third-party files in this repository, each under its own licence:

- `Resources/BlenderAssets/`: Blender 5.2.1's Essentials mesh-sculpt brushes,
  unchanged, under Blender's CC0 licence for its bundled assets
  (`Resources/BlenderAssets/LICENSE`).
- `Resources/Models/DepthAnythingV2SmallF16.mlpackage`: Apple's Core ML
  conversion of Depth Anything V2 Small, under the Apache License 2.0
  (`Resources/Models/NOTICE.md`).
