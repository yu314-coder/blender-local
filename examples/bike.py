"""A procedural bicycle, built entirely from code.

Everything is parametric: change WHEEL_R or FRAME_TUBE at the top and the whole
bike rebuilds around it. No mesh is hand-modelled — the spokes are a radial
loop, the chain is an array along a curve, and the frame is a set of tubes
generated between named points.

Run in Blender's Scripting workspace, or `blender --python bike.py`.
"""

import bpy
import math
from mathutils import Vector

# ---------------------------------------------------------------- parameters
WHEEL_R      = 0.34      # wheel radius, metres (roughly a 700c)
TYRE_R       = 0.028     # tyre cross-section
RIM_R        = 0.012
SPOKE_COUNT  = 24
SPOKE_R      = 0.0022
HUB_R        = 0.028
FRAME_TUBE   = 0.017     # frame tube radius
WHEELBASE    = 1.02      # front axle to rear axle


def clear_scene():
    """Start from an empty file, including orphaned meshes and materials."""
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.curves):
        for item in list(block):
            if item.users == 0:
                block.remove(item)


def material(name, colour, metallic=0.0, roughness=0.4):
    """A Principled BSDF material, reused if it already exists."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        # Materials are node-based by default from Blender 4.x; use_nodes is
        # deprecated and goes away in 6.0, so only set it on older versions.
        if bpy.app.version < (4, 0, 0):
            mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*colour, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def assign(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    return obj


def tube(start, end, radius, name, mat=None):
    """A cylinder spanning two points — the workhorse for the frame.

    Blender's cylinder is created along +Z, so it is rotated onto the vector
    between the points using the direction's rotation_difference.
    """
    start, end = Vector(start), Vector(end)
    span = end - start
    bpy.ops.mesh.primitive_cylinder_add(
        radius=radius, depth=span.length, location=start + span / 2, vertices=16)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_mode = 'QUATERNION'
    obj.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(span.normalized())
    bpy.ops.object.shade_smooth()
    if mat:
        assign(obj, mat)
    return obj


def wheel(centre, name, rubber, metal):
    """Tyre, rim, hub and a radial fan of spokes, joined into one object."""
    cx, cy, cz = centre
    parts = []

    bpy.ops.mesh.primitive_torus_add(
        location=centre, major_radius=WHEEL_R, minor_radius=TYRE_R,
        major_segments=64, minor_segments=16,
        rotation=(math.pi / 2, 0, 0))
    tyre = bpy.context.object
    tyre.name = f"{name}_Tyre"
    assign(tyre, rubber)
    parts.append(tyre)

    bpy.ops.mesh.primitive_torus_add(
        location=centre, major_radius=WHEEL_R - TYRE_R, minor_radius=RIM_R,
        major_segments=64, minor_segments=12,
        rotation=(math.pi / 2, 0, 0))
    rim = bpy.context.object
    rim.name = f"{name}_Rim"
    assign(rim, metal)
    parts.append(rim)

    bpy.ops.mesh.primitive_cylinder_add(
        radius=HUB_R, depth=0.09, location=centre,
        rotation=(0, math.pi / 2, 0), vertices=24)
    hub = bpy.context.object
    hub.name = f"{name}_Hub"
    bpy.ops.object.shade_smooth()
    assign(hub, metal)
    parts.append(hub)

    # Spokes alternate which side of the hub they leave from, as real ones do.
    for i in range(SPOKE_COUNT):
        angle = (i / SPOKE_COUNT) * math.tau
        rim_pt = (cx + math.cos(angle) * (WHEEL_R - TYRE_R),
                  cy + (0.014 if i % 2 else -0.014),
                  cz + math.sin(angle) * (WHEEL_R - TYRE_R))
        hub_pt = (cx + math.cos(angle + 0.55) * HUB_R,
                  cy + (0.03 if i % 2 else -0.03),
                  cz + math.sin(angle + 0.55) * HUB_R)
        parts.append(tube(hub_pt, rim_pt, SPOKE_R, f"{name}_Spoke{i:02d}", metal))

    # Join everything into a single wheel object.
    bpy.ops.object.select_all(action='DESELECT')
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = tyre
    bpy.ops.object.join()
    tyre.name = name
    return tyre


def chain(front, r_front, rear, r_rear, mat):
    """Links arrayed along a curve — Blender's Array + Curve modifier pair,
    which is how you follow a path with repeated geometry.

    The path is the real belt shape: the two external tangent lines plus the
    arc each cog actually wraps, so the chain sits *on* the teeth instead of
    cutting through them."""
    # External tangent geometry for two circles in the XZ plane.
    dx, dz = rear[0] - front[0], rear[2] - front[2]
    span = math.hypot(dx, dz)
    alpha = math.atan2(dz, dx)
    beta = math.acos(max(-1.0, min(1.0, (r_front - r_rear) / span)))

    def on(centre, radius, ang):
        return (centre[0] + radius * math.cos(ang), centre[1],
                centre[2] + radius * math.sin(ang))

    # Clockwise around the hull: wrap the rear cog on its far side, run the
    # lower tangent forward, wrap the chainring, run the upper tangent back.
    pts = []
    for i in range(13):                       # rear cog, +beta down to -beta
        pts.append(on(rear, r_rear, alpha + beta - 2 * beta * i / 12))
    for i in range(25):                       # chainring, -beta down to beta-2pi
        pts.append(on(front, r_front,
                      alpha - beta - (2 * math.pi - 2 * beta) * i / 24))

    curve_data = bpy.data.curves.new("ChainPath", type='CURVE')
    curve_data.dimensions = '3D'
    spline = curve_data.splines.new('POLY')
    spline.points.add(len(pts) - 1)
    for p, (x, y, z) in zip(spline.points, pts):
        p.co = (x, y, z, 1)
    spline.use_cyclic_u = True
    path = bpy.data.objects.new("ChainPath", curve_data)
    bpy.context.collection.objects.link(path)

    # The link has to sit ON the curve object's origin: a Curve modifier reads
    # any offset from that origin as sideways displacement, so a link parked
    # off to one side flings the whole chain that far off the path.
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, 0, 0))
    link = bpy.context.object
    link.name = "Chain"
    link.scale = (0.022, 0.006, 0.011)
    bpy.ops.object.transform_apply(scale=True)

    arr = link.modifiers.new("Array", 'ARRAY')
    arr.fit_type = 'FIT_CURVE'
    arr.curve = path
    arr.relative_offset_displace[0] = 1.15

    fit = link.modifiers.new("Follow", 'CURVE')
    fit.object = path
    fit.deform_axis = 'POS_X'
    assign(link, mat)
    return link, path


def build():
    clear_scene()

    steel  = material("Steel",  (0.62, 0.64, 0.68), metallic=1.0, roughness=0.22)
    paint  = material("Paint",  (0.86, 0.18, 0.12), metallic=0.35, roughness=0.25)
    rubber = material("Rubber", (0.035, 0.035, 0.04), metallic=0.0, roughness=0.85)
    saddle = material("Saddle", (0.06, 0.05, 0.05), metallic=0.0, roughness=0.55)

    rear_axle  = (-WHEELBASE / 2, 0, WHEEL_R)
    front_axle = ( WHEELBASE / 2, 0, WHEEL_R)

    wheel(rear_axle,  "WheelRear",  rubber, steel)
    wheel(front_axle, "WheelFront", rubber, steel)

    # Frame geometry: the classic diamond, defined by five points.
    bb     = (-0.10, 0, WHEEL_R - 0.06)          # bottom bracket (crank axis)
    seat_t = (-0.26, 0, WHEEL_R + 0.46)          # top of seat tube
    head_t = ( 0.34, 0, WHEEL_R + 0.42)          # top of head tube
    head_b = ( 0.40, 0, WHEEL_R + 0.16)          # bottom of head tube

    for a, b, nm in [
        (bb, seat_t,     "SeatTube"),
        (seat_t, head_t, "TopTube"),
        (bb, head_b,     "DownTube"),
        (head_t, head_b, "HeadTube"),
        (bb, rear_axle,  "ChainStay"),
        (seat_t, rear_axle, "SeatStay"),
    ]:
        tube(a, b, FRAME_TUBE, nm, paint)

    # Fork: two blades from the head tube down to the front axle.
    for side in (-0.045, 0.045):
        tube(head_b, (front_axle[0], side, front_axle[2]), FRAME_TUBE * 0.8,
             f"Fork{'L' if side < 0 else 'R'}", steel)

    # Handlebars and stem.
    stem_top = (head_t[0] - 0.02, 0, head_t[2] + 0.09)
    tube(head_t, stem_top, FRAME_TUBE * 0.75, "Stem", steel)
    tube((stem_top[0], -0.21, stem_top[2]), (stem_top[0], 0.21, stem_top[2]),
         FRAME_TUBE * 0.7, "Handlebar", steel)
    for side in (-0.21, 0.21):
        tube((stem_top[0], side, stem_top[2]),
             (stem_top[0] + 0.10, side, stem_top[2] - 0.02),
             FRAME_TUBE * 0.72, f"Grip{'L' if side < 0 else 'R'}", rubber)

    # Seat post and saddle.
    post_top = (seat_t[0] - 0.02, 0, seat_t[2] + 0.13)
    tube(seat_t, post_top, FRAME_TUBE * 0.7, "SeatPost", steel)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.1, location=post_top)
    seat = bpy.context.object
    seat.name = "Saddle"
    seat.scale = (1.25, 0.42, 0.22)
    bpy.ops.object.transform_apply(scale=True)
    bpy.ops.object.shade_smooth()
    assign(seat, saddle)

    # Chainring, cranks and pedals.
    bpy.ops.mesh.primitive_cylinder_add(radius=0.105, depth=0.006,
                                        location=(bb[0], 0.045, bb[2]),
                                        rotation=(0, math.pi / 2, 0), vertices=48)
    ring = bpy.context.object
    ring.name = "Chainring"
    bpy.ops.object.shade_smooth()
    assign(ring, steel)

    for side, angle in ((0.075, 0.0), (-0.075, math.pi)):
        end = (bb[0] + math.cos(angle) * 0.17, side, bb[2] + math.sin(angle) * 0.17)
        tube((bb[0], side, bb[2]), end, 0.010, f"Crank{'R' if side > 0 else 'L'}", steel)
        bpy.ops.mesh.primitive_cube_add(size=1, location=(end[0], end[1] + 0.03 * (1 if side > 0 else -1), end[2]))
        pedal = bpy.context.object
        pedal.name = f"Pedal{'R' if side > 0 else 'L'}"
        pedal.scale = (0.075, 0.05, 0.012)
        bpy.ops.object.transform_apply(scale=True)
        assign(pedal, rubber)

    # Rear sprocket, then the chain looping between the two.
    bpy.ops.mesh.primitive_cylinder_add(radius=0.048, depth=0.006,
                                        location=(rear_axle[0], 0.045, rear_axle[2]),
                                        rotation=(0, math.pi / 2, 0), vertices=32)
    cog = bpy.context.object
    cog.name = "Sprocket"
    bpy.ops.object.shade_smooth()
    assign(cog, steel)

    chain((bb[0], 0.045, bb[2]), 0.105,
          (rear_axle[0], 0.045, rear_axle[2]), 0.048, steel)

    print(f"Bike built: {len(bpy.data.objects)} objects, "
          f"{sum(len(o.data.vertices) for o in bpy.data.objects if o.type == 'MESH')} vertices")


build()
