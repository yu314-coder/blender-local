# Blender's Essentials sculpt brushes

`brushes/essentials_brushes-mesh_sculpt.blend`, `blender_assets.cats.txt` and
`LICENSE` are Blender 5.2.1 LTS's `datafiles/assets` files, unchanged, under
Blender's CC0 licence for its bundled assets (LICENSE).

The bpy staged into the app has no `datafiles/assets` (its datafiles are
colormanagement, fonts, icons and locale), so Sculpt Mode had no brush at all:
`brush.asset_activate` and Blender's default brush both load from this file.
`scripts/stage-blender.sh` copies it into `bpy/<version>/datafiles/assets` on
every device build, where `bpy.utils.system_resource('DATAFILES',
path='assets/brushes')` finds it. Only the mesh-sculpt file is shipped: the
paint modes here are the app's own, and the other Essentials files are not used.
