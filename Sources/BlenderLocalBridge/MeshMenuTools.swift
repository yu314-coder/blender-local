import Foundation
import simd

/// Where Blender's pointer would be for the Mesh menu's rows that act at it,
/// when a finger has no pointer to hover: over the 3D cursor, in the app's own
/// view. Blender's Extrude to Cursor or Add (Ctrl+right click) and Rip
/// Vertices and Extend (Alt+D) read the mouse from a window's event, which a
/// Blender with no window has none of (round 3's review measured both
/// changing nothing under the borrowed 3D View); the app hands Blender the
/// eye, the line of sight and the up the 3D View is drawn with, and
/// `_blenderkit_meshmenu` reads Blender's own 3D cursor when the row runs.
public struct MeshPointer: Sendable, Equatable {
    public var eye: SIMD3<Float>
    public var forward: SIMD3<Float>
    public var up: SIMD3<Float>
    public var orthographic: Bool
    /// The 3D cursor as the mirror holds it: Point to Target…'s Target
    /// starts here. The rows that act at the pointer read Blender's own.
    public var cursor: SIMD3<Float>

    public init(eye: SIMD3<Float>, forward: SIMD3<Float>, up: SIMD3<Float>, orthographic: Bool,
                cursor: SIMD3<Float>) {
        self.eye = eye; self.forward = forward; self.up = up
        self.orthographic = orthographic; self.cursor = cursor
    }

    /// A view from the front, 10 m out, onto a cursor at the origin: the
    /// catalogue's stand-in when no view is given (tests only).
    public static let front = MeshPointer(eye: SIMD3(0, -10, 0), forward: SIMD3(0, 1, 0), up: SIMD3(0, 0, 1),
                                          orthographic: false, cursor: .zero)

    /// `eye=(…), forward=(…), [up=(…), ]ortho=…`, as `_blenderkit_meshmenu`
    /// takes them. Six places: the line of sight through a cursor 100 m away
    /// moves 1e-4 m for a 1e-6 change in the direction.
    func pythonArguments(up withUp: Bool = true) -> String {
        func v(_ p: SIMD3<Float>) -> String {
            "(" + [p.x, p.y, p.z].map { LastOperator.number(Double($0), places: 6) }.joined(separator: ", ") + ")"
        }
        return "eye=\(v(eye)), forward=\(v(forward))" + (withUp ? ", up=\(v(up))" : "")
            + ", ortho=\(orthographic ? "True" : "False")"
    }
}

/// Mesh ▸ Vertex ▸ Extrude to Cursor or Add, and the two rows of that menu
/// Blender cannot run without a pointer.
public enum MeshMenuTools {

    /// The row's label and its operator's name, which is the undo step's
    /// name too (5.2.1: `mesh.dupli_extrude_cursor`'s RNA name; the Vertex
    /// menu's row is drawn by the operator's own name).
    public static let extrudeToCursor = "Extrude to Cursor or Add"

    /// Blender's operator has an invoke and no exec, so Blender shows no redo
    /// panel for it (the panel only appears for an operator it can run again,
    /// `WM_operator_repeat_check`), and neither does the app: it is run once,
    /// with Rotate Source on as Blender's Vertex menu calls it
    /// (`layout.operator("mesh.dupli_extrude_cursor").rotate_source = True`).
    /// The pointer is over the 3D cursor (`MeshPointer`); with nothing
    /// selected it adds a vertex there. The Info log carries this line: there
    /// is no `bpy.ops` line that runs it without a pointer.
    public static func extrudeToCursorPython(_ pointer: MeshPointer, rotateSource: Bool = true) -> String {
        """
        import _blenderkit_meshmenu
        _blenderkit_meshmenu.to_cursor(\(pointer.pythonArguments()), rotate_source=\(rotateSource ? "True" : "False"))
        """
    }

    /// Rip Vertices and Rip Vertices and Fill (`mesh.rip_move`): rows Blender
    /// has, which the app shows and cannot run. `mesh.rip` has an invoke and
    /// no exec — which side of the vertex or edge tears away is decided by
    /// where the pointer is — and with no window there is no pointer: measured
    /// in desktop 5.2.1 under the borrowed 3D View, `rip_move` returned
    /// FINISHED with nothing changed and `rip` PASS_THROUGH ("can't exec
    /// macro"). Rip Vertices and Extend's operator has an exec, given a ray:
    /// with the ray through the 3D cursor it splits each selected vertex's
    /// edge that points most toward it, the new vertex on the old one until
    /// the panel's Move moves it (its row's own words, LastOperator.Mesh).
    public static let ripRows = ["Rip Vertices", "Rip Vertices and Fill"]

    public static let ripRefusal = "Blender tears this toward the pointer, which it reads from a window this "
        + "Blender does not have. Rip Vertices and Extend runs, with the 3D cursor as the pointer: it splits a "
        + "new vertex off on the edge pointing most toward the cursor, which its panel's Move then moves."

    /// What the toolbar's Poly Build says (its tooltip). Measured in desktop
    /// 5.2.1 with the app's context, under the borrowed 3D View: all five
    /// `polybuild_*` operators returned FINISHED or PASS_THROUGH and changed
    /// nothing — each acts on the element the pointer is over, found by
    /// Blender's preselection under the mouse — and the operator search
    /// refuses them by their poll.
    public static let polyBuildRefusal = "Poly Build acts on the element under the pointer, which Blender finds "
        + "from a window's mouse, and this Blender has no window: its operators change nothing here"
}
