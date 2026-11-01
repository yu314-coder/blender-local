import Foundation
import Observation

/// Every operator the backend actually has, asked of the backend.
///
/// Blender's F3 search is the fastest way to reach an operator, and under the
/// new direction it is also the honest one: the list is not a table maintained
/// in Swift that drifts from reality, it is `dir(bpy.ops.*)` read at runtime.
/// Whatever the module can do appears here — so on device, where the real
/// module is loaded, the search covers all of Blender rather than the subset
/// somebody remembered to add to a menu.
@Observable
public final class OperatorCatalogue {

    public struct Entry: Identifiable, Hashable {
        /// `mesh.bevel`
        public let path: String
        /// The operator's own name, `get_rna_type().name` — what Blender's
        /// Operator Search lists, its redo panel shows and its undo history
        /// records: `action.clickselect` is "Select Keyframes",
        /// `mesh.remove_doubles` "Merge by Distance". Before round 4 this was
        /// the identifier spaced and capitalised ("Clickselect", "Remove
        /// Doubles"), which is no name Blender shows. That spelling is kept
        /// only for an operator Blender gives none (9 of 2,498 in desktop
        /// 5.2.1, whose `get_rna_type` raises).
        public let label: String
        /// `mesh`
        public var category: String { String(path.split(separator: ".").first ?? "") }
        public var id: String { path }

        public var call: String { "bpy.ops.\(path)()" }

        init(path: String, name: String? = nil) {
            self.path = path
            if let name, !name.isEmpty {
                label = name
            } else {
                let tail = String(path.split(separator: ".").last ?? "")
                label = tail.split(separator: "_")
                    .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                    .joined(separator: " ")
            }
        }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var loaded = false

    /// The submodules worth offering. `bpy.ops` carries a great many, most of
    /// which need an editor this app does not have; these are the ones whose
    /// operators act on a 3D scene.
    static let modules = ["mesh", "object", "transform", "uv", "material",
                          "sculpt", "paint", "curve", "anim", "render", "view3d"]

    public init() {}

    /// Asks the backend what it can do. Must run after the interpreter is up.
    public func load(using bridge: BpyBridge) {
        guard !loaded else { return }
        // dir() on each submodule, filtered to callables, each with its
        // name. Written in Python because only Python can see what the module
        // actually exposes. `get_rna_type` only looks the type up — measured
        // in desktop 5.2.1 (background, gpu.init), all 2,498 in 41 ms, 9
        // raising (kept by their identifier).
        let probe = """
        import bpy as _bpy_probe
        _found = []
        for _m in dir(_bpy_probe.ops):
            if _m.startswith("_"):
                continue
            _mod = getattr(_bpy_probe.ops, _m, None)
            if _mod is None:
                continue
            for _n in dir(_mod):
                if _n.startswith("_"):
                    continue
                _op = getattr(_mod, _n, None)
                if not callable(_op):
                    continue
                try:
                    _name = _op.get_rna_type().name
                except Exception:
                    _name = ""
                _found.append(_m + "." + _n + "\\t" + _name.replace("\\n", " "))
        print("\\n".join(sorted(set(_found))))
        """
        guard let text = bridge.capture(probe) else { return }
        entries = Self.entries(fromProbe: text)
        loaded = !entries.isEmpty
    }

    /// The probe's lines, `path<TAB>name`, as entries; a line with no name
    /// (or a backend that prints paths alone) is labelled by its identifier.
    public static func entries(fromProbe text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let path = parts[0].trimmingCharacters(in: .whitespaces)
            guard path.contains("."), !path.contains(" ") else { return nil }
            let name = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return Entry(path: path, name: name)
        }
    }

    /// What the search's Run sends, through `bridge.run` as every command
    /// goes: `run_operator`, which puts the operator in the mode it needs,
    /// refuses what is measured to crash, and puts the mode back. Here rather
    /// than in the form so the checks that compile only this module run the
    /// very string (tests/relations/blender runs it in Local View).
    public static func runCommand(path: String, json: String) -> String {
        "import _blenderkit_sync as _bkui; import json; _bkui.run_operator(\(Bpy.quote(path)), json.loads(\(Bpy.quote(json))))"
    }

    /// Fills the catalogue directly, for tests that have no backend to ask.
    public func injectForTesting(_ paths: [String]) {
        entries = paths.map { Entry(path: $0) }
        loaded = true
    }

    /// Blender's search matches on the label; matching the dotted path too
    /// means `mesh.bev` finds Bevel as readily as `bevel` does.
    public func search(_ text: String, limit: Int = 40) -> [Entry] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }

        // Rank: a label that starts with the term beats one that merely
        // contains it, which is what makes typing "bev" put Bevel first.
        func rank(_ e: Entry) -> Int? {
            let label = e.label.lowercased(), path = e.path.lowercased()
            if label.hasPrefix(needle) { return 0 }
            if path.hasPrefix(needle) { return 1 }
            if label.contains(needle) { return 2 }
            if path.contains(needle) { return 3 }
            return nil
        }
        // Spelled out in steps rather than chained: the single-expression form
        // was more than the type checker would take.
        var scored: [(rank: Int, entry: Entry)] = []
        for entry in entries {
            if let r = rank(entry) { scored.append((r, entry)) }
        }
        scored.sort { a, b in
            a.rank == b.rank ? a.entry.path < b.entry.path : a.rank < b.rank
        }
        return scored.prefix(limit).map(\.entry)
    }
}
