import Foundation
import simd

/// The simulator's approximation of six of Blender's sculpt brushes, reduced to
/// direct operations on vertex positions.
///
/// Only the simulator's stand-in for Blender uses these: with the real
/// Blender, Sculpt Mode strokes Blender's own Essentials brushes
/// (`_blenderkit_sculpt`, `SculptBpy`), and the Sculpt menu labels these as an
/// approximation where they are offered.
///
/// Blender's sculpt mode rebuilds topology as you work (dynamic topology,
/// multires) so detail appears where you add it. Nothing here adds geometry —
/// these move the vertices a mesh already has, so sculpting a coarse mesh gives
/// coarse results. Subdivide first, as you would in Blender before sculpting.
public enum SculptBrush: String, CaseIterable, Identifiable, Sendable {
    case draw, inflate, smooth, flatten, grab, pinch

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .draw:    return "Draw"
        case .inflate: return "Inflate"
        case .smooth:  return "Smooth"
        case .flatten: return "Flatten"
        case .grab:    return "Grab"
        case .pinch:   return "Pinch"
        }
    }

    public var icon: String {
        switch self {
        case .draw:    return "paintbrush.pointed"
        case .inflate: return "arrow.up.left.and.arrow.down.right.circle"
        case .smooth:  return "drop"
        case .flatten: return "square.bottomhalf.filled"
        case .grab:    return "hand.point.up.left"
        case .pinch:   return "arrow.down.right.and.arrow.up.left"
        }
    }

    /// Blender's brush names, so the Info log reads like a real script.
    public var bpyName: String { rawValue.capitalized }
}

/// Applies a brush stroke to a mesh.
public enum SculptEngine {

    /// Blender's brush falloff: full strength at the centre, easing to nothing
    /// at the radius. This is the smooth curve, Blender's default.
    static func falloff(_ distance: Float, radius: Float) -> Float {
        guard distance < radius, radius > 0 else { return 0 }
        let t = distance / radius
        // Smoothstep, so the edge of the stroke blends rather than steps.
        return 1 - (t * t * (3 - 2 * t))
    }

    /// One dab of the brush, centred on a point in the object's local space.
    ///
    /// `direction` is the surface normal at the stroke centre, which is what
    /// Draw pushes along — Blender's Draw brush moves along the *stroke's*
    /// normal, not each vertex's own, so a stroke across a curved surface
    /// stays coherent instead of splaying.
    public static func stroke(_ mesh: MeshData,
                              at centre: SIMD3<Float>,
                              direction: SIMD3<Float>,
                              brush: SculptBrush,
                              radius: Float,
                              strength: Float,
                              grabDelta: SIMD3<Float> = .zero) -> MeshData {
        var result = mesh
        var touched = false

        // Flatten needs the average height of what is under the brush first.
        var planePoint = SIMD3<Float>.zero
        if brush == .flatten {
            var sum = SIMD3<Float>.zero
            var count: Float = 0
            for v in mesh.vertices {
                let w = falloff(distance(v.position, centre), radius: radius)
                if w > 0 { sum += v.position; count += 1 }
            }
            guard count > 0 else { return mesh }
            planePoint = sum / count
        }

        for i in result.vertices.indices {
            let p = result.vertices[i].position
            let w = falloff(distance(p, centre), radius: radius)
            guard w > 0 else { continue }
            touched = true
            let amount = w * strength

            switch brush {
            case .draw:
                result.vertices[i].position += direction * amount * radius * 0.5
            case .inflate:
                result.vertices[i].position += result.vertices[i].normal * amount * radius * 0.5
            case .grab:
                result.vertices[i].position += grabDelta * amount
            case .pinch:
                // Pull toward the stroke centre, along the surface.
                let toCentre = centre - p
                result.vertices[i].position += toCentre * amount * 0.5
            case .flatten:
                let offset = dot(p - planePoint, direction)
                result.vertices[i].position -= direction * offset * amount
            case .smooth:
                break   // handled below: it needs neighbour positions
            }
        }

        if brush == .smooth {
            result = smoothUnderBrush(result, centre: centre,
                                      radius: radius, strength: strength)
            touched = true
        }

        guard touched else { return mesh }
        ModifierStack.recomputeNormals(&result, welded: true)
        return result
    }

    /// Relaxes vertices toward their neighbours, weighted by the brush falloff,
    /// so the effect fades at the edge of the stroke instead of leaving a seam.
    private static func smoothUnderBrush(_ mesh: MeshData, centre: SIMD3<Float>,
                                         radius: Float, strength: Float) -> MeshData {
        var sums = [SIMD3<Float>](repeating: .zero, count: mesh.vertices.count)
        var counts = [Float](repeating: 0, count: mesh.vertices.count)

        var e = 0
        while e + 1 < mesh.edges.count {
            let a = Int(mesh.edges[e]), b = Int(mesh.edges[e + 1])
            sums[a] += mesh.vertices[b].position; counts[a] += 1
            sums[b] += mesh.vertices[a].position; counts[b] += 1
            e += 2
        }

        var result = mesh
        for i in result.vertices.indices where counts[i] > 0 {
            let p = result.vertices[i].position
            let w = falloff(distance(p, centre), radius: radius)
            guard w > 0 else { continue }
            let average = sums[i] / counts[i]
            result.vertices[i].position = p + (average - p) * w * strength
        }
        return result
    }
}

public extension BKObject {
    /// Why the stand-in brushes above may not touch this object, or nil when
    /// they may.
    ///
    /// They may not touch Blender's evaluated mesh, which is what every mesh
    /// on screen is on a device (`setEvaluatedMesh`). There the only brush is
    /// Blender's own, streamed through `SculptStrokeInput` from a 3D View that
    /// has the bridge; a 3D View without one (the Shading, UV Editing,
    /// Scripting and Geometry Nodes tabs) fell through to the stand-in, which
    /// changed a picture Blender never held and, through `setMirroredMesh`,
    /// ran the mirrored modifier stack over Blender's result on every dab. A
    /// cube with a Subdivision grew 54 → 150 → 486 → … → 1,579,014 vertices
    /// over 8 dabs (round 3's review, swiftc -O; tests/sculpt/main.swift
    /// repeats it on the old install).
    var standInSculptRefusal: String? {
        meshIsEvaluated
            ? "This 3D View cannot reach Blender's sculpt brushes. Sculpt in the Sculpting tab."
            : nil
    }

    /// One dab of the simulator's stand-in brush: `dab` runs over the mesh the
    /// modifier stack runs over (`editCage`, the base once the object has a
    /// stack) and the result is installed once (`installTransformed`), so the
    /// stack runs over it once, as Blender evaluates its modifiers over the
    /// mesh a brush moved. Returns the refusal, having changed nothing, or nil.
    @discardableResult
    func sculptStandIn(_ dab: (MeshData) -> MeshData) -> String? {
        if let refusal = standInSculptRefusal { return refusal }
        installTransformed(dab(editCage))
        return nil
    }
}

/// Sculpt-mode settings, mirroring Blender's brush header.
public struct SculptSettings: Sendable {
    public var brush: SculptBrush = .draw
    /// Blender's radius is in pixels; this is in world units, which is what a
    /// touch maps onto without a pressure-sensitive pixel radius.
    public var radius: Float = 0.5
    public var strength: Float = 0.5
    /// Blender's Ctrl-invert: Draw digs instead of raising.
    public var invert = false
    public init() {}
}
