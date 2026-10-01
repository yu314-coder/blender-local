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
        /// `Bevel` — the last component, spaced and capitalised.
        public let label: String
        /// `mesh`
        public var category: String { String(path.split(separator: ".").first ?? "") }
        public var id: String { path }

        public var call: String { "bpy.ops.\(path)()" }

        init(path: String) {
            self.path = path
            let name = String(path.split(separator: ".").last ?? "")
            label = name.split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
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
        // dir() on each submodule, filtered to callables. Written in Python
        // because only Python can see what the module actually exposes.
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
                if callable(getattr(_mod, _n, None)):
                    _found.append(_m + "." + _n)
        print("\\n".join(sorted(set(_found))))
        """
        guard let text = bridge.capture(probe) else { return }
        entries = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains(".") && !$0.contains(" ") }
            .map(Entry.init(path:))
        loaded = !entries.isEmpty
    }

    /// Fills the catalogue directly, for tests that have no backend to ask.
    public func injectForTesting(_ paths: [String]) {
        entries = paths.map(Entry.init(path:))
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
