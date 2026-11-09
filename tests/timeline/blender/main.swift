import Foundation

// Every string the Timeline's controls send, printed for a headless Blender
// to run (tests/timeline/blender/verify.py): made by the same builders the
// controls call (`BpyKeys`, through `TimelineKeyEditor`), the history's push,
// undo and redo as the app sends them, and the menus' rows by Blender's
// names. `check menus` prints the rows as JSON.

var out: [String] = []
func emit(_ name: String, _ body: String) { out.append("### \(name)\n\(body)") }
func command(_ name: String, _ c: BlenderCommand) {
    emit(name, c.body)
    emit("LABEL_" + name, c.undo ?? "")
}

if CommandLine.arguments.dropFirst().first == "menus" {
    var menus: [String: [[String]]] = [:]
    for id in TimelineMenus.ids {
        menus[id] = TimelineMenus.rows(id).map { row -> [String] in
            switch row.kind {
            case .separator: return ["sep", ""]
            case .heading: return ["heading", row.title]
            case .unavailable: return ["unavailable", row.title]
            case .submenu(let sub): return ["submenu", row.title, sub]
            case .action: return ["action", row.title]
            case .interface(let name): return ["interface", row.title, name]
            }
        }
    }
    let data = try! JSONSerialization.data(withJSONObject: menus, options: [.sortedKeys, .prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

command("CLICK_10", BpyKeys.clickSelect(frame: 10, extend: false))
command("CLICK_10_SHIFT", BpyKeys.clickSelect(frame: 10, extend: true))
command("CLICK_20_SHIFT", BpyKeys.clickSelect(frame: 20, extend: true))
command("CLICK_EMPTY", BpyKeys.clickSelect(frame: nil, extend: false))
command("BOX_SET", BpyKeys.boxSelect(from: 12, to: 4.5, mode: "SET"))
command("BOX_ADD", BpyKeys.boxSelect(from: 19.5, to: 21, mode: "ADD"))
command("BOX_SUB", BpyKeys.boxSelect(from: 4, to: 6, mode: "SUB"))
command("SIDE_LEFT", BpyKeys.selectLeftRight("LEFT", extend: false))
command("SIDE_RIGHT_EXTEND", BpyKeys.selectLeftRight("RIGHT", extend: true))
command("MOVE_3", BpyKeys.move(by: 3, duplicate: false))
command("MOVE_10", BpyKeys.move(by: 10, duplicate: false))
command("MOVE_2_4_UNSNAPPED", BpyKeys.move(by: 2.4, duplicate: false, snap: false))
command("DUPLICATE_4", BpyKeys.move(by: 4, duplicate: true))
command("DUPLICATE_0", BpyKeys.move(by: 0, duplicate: true))
command("SCALE_1_5", BpyKeys.scale(by: 1.5))
command("MARKER_SELECT_0", BpyKeys.markerSelect(index: 0, extend: false))
command("MARKER_SELECT_1_SHIFT", BpyKeys.markerSelect(index: 1, extend: true))
command("MARKER_SELECT_NONE", BpyKeys.markerSelect(index: -1, extend: false))
command("MARKER_MOVE_5", BpyKeys.markerMove(by: 5, duplicate: false))
command("MARKER_DUPLICATE_3", BpyKeys.markerMove(by: 3, duplicate: true))
command("MARKER_RENAME", BpyKeys.markerRename("Hit's \"crash\""))
emit("SNAP_STATE", BpyKeys.snapState)

let actions: [(String, TimelineAction)] = [
    ("SELECT_ALL", .selectAll("SELECT")), ("SELECT_NONE", .selectAll("DESELECT")),
    ("SELECT_INVERT", .selectAll("INVERT")), ("COLUMNS_KEYS", .selectColumn("KEYS")),
    ("COLUMN_CFRA", .selectColumn("CFRA")), ("COLUMNS_MARKERS", .selectColumn("MARKERS_COLUMN")),
    ("BETWEEN_MARKERS", .selectColumn("MARKERS_BETWEEN")), ("BEFORE", .selectLeftRight("LEFT")),
    ("AFTER", .selectLeftRight("RIGHT")), ("LINKED", .selectLinked), ("MORE", .selectMore), ("LESS", .selectLess),
    ("DELETE", .delete), ("CLEAN", .clean(channels: false)), ("CLEAN_CHANNELS", .clean(channels: true)),
    ("COPY", .copy), ("PASTE", .paste(flipped: false)), ("PASTE_FLIPPED", .paste(flipped: true)),
    ("SNAP_CFRA", .snap("CFRA")), ("SNAP_NEAREST_FRAME", .snap("NEAREST_FRAME")),
    ("MIRROR_CFRA", .mirror("CFRA")), ("JUMP", .jumpToKeys),
    ("INTERPOLATION_ELASTIC", .interpolation("ELASTIC")), ("INTERPOLATION_LINEAR", .interpolation("LINEAR")),
    ("EASING_EASE_IN", .easing("EASE_IN")), ("TYPE_BREAKDOWN", .keyframeType("BREAKDOWN")),
    ("TYPE_EXTREME", .keyframeType("EXTREME")), ("HANDLE_VECTOR", .handleType("VECTOR")),
    ("INSERT_ALL", .insert("ALL")), ("MARKER_ADD", .markerAdd), ("MARKER_DELETE", .markerDelete),
    ("MARKER_SELECT_ALL", .markerSelectAll("SELECT")), ("MARKER_DESELECT_ALL", .markerSelectAll("DESELECT")),
    ("MARKER_BEFORE", .markerSelectLeftRight("LEFT")), ("MARKER_CAMERA", .markerCameraBind),
    ("LOCK_ON", .lockMarkers(true)), ("LOCK_OFF", .lockMarkers(false)),
]
for (name, action) in actions {
    command(name, BpyKeys.command(for: action))
    emit("MIRROR_" + name, BpyKeys.isSelection(action) || action == .copy ? "0" : "1")
}

emit("PUSH", BackendHistoryPython.push(root: "@ROOT@", label: "@LABEL@", replace: false, forceCheckpoints: false))
emit("UNDO", BackendHistoryPython.step(-1))
emit("REDO", BackendHistoryPython.step(1))
emit("UNCHANGED", BpyKeys.unchanged)
print(out.joined(separator: "\n#--\n"))
