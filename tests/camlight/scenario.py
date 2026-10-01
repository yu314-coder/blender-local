# One script, run by a headless Blender 5.2.1 (tests/camlight/blender/verify.py)
# and by the simulator's shim (tests/camlight/shim/main.py). What the mirror
# hands the viewport for it has to be the same in both, or the simulator shows
# a different scene from the iPad.
#
# Only what a script can do in either: add, set data and object properties,
# rename, hide, choose the scene camera and the render size.

bpy.ops.object.camera_add(location=(1.0, 2.0, 3.0), rotation=(1.1, 0.0, 0.8))
camera = bpy.context.object
camera.data.lens = 35.0
camera.data.sensor_fit = 'VERTICAL'
camera.data.shift_x = 0.1
camera.data.display_size = 2.0
camera.data.show_limits = True
camera.data.dof.focus_distance = 7.5
bpy.context.scene.camera = camera

bpy.ops.object.camera_add(location=(-2.0, 0.0, 1.0))
ortho = bpy.context.object
ortho.data.type = 'ORTHO'
ortho.data.ortho_scale = 4.0
ortho.data.clip_start = 0.5
ortho.data.clip_end = 250.0
ortho.name = "Ortho"

bpy.context.scene.render.resolution_x = 1080
bpy.context.scene.render.resolution_y = 1920
bpy.context.scene.render.pixel_aspect_x = 2.0

for index, kind in enumerate(('POINT', 'SUN', 'SPOT', 'AREA')):
    bpy.ops.object.light_add(type=kind, radius=0.5, location=(index * 2.0, -3.0, 4.0))

spot = bpy.data.objects['Spot'].data
spot.spot_size = 1.2
spot.spot_blend = 0.4
spot.show_cone = True
spot.shadow_soft_size = 0.25
spot.color = (1.0, 0.5, 0.25)
spot.energy = 250.0
area = bpy.data.objects['Area'].data
area.shape = 'RECTANGLE'
area.size_y = 0.75
point = bpy.data.objects['Point'].data
point.shadow_soft_size = 0.3
point.cutoff_distance = 12.0
point.shadow_buffer_clip_start = 0.2
bpy.data.objects['Sun'].hide_viewport = True

for index, kind in enumerate(('PLAIN_AXES', 'ARROWS', 'SINGLE_ARROW', 'CIRCLE', 'CUBE', 'SPHERE', 'CONE')):
    bpy.ops.object.empty_add(type=kind, radius=0.5 + index * 0.25, location=(0.0, index * 1.5, 0.0))
bpy.data.objects['Empty.003'].empty_display_size = 3.0

loose = bpy.data.objects.new("Loose Empty", None)
bpy.context.collection.objects.link(loose)
made = bpy.data.lights.new("Made Light", 'SPOT')
holder = bpy.data.objects.new("Made Light", made)
bpy.context.collection.objects.link(holder)
