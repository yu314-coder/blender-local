import SwiftUI

/// The 3D View's menus that Blender opens at the pointer — with a right-click
/// (Blender's context menus) or a key (`wm.call_menu` and the pies) — as
/// rows for `PopupMenuOverlay`.
///
/// Every row is an action this app already had, in a menu bar item or a
/// header menu: these menus only gather them where Blender's do, under
/// Blender's names (space_view3d.py and the operators' own names, 5.2.1).
/// A row Blender has and this app cannot run is left out rather than drawn
/// greyed, as its menu bar does. A pie is drawn as the list of its items.
enum ViewportMenu: String, CaseIterable {
    case context
    case add, apply, deleteObjects, delete
    case merge, split, separate, extrude, vertex, edge, face, normals
    case snap, shading, view, mode, orientation
    case parent, clearParent, moveToCollection, linkToCollection, makeLinks
    case selectGrouped, selectLinked, selectSimilar

    /// Blender's menu, by its `bl_idname` (or the operator whose invoke draws
    /// it), for the launch hooks and the docs.
    var blenderName: String {
        switch self {
        case .context:          return "VIEW3D_MT_object_context_menu"
        case .add:              return "VIEW3D_MT_add"
        case .apply:            return "VIEW3D_MT_object_apply"
        case .deleteObjects:    return "OBJECT_OT_delete"
        case .delete:           return "VIEW3D_MT_edit_mesh_delete"
        case .merge:            return "VIEW3D_MT_edit_mesh_merge"
        case .split:            return "VIEW3D_MT_edit_mesh_split"
        case .separate:         return "MESH_OT_separate"
        case .extrude:          return "VIEW3D_MT_edit_mesh_extrude"
        case .vertex:           return "VIEW3D_MT_edit_mesh_vertices"
        case .edge:             return "VIEW3D_MT_edit_mesh_edges"
        case .face:             return "VIEW3D_MT_edit_mesh_faces"
        case .normals:          return "VIEW3D_MT_edit_mesh_normals"
        case .snap:             return "VIEW3D_MT_snap_pie"
        case .shading:          return "VIEW3D_MT_shading_pie"
        case .view:             return "VIEW3D_MT_view_pie"
        case .mode:             return "VIEW3D_MT_object_mode_pie"
        case .orientation:      return "VIEW3D_MT_orientations_pie"
        case .parent:           return "OBJECT_OT_parent_set"
        case .clearParent:      return "OBJECT_OT_parent_clear"
        case .moveToCollection: return "OBJECT_MT_move_to_collection"
        case .linkToCollection: return "OBJECT_MT_link_to_collection"
        case .makeLinks:        return "VIEW3D_MT_make_links"
        case .selectGrouped:    return "OBJECT_OT_select_grouped"
        case .selectLinked:     return "OBJECT_OT_select_linked"
        case .selectSimilar:    return "VIEW3D_MT_edit_mesh_select_similar"
        }
    }

    /// The menu `v` opens for this request: the context menu becomes the
    /// mode's own, and nil means Blender has nothing here (Join's Ctrl+P with
    /// nothing selected still opens, as Blender's does).
    @MainActor static func model(_ menu: ViewportMenu, _ v: ViewportKeyActions, at point: CGPoint) -> PopupMenuModel? {
        let rows: [PopupItem]
        var title: String?
        var name = menu.blenderName
        switch menu {
        case .context:
            if v.editing && v.editingMesh {
                name = "VIEW3D_MT_edit_mesh_context_menu"
                rows = editMeshContext(v)
            } else if v.editing && v.editingLattice {
                name = "VIEW3D_MT_edit_lattice_context_menu"
                title = "Lattice"
                rows = latticeContext(v)
            } else if v.editing && v.editingCurve {
                name = "VIEW3D_MT_edit_curve_context_menu"
                title = "Curve"
                rows = curveContext(v)
            } else if v.mode == .object {
                title = "Object"
                rows = objectContext(v)
            } else if let panel = v.brushPanel, let label = BrushContextPanel.title(for: v.mode) {
                name = v.mode == .sculpt ? "VIEW3D_PT_sculpt_context_menu"
                    : v.mode == .weightPaint ? "VIEW3D_PT_paint_weight_context_menu" : "VIEW3D_PT_paint_vertex_context_menu"
                title = label
                rows = [.control(panel())]
            } else {
                return nil
            }
        case .add:
            guard !v.editing, v.mode == .object else { return nil }
            title = "Add"
            rows = add(v)
        case .apply:
            guard !v.editing else { return nil }
            title = "Apply"
            rows = apply(v)
        case .deleteObjects:
            guard v.mode == .object, v.hasActiveObject else { return nil }
            title = "Delete"
            rows = [.action("Delete") { v.deleteSelected() }]
        case .delete, .merge, .split, .extrude, .vertex, .edge, .face, .normals:
            guard v.editing && v.editingMesh else { return nil }
            title = meshGroup(menu)?.rawValue
            rows = meshRows(menu, v)
        case .separate:
            guard v.editing && v.editingMesh else { return nil }
            title = "Separate"
            rows = Bpy.SeparateType.allCases.map { type in .action(type.label) { v.separate(type) } }
        case .snap:
            title = "Snap"
            rows = snap(v)
        case .shading:
            title = "Shading"
            rows = ViewportShading.allCases.map { s in
                .action(s.label, icon: s.icon, checked: v.shading == s) { v.setShading(s) }
            }
        case .view:
            title = "View"
            rows = view(v)
        case .mode:
            guard !v.modes.isEmpty else { return nil }
            title = "Mode"
            rows = v.modes.map { m in
                .action(m.label, icon: m.icon, checked: v.mode == m) { v.enterMode(m) }
            }
        case .orientation:
            title = "Orientation"
            let current = v.orientation()
            rows = TransformOrientation.allCases.map { o in
                .action(o.label, icon: o.icon, checked: current == o) { v.setOrientation(o) }
            }
        case .parent:
            guard !v.editing else { return nil }
            title = "Set Parent To"
            rows = parentSet(v)
        case .clearParent:
            guard !v.editing else { return nil }
            title = "Clear Parent"
            rows = LastOperator.ClearParentType.allCases.map { type in
                .action(type.label, enabled: v.objectRelations.canClearParent) { v.perform(.clearParent(type)) }
            }
        case .moveToCollection, .linkToCollection:
            guard !v.editing, let tree = v.collections, let root = tree.sceneCollection else { return nil }
            let link = menu == .linkToCollection
            title = link ? "Link to Collection" : "Move to Collection"
            rows = collectionRows(tree, root, link: link, v)
        case .makeLinks:
            guard !v.editing else { return nil }
            title = "Link/Transfer Data"
            rows = makeLinks(v)
        case .selectGrouped:
            guard !v.editing, v.hasActiveObject else { return nil }
            title = "Select Grouped"
            rows = SelectMenu.groupedTypes.map { type in .action(type.label) { v.selectRow(.grouped(type.identifier)) } }
        case .selectLinked:
            guard !v.editing, v.hasActiveObject else { return nil }
            title = "Select Linked"
            rows = SelectMenu.linkedTypes.map { type in .action(type.label) { v.selectRow(.linked(type.identifier)) } }
        case .selectSimilar:
            guard v.editing && v.editingMesh else { return nil }
            title = "Select Similar"
            rows = SelectMenu.SimilarType.offered(in: v.selectMode).map { type in
                .action(type.label) { v.selectRow(.similar(type)) }
            } + [.separator, .action(SelectMenu.MeshItem.similarRegion.title) {
                v.selectRow(.mesh(.similarRegion))
            }]
        }
        guard !rows.isEmpty else { return nil }
        return PopupMenuModel(name: name, title: title, anchor: point, items: rows)
    }

    // MARK: Object Mode

    /// `VIEW3D_MT_object_context_menu`, for the active object's type.
    @MainActor private static func objectContext(_ v: ViewportKeyActions) -> [PopupItem] {
        var rows: [PopupItem] = []
        let type = v.activeType
        let busy = v.isRunning
        if type == "CAMERA", let set = v.setActiveCamera {
            rows += [.action("Set Active Camera", key: "Ctrl Numpad 0", enabled: !busy, set), .separator]
        }
        if type == "MESH" || type == "CURVE" || type == "SURFACE" {
            rows.append(.action("Shade Smooth", enabled: !busy) { v.shade(true) })
            if type == "MESH" {
                rows.append(.action("Shade Auto Smooth", enabled: !busy && v.essentialsLibrary != false,
                                    note: v.essentialsLibrary == false
                                        ? "Needs Blender's Essentials library" : nil) {
                    v.perform(LastOperator.shadeAutoSmooth())
                })
            }
            rows.append(.action("Shade Flat", enabled: !busy) { v.shade(false) })
            rows.append(.separator)
        }
        if let type, LastOperator.joinableTypes.contains(type), v.selectedCount > 1 {
            rows.append(.action("Join", key: "Ctrl J", enabled: !busy && v.objectRelations.canJoin) {
                v.perform(.join())
            })
        }
        if let type, ["MESH", "CURVE", "CURVES", "SURFACE", "POINTCLOUD", "META", "FONT", "GREASEPENCIL"].contains(type) {
            rows.append(.submenu("Convert", enabled: !busy && v.objectRelations.canConvert) {
                LastOperator.ConvertTarget.allCases.map { target in
                    .action(target.label) { v.perform(.convert(to: target)) }
                }
            })
        }
        if type != nil && type != "CAMERA" && type != "LIGHT" && type != "SPEAKER" && type != "LIGHT_PROBE" {
            rows.append(.submenu("Set Origin", enabled: v.objectTransform.enabled && v.objectTransform.canSetOrigin) {
                Bpy.originMenu.map { choice in .action(choice.title) { v.setOrigin(choice) } }
            })
            rows.append(.separator)
        }
        // The shared rows start a section of their own.
        if let last = rows.last, case .separator = last.kind {} else if !rows.isEmpty { rows.append(.separator) }
        rows += [
            .action("Copy Objects", icon: "doc.on.doc", key: "Ctrl C", enabled: !busy && v.hasActiveObject,
                    v.copyObjects),
            .action("Paste Objects", icon: "doc.on.clipboard", key: "Ctrl V", enabled: !busy, v.pasteObjects),
            .separator,
            .action("Duplicate Objects", icon: "plus.square.on.square", key: "Shift D",
                    enabled: !busy && v.hasActiveObject) { v.duplicate() },
            .action("Duplicate Linked", key: "Alt D", enabled: !busy && v.objectRelations.canDuplicate) {
                v.perform(.duplicateLinked())
            },
            .separator,
        ]
        if let rename = v.rename {
            rows += [.action("Rename Active Object…", key: "F2", enabled: !busy, rename), .separator]
        }
        rows.append(.submenu("Mirror", enabled: !busy && v.objectRelations.canDuplicate) { mirrorRows(v) })
        rows.append(.submenu("Snap", enabled: !busy) { snap(v) })
        rows.append(.submenu("Parent", enabled: !busy && v.objectRelations.available) { parentMenu(v) })
        if v.inLocalView {
            rows.append(.action("Remove from Local View", enabled: !busy) { v.run(LocalViewBpy.removeFrom) })
        } else if let tree = v.collections, let root = tree.sceneCollection {
            rows.append(.submenu("Move to Collection", enabled: !busy && v.objectRelations.canDuplicate) {
                collectionRows(tree, root, link: false, v)
            })
        }
        rows += [
            .separator,
            .action("Insert Keyframe", key: "I", enabled: !busy && v.hasActiveObject, v.insertKeyframe),
            .separator,
            .action("Delete", key: "X", enabled: !busy && v.hasActiveObject) { v.deleteSelected() },
        ]
        return rows
    }

    /// `VIEW3D_MT_add`, the rows this app can add, in Blender's order.
    @MainActor private static func add(_ v: ViewportKeyActions) -> [PopupItem] {
        var rows: [PopupItem] = [
            .submenu("Mesh", icon: "cube") {
                PrimitiveKind.allCases.map { kind in .action(kind.displayName, icon: kind.icon) { v.add(kind) } }
            },
            .submenu("Curve", icon: ObjectAddition.CurveKind.bezier.icon) {
                ObjectAddition.CurveKind.allCases.map { kind in
                    .action(kind.label, icon: kind.icon) { v.addObject(.curve(kind)) }
                }
            },
            .action(ObjectAddition.text.label, icon: ObjectAddition.text.icon) { v.addObject(.text) },
            .separator,
            .action(ObjectAddition.lattice.label, icon: ObjectAddition.lattice.icon) { v.addObject(.lattice) },
            .separator,
            .submenu("Empty", icon: EmptyDisplay.Kind.arrows.icon) {
                EmptyDisplay.Kind.addMenu.map { kind in
                    .action(kind.label, icon: kind.icon) { v.addObject(.empty(kind)) }
                }
            },
            .submenu("Image", icon: "photo") {
                var images: [PopupItem] = []
                if let addImage = v.addImage {
                    images += ReferenceImages.Kind.allCases.map { kind in
                        .action(kind.label, icon: kind.icon) { addImage(kind) }
                    }
                }
                images.append(.action("Empty Image", icon: EmptyDisplay.Kind.image.icon) {
                    v.addObject(.empty(.image))
                })
                return images
            },
            .separator,
            .submenu("Light", icon: "lightbulb") {
                LightDisplay.Kind.allCases.map { kind in
                    .action(kind.label, icon: kind.icon) { v.addObject(.light(kind)) }
                }
            },
            .separator,
            .action(ObjectAddition.camera.label, icon: ObjectAddition.camera.icon) { v.addObject(.camera) },
        ]
        if v.isRunning { rows = rows.map { var r = $0; r.enabled = false; return r } }
        return rows
    }

    /// `VIEW3D_MT_object_apply`, the rows `object.transform_apply` covers here.
    @MainActor private static func apply(_ v: ViewportKeyActions) -> [PopupItem] {
        let state = v.objectTransform
        let order: [Bpy.AppliedTransform] = [.location, .rotation, .scale, .all]
        return order.map { what in
            .action(what.title, enabled: state.offers(what),
                    note: what == .scale ? state.activeScaleText : nil) { v.applyTransform(what) }
        }
    }

    /// Ctrl+P's Set Parent To: what `object.parent_set`'s invoke offers for
    /// objects, the two rows this app runs.
    @MainActor private static func parentSet(_ v: ViewportKeyActions) -> [PopupItem] {
        let ok = v.objectRelations.canParent && !v.isRunning
        let why = v.objectRelations.canParent ? nil : "Select the children, then the parent last"
        return [
            .action("Object", enabled: ok, note: why) { v.perform(.parent(keepTransform: false)) },
            .action("Object (Keep Transform)", enabled: ok) { v.perform(.parent(keepTransform: true)) },
        ]
    }

    /// Object ▸ Parent (`VIEW3D_MT_object_parent`): the parent rows, then the
    /// three ways to clear.
    @MainActor private static func parentMenu(_ v: ViewportKeyActions) -> [PopupItem] {
        parentSet(v) + [.separator] + LastOperator.ClearParentType.allCases.map { type in
            .action(type.label, enabled: v.objectRelations.canClearParent) { v.perform(.clearParent(type)) }
        }
    }

    /// `VIEW3D_MT_mirror` in Object Mode: Interactive Mirror waits for an
    /// axis key in Blender, so the rows here are its axes.
    @MainActor private static func mirrorRows(_ v: ViewportKeyActions) -> [PopupItem] {
        var rows: [PopupItem] = []
        for (i, row) in LastOperator.mirrorRows.enumerated() {
            if i == 3 { rows.append(.separator) }
            rows.append(.action(row.label) { v.perform(.mirror(axis: row.axis, local: row.local)) })
        }
        return rows
    }

    /// `VIEW3D_MT_snap`.
    @MainActor private static func snap(_ v: ViewportKeyActions) -> [PopupItem] {
        var rows: [PopupItem] = []
        for item in SnapBpy.allCases {
            if item == .cursorToSelected { rows.append(.separator) }
            let enabled = !v.isRunning && (!item.needsActive || v.hasActiveObject)
                && (!item.movesSelection || v.hasActiveObject || v.editing)
            rows.append(.action(item.label, icon: item.movesSelection ? nil : "scope", enabled: enabled) {
                v.snap(item)
            })
        }
        return rows
    }

    /// `VIEW3D_MT_view_pie`: the six axis views, View Camera, View Selected.
    @MainActor private static func view(_ v: ViewportKeyActions) -> [PopupItem] {
        let order: [ViewportCamera.Viewpoint] = [.left, .right, .bottom, .top, .front, .back]
        return order.map { p in .action(p.label, key: p.shortcut) { v.view(p) } } + [
            .action("View Camera", icon: "camera", key: "Numpad 0", enabled: v.lookThroughCamera != nil) {
                v.lookThroughCamera?()
            },
            .action("View Selected", key: "Numpad .") { v.frameSelected() },
        ]
    }

    /// Blender's Move to Collection and Link to Collection
    /// (`move_to_collection_menu_draw`): New Collection, the collection, its
    /// children — each with children of its own as a submenu.
    @MainActor private static func collectionRows(_ tree: CollectionTree, _ entry: CollectionTree.Entry,
                                                  link: Bool, _ v: ViewportKeyActions) -> [PopupItem] {
        var rows: [PopupItem] = [
            .action("New Collection", icon: "plus") { v.askNewCollection(entry.uid, link) },
            .separator,
            .action(entry.name) { v.run(CollectionsBpy.move(to: entry.uid, link: link)) },
        ]
        for child in tree.children(of: entry.uid) {
            if tree.children(of: child.uid).isEmpty {
                rows.append(.action(child.name) { v.run(CollectionsBpy.move(to: child.uid, link: link)) })
            } else {
                rows.append(.submenu(child.name) { collectionRows(tree, child, link: link, v) })
            }
        }
        return rows
    }

    /// `VIEW3D_MT_make_links`, the rows this app runs.
    @MainActor private static func makeLinks(_ v: ViewportKeyActions) -> [PopupItem] {
        let ok = v.objectRelations.canJoin && !v.isRunning
        var rows: [PopupItem] = []
        for (i, type) in LastOperator.makeLinksTypes.enumerated() {
            if i == 6 { rows.append(.separator) }
            rows.append(.action(type.label, enabled: ok) { v.perform(.makeLinksData(type.identifier)) })
        }
        rows.append(.separator)
        rows.append(.action("Copy UV Maps", enabled: ok) { v.perform(.copyUVMaps()) })
        return rows
    }

    // MARK: Edit Mode

    private static func meshGroup(_ menu: ViewportMenu) -> LastOperator.Mesh.Group? {
        switch menu {
        case .delete:  return .delete
        case .merge:   return .merge
        case .split:   return .split
        case .extrude: return .extrude
        case .vertex:  return .vertex
        case .edge:    return .edge
        case .face:    return .face
        case .normals: return .normals
        default:       return nil
        }
    }

    /// The Mesh menu's group as the key's menu: Blender's Delete (X), Merge
    /// (M), Split (Alt+M), Extrude (Alt+E), Vertex (Ctrl+V), Edge (Ctrl+E),
    /// Face (Ctrl+F) and Normals (Alt+N) — the same rows, in the same order,
    /// as the header's Mesh menu draws them.
    @MainActor private static func meshRows(_ menu: ViewportMenu, _ v: ViewportKeyActions) -> [PopupItem] {
        guard let group = meshGroup(menu) else { return [] }
        var rows: [PopupItem] = []
        for op in group.rows {
            if group == .vertex, op == .bevelVertices {
                rows.append(.action(MeshMenuTools.extrudeToCursor, enabled: !v.isRunning, v.extrudeToCursor))
            }
            // Blender's separators in its Delete menu: before the dissolves
            // and before Collapse.
            if group == .delete, op == .dissolveVerts || op == .collapseEdgesFaces { rows.append(.separator) }
            rows.append(meshRow(op, v))
            if let nested = LastOperator.Mesh.Group.allCases.first(where: { $0.parent == group && $0.after == op }) {
                rows.append(.submenu(nested.rawValue) { nested.rows.map { meshRow($0, v) } })
            }
        }
        return rows
    }

    @MainActor private static func meshRow(_ op: LastOperator.Mesh, _ v: ViewportKeyActions,
                                           title: String? = nil) -> PopupItem {
        .action(title ?? op.menuLabel, enabled: !v.isRunning && (!op.editModeOnly || v.editing)) { v.mesh(op) }
    }

    /// `VIEW3D_MT_edit_mesh_context_menu`: a column for each select mode in
    /// use — Vertex, Edge, Face — each with Blender's rows in its order, those
    /// this app runs. Rows Blender draws only past a count (New Edge/Face
    /// from Vertices for two vertices or more) follow the mirror's counts
    /// when it has them.
    @MainActor private static func editMeshContext(_ v: ViewportKeyActions) -> [PopupItem] {
        let counts = v.selectedElements()
        func atLeast(_ n: Int, _ count: Int?) -> Bool { count.map { $0 >= n } ?? true }
        let off = v.isRunning
        func row(_ op: LastOperator.Mesh, _ title: String? = nil) -> PopupItem { meshRow(op, v, title: title) }
        let separate = PopupItem.submenu("Separate", enabled: !off) {
            Bpy.SeparateType.allCases.map { type in .action(type.label) { v.separate(type) } }
        }
        let snap = PopupItem.submenu("Snap Vertices", enabled: !off) { snap(v) }

        var vertex: [PopupItem] = [.heading("Vertex", icon: "circle.grid.2x2"), .separator,
                                   row(.subdivide), .separator, row(.bevelVertices)]
        if atLeast(2, counts?.vertices) {
            vertex += [.separator, row(.fillFace), row(.connectVertexPath), row(.connectVertexPairs)]
        }
        vertex += [.separator, row(.pushPull), row(.shrinkFatten),
                   .action("Shear", enabled: !off, v.shear),
                   row(.slideVertices), row(.randomize, "Randomize Vertices"), row(.smooth),
                   row(.smoothLaplacian, "Smooth Laplacian"), .separator, snap, .separator]
        if atLeast(2, counts?.vertices) {
            vertex.append(.submenu("Merge Vertices", enabled: !off) {
                LastOperator.Mesh.Group.merge.rows.map { meshRow($0, v) }
            })
        }
        vertex += [row(.splitSelection, "Split"), separate, row(.dissolveVerts), row(.deleteVertices, "Delete Vertices")]

        var edge: [PopupItem] = [.heading("Edge", icon: "line.diagonal"), .separator,
                                 row(.subdivide), .separator, row(.bevel)]
        if atLeast(2, counts?.edges) { edge.append(row(.bridgeEdgeLoops)) }
        if atLeast(1, counts?.edges) { edge.append(row(.fillFace, "New Face from Edges")) }
        edge += [.separator,
                 .action(CutTool.loopCut.menuRow.label, enabled: !off) { v.setTool(.loopCut) },
                 row(.offsetEdgeSlide), .separator,
                 .action(CutTool.knife.menuRow.label, enabled: !off) { v.setTool(.knife) },
                 row(.bisect), .separator,
                 row(.rotateEdgeCW), row(.edgeSlide), row(.edgeSplitEdges, "Edge Split"), .separator,
                 row(.bevelWeight), row(.edgeCrease), .separator,
                 row(.markSeam), row(.clearSeam), .separator,
                 row(.markSharp), row(.clearSharp), .separator,
                 row(.unsubdivide), row(.splitSelection, "Split"), separate, row(.dissolveEdges),
                 row(.deleteEdges, "Delete Edges")]

        var face: [PopupItem] = [.heading("Face", icon: "square"), .separator,
                                 row(.subdivide), .separator,
                                 row(.extrude, "Extrude Faces Along Normals"), row(.extrudeIndividual),
                                 row(.inset), row(.poke)]
        if atLeast(2, counts?.faces) { face.append(row(.bridgeEdgeLoops, "Bridge Faces")) }
        face += [.separator, row(.triangulate), row(.quadify), .separator,
                 row(.shadeSmoothFaces, "Shade Smooth"), row(.shadeFlatFaces, "Shade Flat"), .separator,
                 row(.unsubdivide), row(.splitSelection, "Split"), separate, row(.dissolveFaces),
                 row(.deleteFaces, "Delete Faces")]

        let columns: [[PopupItem]]
        switch v.selectMode {
        case .vertex: columns = [vertex]
        case .edge:   columns = [edge]
        case .face:   columns = [face]
        }
        return columns.count == 1 ? columns[0] : [.columns(columns)]
    }

    /// `VIEW3D_MT_edit_lattice_context_menu`: Mirror, Snap and the rest; the
    /// app runs Snap.
    @MainActor private static func latticeContext(_ v: ViewportKeyActions) -> [PopupItem] {
        [.submenu("Snap", enabled: !v.isRunning) { snap(v) }]
    }

    /// `VIEW3D_MT_edit_curve_context_menu`, the rows this app runs: Snap and
    /// the Delete rows.
    @MainActor private static func curveContext(_ v: ViewportKeyActions) -> [PopupItem] {
        [.submenu("Snap", enabled: !v.isRunning) { snap(v) },
         .separator,
         .action("Delete Point", enabled: !v.isRunning) { v.deleteSelected() }]
    }
}
