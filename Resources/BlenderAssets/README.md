# Blender's Essentials brushes

`brushes/essentials_brushes-mesh_sculpt.blend`, `essentials_brushes-mesh_vertex.blend`,
`essentials_brushes-mesh_weight.blend`, `blender_assets.cats.txt` and `LICENSE`
are Blender 5.2.1 LTS's `datafiles/assets` files, unchanged, under Blender's
CC0 licence for its bundled assets (LICENSE).

The bpy staged into the app has no `datafiles/assets` (its datafiles are
colormanagement, fonts, icons and locale), so Sculpt Mode, Vertex Paint and
Weight Paint had no brush at all: `brush.asset_activate` and Blender's default
brushes load from these files. `scripts/stage-blender.sh` copies them into
`bpy/<version>/datafiles/assets` on every device build, where
`bpy.utils.system_resource('DATAFILES', path='assets/brushes')` finds them.
Texture Paint here is the app's own, and the other Essentials files are not
used.
