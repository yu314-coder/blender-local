import SwiftUI

/// The two workspaces. Blender ships eleven (Layout, Modeling, Sculpting,
/// UV Editing, …, Scripting); these are the two this app provides, and they
/// appear as workspace tabs in the topbar exactly as Blender's do.
enum Workspace: String, CaseIterable, Identifiable {
    case scripting     = "Scripting"
    case layout        = "3D View"
    case shading       = "Shading"
    case rendering     = "Rendering"

    // Blender ships eleven workspaces, and this had all eleven. Most were the
    // same 3D viewport in a different mode, which the mode selector already
    // switches — so they cost a tab each and changed almost nothing. Sculpt,
    // Vertex Paint, Weight Paint, Texture Paint and UV all still work; they are
    // reached the way Blender reaches them once you are already in the
    // viewport, from the mode dropdown. Compositing and Geometry Nodes are
    // node editors, and a node graph is better written as bpy than tapped out
    // on glass — the Scripting workspace is where they live now.
    /// Layout and Modeling were the same workspace with a different mode set
    /// on entry, which is a whole tab to change one dropdown. They are one 3D
    /// View now, and the mode selector does what the tab used to.
    case modeling      = "Modeling"
    case sculpting     = "Sculpting"
    case uvEditing     = "UV Editing"
    case texturePaint  = "Texture Paint"
    case animation     = "Animation"
    case compositing   = "Compositing"
    case geometryNodes = "Geometry Nodes"

    /// The tabs the topbar actually shows.
    ///
    /// Two. Shading and Rendering were each the same 3D viewport with one
    /// editor bolted underneath, so each cost a whole tab to change what a
    /// panel showed — and switching tabs reframed the camera and lost your
    /// place in the scene you were working on. They are modes of the panel
    /// under the 3D View now, which is where the work already was.
    static var visible: [Workspace] { [.scripting, .layout] }

    var id: String { rawValue }

    /// All eleven workspaces now have something real behind them.
    var isImplemented: Bool { true }

    /// What each missing workspace would need, shown as its tooltip.
    var requirement: String {
        switch self {
        case .layout, .scripting, .modeling: return ""
        case .sculpting:     return "Needs sculpt mode and dynamic topology"
        case .uvEditing:     return "Needs UV coordinates and an image editor"
        case .texturePaint:  return "Needs texture painting"
        case .shading:       return "Needs the shader node editor"
        case .animation:     return "Needs keyframes and a dope sheet"
        case .rendering:     return "Needs Eevee or Cycles"
        case .compositing:   return "Needs the compositor node editor"
        case .geometryNodes: return "Needs the geometry node system"
        }
    }
}

/// Blender's topbar: application menus on the left, workspace tabs across the
/// middle, scene state on the right.
struct TopBar: View {
    @Binding var workspace: Workspace
    var scene: BKScene
    var session: BpySession
    var undo: UndoStack
    @Binding var showStatusBar: Bool
    /// The view the Render menu renders from.
    var renderCamera: ViewportCamera
    var catalogue: OperatorCatalogue
    var bridge: BpyBridge?
    @Binding var showSearch: Bool
    @State private var savedFiles: [URL] = []

    var body: some View {
        HStack(spacing: 12) {
            FileMenu(scene: scene, session: session, bridge: bridge, savedFiles: $savedFiles)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Workspace", selection: $workspace) {
                Text("Scripting").tag(Workspace.scripting)
                Text("3D View").tag(Workspace.layout)
            }.pickerStyle(.segmented).frame(maxWidth: 300)
            // Undo, Redo and what the last run did, the same on both tabs.
            //
            // Undo and Redo were two items deep in the 3D View's More menu and
            // absent from Scripting, where Run Script is itself an undo step.
            // They sit beside the run status so that nothing moves when the
            // tab changes: a control that jumps sideways between two screens is
            // one you have to look for twice.
            HStack(spacing: 2) {
                historyButton("Undo", icon: "arrow.uturn.backward", enabled: canUndo) {
                    session.performUndo()
                }
                historyButton("Redo", icon: "arrow.uturn.forward", enabled: canRedo) {
                    session.performRedo()
                }
                Rectangle().fill(BTheme.outline).frame(width: 1, height: 18)
                    .padding(.horizontal, 8)
                RunStatusPill(session: session)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 48)
        .background(BTheme.topbar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(BTheme.editorOutline).frame(height: BTheme.Metric.hairline)
        }
        .onAppear { savedFiles = SceneDocument.listSaved() }
    }

    private var canUndo: Bool {
        // Held while a sculpt stroke is down, or points are being dragged,
        // too (BpySession.gestureHold).
        !session.isRunning && session.gestureHold == nil
            && (session.usesRealBlender ? session.backendCanUndo : undo.canUndo)
    }

    private var canRedo: Bool {
        !session.isRunning && session.gestureHold == nil
            && (session.usesRealBlender ? session.backendCanRedo : undo.canRedo)
    }

    private func historyButton(_ label: String, icon: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(BTheme.text.opacity(enabled ? 1 : 0.35))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .help(label)
    }

    /// The workspace tabs.
    ///
    /// Eleven tabs plus the menus and the scene selectors do not fit across a
    /// portrait iPad, and the strip used to share one scroll view with the
    /// menus — where a greedy `Spacer` meant it was squeezed and clipped rather
    /// than scrolled, so Scripting simply could not be reached.
    ///
    /// It now scrolls on its own, and the active tab is always brought into
    /// view, so switching workspaces from a menu never leaves you looking at a
    /// strip that does not show where you are.
    @ViewBuilder
    private var workspaceTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(Workspace.visible, id: \.self) { ws in
                        workspaceTab(ws).id(ws)
                    }
                    // Blender's "add workspace" tab.
                    Text("+")
                        .font(BTheme.Font.ui(14))
                        .foregroundStyle(BTheme.textDim.opacity(0.5))
                        .padding(.horizontal, 9)
                        .frame(height: BTheme.Metric.topbarHeight - 5)
                        .background(BTheme.tabInactive)
                        .clipShape(UnevenRoundedRectangle(
                            topLeadingRadius: 5, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0, topTrailingRadius: 5))
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            // Fading the edges is the only hint that the strip runs past them:
            // scroll indicators do not show on a bar this short.
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.02),
                                       .init(color: .black, location: 0.98),
                                       .init(color: .clear, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
            .onAppear { proxy.scrollTo(workspace, anchor: .center) }
            .onChange(of: workspace) { _, ws in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(ws, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    /// One workspace tab. Split out because the inline expression was complex
    /// enough that the type-checker resolved ForEach to its Binding overload.
    @ViewBuilder
    private func workspaceTab(_ ws: Workspace) -> some View {
        let selected: Bool = (workspace == ws)
        let enabled: Bool = ws.isImplemented
        // Blender fills every tab, not only the active one — the active tab is
        // lighter, and a hairline gap separates them.
        let fill: Color = selected ? BTheme.tabActive : BTheme.tabInactive
        let titleColour: Color = selected ? BTheme.title
                                          : BTheme.textDim.opacity(enabled ? 0.95 : 0.6)
        Button {
            if enabled { workspace = ws }
        } label: {
            Text(ws.rawValue)
                .font(BTheme.Font.ui(12, weight: selected ? .medium : .regular))
                .foregroundStyle(titleColour)
                .padding(.horizontal, 10)
                .frame(height: BTheme.Metric.topbarHeight - 4)
                .background(fill)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 5, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 5))
        }
        .buttonStyle(.plain)
                .hoverEffect(.highlight)
        .disabled(!enabled)
        .help(enabled ? ws.rawValue : ws.requirement)
    }

}

/// What the last run did, where it can be seen from either tab.
///
/// The Scripting tab had no sign a script was running beyond a disabled Run
/// button, and a failed run said so in orange in the far corner of the
/// preview. Both belong in one place, and the top bar is the one place on
/// screen whichever tab is open — a script that fails while you are looking at
/// the 3D View is still worth knowing about.
struct RunStatusPill: View {
    var session: BpySession

    var body: some View {
        HStack(spacing: 7) {
            if session.isRunning {
                ProgressView().controlSize(.small).tint(BTheme.active)
                    .scaleEffect(0.7).frame(width: 12, height: 12)
                Text("Running").foregroundStyle(BTheme.text)
                Text(String(format: "%.1f s", session.runElapsed))
                    .font(BTheme.Font.mono(11)).foregroundStyle(BTheme.textDim)
            } else if let run = session.lastRun {
                Circle().fill(run.succeeded ? BTheme.textDim : BTheme.error)
                    .frame(width: 6, height: 6)
                if run.succeeded {
                    Text("Ran \(run.lines) line\(run.lines == 1 ? "" : "s")")
                        .foregroundStyle(BTheme.text)
                    Text(run.timing).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.textDim)
                } else if let line = run.errorLine {
                    Text("Stopped at line \(line)").foregroundStyle(BTheme.error)
                    Text(run.timing).font(BTheme.Font.mono(11)).foregroundStyle(BTheme.textDim)
                } else {
                    // "Nothing to run — the editor is empty." and its kind:
                    // no line to point at, so the sentence is the status.
                    Text(run.error ?? "Run failed").foregroundStyle(BTheme.error).lineLimit(1)
                }
            } else {
                Circle().fill(BTheme.textDim).frame(width: 6, height: 6)
                Text("Ready").foregroundStyle(BTheme.textDim)
            }
        }
        .font(BTheme.Font.ui(12))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(BTheme.header)
        .clipShape(Capsule())
        .overlay {
            Capsule().strokeBorder(failed ? BTheme.error.opacity(0.45) : BTheme.outline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var failed: Bool { !session.isRunning && session.lastRun?.succeeded == false }
}
