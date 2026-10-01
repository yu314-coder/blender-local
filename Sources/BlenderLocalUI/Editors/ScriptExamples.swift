import Foundation

/// Ready-to-run scripts for the Text Editor's Examples menu.
///
/// The Scripting tab opened onto a blank-ish buffer and a Run button, which
/// tells you nothing about what bpy can do from here. These do: each one is
/// short enough to read in one screen and produces something visible in the
/// viewport the moment it runs.
///
/// All but the last use only primitives, transforms, materials and modifiers,
/// so they behave the same under the bundled shim as under the real module.
enum ScriptExample: String, CaseIterable, Identifiable {
    case starter        = "Starter"
    case spiralTower    = "Spiral Tower"
    case waveGrid       = "Wave Grid"
    case modifierStack  = "Modifier Stack"
    case bike           = "Procedural Bike"

    var id: String { rawValue }

    /// Marked for the ones that need the real module: the shim has no curves,
    /// no join and no node-based materials, so saying so up front beats a
    /// traceback.
    var needsRealBpy: Bool { self == .bike }

    var source: String {
        switch self {
        case .starter:       return Self.starterSource
        case .spiralTower:   return Self.spiralSource
        case .waveGrid:      return Self.waveSource
        case .modifierStack: return Self.modifierSource
        case .bike:          return Self.bikeSource
        }
    }

    private static let clear = """
    import bpy
    import math

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)
    """

    static let starterSource = """
    import bpy

    # Everything here also happens when you use the Tools tab —
    # switch to it and watch the viewport update.

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

    bpy.ops.mesh.primitive_uv_sphere_add(radius=1.0, location=(0.0, 0.0, 1.0))
    bpy.ops.mesh.primitive_cube_add(size=2.0, location=(2.5, 0.0, 0.0))
    bpy.ops.mesh.primitive_torus_add(location=(-2.5, 0.0, 0.5))

    print("scene rebuilt")
    """

    private static let spiralSource = clear + """


    # A helix of cubes. Each one is turned a little further round than the
    # last, so the stack reads as a twist rather than a column.
    STEPS = 28
    RADIUS = 2.2
    RISE = 0.22

    for i in range(STEPS):
        t = i / STEPS * math.tau * 1.5
        bpy.ops.mesh.primitive_cube_add(
            size=0.7,
            location=(math.cos(t) * RADIUS, math.sin(t) * RADIUS, i * RISE))
        cube = bpy.context.object
        cube.name = "Step%02d" % i
        cube.rotation_euler = (0.0, 0.0, t)
        cube.scale = (1.0, 0.45, 0.16)
        # Hue sweeps from warm at the base to cool at the top.
        f = i / STEPS
        cube.color = (1.0 - f * 0.7, 0.35 + f * 0.4, 0.25 + f * 0.7, 1.0)

    print("tower:", STEPS, "steps,", round(STEPS * RISE, 2), "m tall")
    """

    private static let waveSource = clear + """


    # A height field. The grid is built by hand rather than displaced, so the
    # maths that positions each sphere is right there to change.
    N = 11
    SPACING = 0.62
    AMPLITUDE = 1.1

    for ix in range(N):
        for iy in range(N):
            x = (ix - (N - 1) / 2) * SPACING
            y = (iy - (N - 1) / 2) * SPACING
            z = math.sin(x * 1.5) * math.cos(y * 1.5) * AMPLITUDE
            bpy.ops.mesh.primitive_uv_sphere_add(radius=0.2, location=(x, y, z))
            ball = bpy.context.object
            ball.name = "Wave_%d_%d" % (ix, iy)
            # Colour by height, so the surface is readable without shading.
            h = (z / AMPLITUDE + 1) / 2
            ball.color = (0.15 + h * 0.85, 0.35, 1.0 - h * 0.75, 1.0)

    print("wave grid:", N * N, "spheres")
    """

    private static let modifierSource = clear + """


    # Modifiers are non-destructive: the cage stays low-poly and the stack does
    # the rest. Change the levels and run again to feel the difference.
    bpy.ops.mesh.primitive_monkey_add(size=2.0, location=(0.0, 0.0, 0.6))
    suzanne = bpy.context.object
    bpy.ops.object.modifier_add(type='SUBSURF')
    suzanne.modifiers["Subdivision"].levels = 2
    suzanne.color = (0.85, 0.45, 0.25, 1.0)

    # An arrayed, subdivided pillar beside it.
    bpy.ops.mesh.primitive_cube_add(size=0.8, location=(3.0, 0.0, 0.4))
    pillar = bpy.context.object
    bpy.ops.object.modifier_add(type='ARRAY')
    pillar.modifiers["Array"].count = 6
    bpy.ops.object.modifier_add(type='SUBSURF')
    pillar.modifiers["Subdivision"].levels = 1
    pillar.color = (0.3, 0.6, 0.9, 1.0)

    for obj in (suzanne, pillar):
        print(obj.name, "->", [m.type for m in obj.modifiers])
    """

    /// The full parametric bicycle from `examples/bike.py`, kept short enough
    /// to read here. Needs the real module: curves, `join` and node materials
    /// are all outside the shim.
    private static let bikeSource = """
    # Needs the real bpy module — runs on device, not in the simulator.
    # The full version lives in examples/bike.py.
    import bpy, math
    from mathutils import Vector

    WHEEL_R, SPOKES, WHEELBASE = 0.34, 24, 1.02

    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete(use_global=False)

    def material(name, rgba, metallic=0.0, roughness=0.5):
        mat = bpy.data.materials.new(name)
        if bpy.app.version < (4, 0, 0):
            mat.use_nodes = True
        b = mat.node_tree.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = rgba
        b.inputs["Metallic"].default_value = metallic
        b.inputs["Roughness"].default_value = roughness
        return mat

    steel = material("Steel", (0.62, 0.64, 0.68, 1), 1.0, 0.25)
    paint = material("Paint", (0.80, 0.28, 0.24, 1), 0.1, 0.35)
    rubber = material("Rubber", (0.05, 0.05, 0.06, 1), 0.0, 0.85)

    def tube(a, b, r, name, mat):
        a, b = Vector(a), Vector(b)
        d = b - a
        bpy.ops.mesh.primitive_cylinder_add(radius=r, depth=d.length,
                                            location=(a + b) / 2, vertices=16)
        o = bpy.context.object
        o.name = name
        o.rotation_mode = 'QUATERNION'
        o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d)
        o.data.materials.append(mat)
        return o

    def wheel(x, name):
        bpy.ops.mesh.primitive_torus_add(location=(x, 0, WHEEL_R),
                                         major_radius=WHEEL_R, minor_radius=0.035,
                                         rotation=(0, math.pi / 2, 0))
        tyre = bpy.context.object
        tyre.name = name
        tyre.data.materials.append(rubber)
        parts = [tyre]
        for i in range(SPOKES):
            t = i / SPOKES * math.tau
            side = 0.02 if i % 2 else -0.02
            parts.append(tube((x + side, 0, WHEEL_R),
                              (x, math.cos(t) * WHEEL_R * 0.93,
                               WHEEL_R + math.sin(t) * WHEEL_R * 0.93),
                              0.004, name + "_Spoke%d" % i, steel))
        bpy.ops.object.select_all(action='DESELECT')
        for p in parts:
            p.select_set(True)
        bpy.context.view_layer.objects.active = tyre
        bpy.ops.object.join()
        return tyre

    rear = wheel(-WHEELBASE / 2, "WheelRear")
    front = wheel(WHEELBASE / 2, "WheelFront")

    bb = (-0.06, 0, 0.28)
    seat = (-0.30, 0, 0.86)
    head = (0.40, 0, 0.80)
    tube(bb, seat, 0.016, "SeatTube", paint)
    tube(bb, head, 0.017, "DownTube", paint)
    tube(seat, head, 0.016, "TopTube", paint)
    tube(bb, (-WHEELBASE / 2, 0, WHEEL_R), 0.014, "ChainStay", paint)
    tube(seat, (-WHEELBASE / 2, 0, WHEEL_R), 0.013, "SeatStay", paint)
    tube(head, (WHEELBASE / 2, 0, WHEEL_R), 0.016, "Fork", paint)
    tube((head[0], -0.21, head[2] + 0.06), (head[0], 0.21, head[2] + 0.06),
         0.012, "Handlebar", steel)

    print("Bike built:", len(bpy.data.objects), "objects")
    """
}
