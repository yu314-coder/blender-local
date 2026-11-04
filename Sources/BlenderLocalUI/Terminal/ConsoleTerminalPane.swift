import SwiftUI
import UIKit

/// The Scripting tab's terminal, drawn as BenchCode draws its terminal: a
/// strip over the screen with the prompt it is at, Commands, Stop, Copy and
/// Clear. The strip is a finger's height and Commands types a command for
/// whoever has no keyboard or does not know the commands' names (the user,
/// November 4: "make it much easy to use the terminal").
struct ConsoleTerminalPane: View {
    var scene: BKScene
    var session: BpySession
    var focusRequest: Int = 0
    var fontSize: Int = 14
    @State private var size = ""
    @State private var typeRequest = ConsoleTypeRequest(id: 0, text: "")

    /// Commands's rows: what a row types, and what it does in a few words.
    private struct Row: Identifiable {
        var command: String
        var says: String
        /// A shell command, typed with `!` at the Python prompt.
        var shell = true
        var id: String { command }
    }

    private static let groups: [(String, [Row])] = [
        ("Blender", [
            Row(command: "python", says: "The >>> prompt, where every line is Python"),
            Row(command: "[o.name for o in D.objects]", says: "Every object's name", shell: false),
            Row(command: "C.object", says: "The active object", shell: false),
            Row(command: "C.object.location", says: "Where the active object is", shell: false),
            Row(command: "bpy.ops.mesh.primitive_cube_add()", says: "Add a cube at the 3D cursor", shell: false),
        ]),
        ("Files", [
            Row(command: "ls -la", says: "This folder, with sizes and dates"),
            Row(command: "tree", says: "This folder and everything in it"),
            Row(command: "pwd", says: "Which folder this is"),
            Row(command: "cd ~/Documents", says: "Go to the app's Documents"),
        ]),
        ("This device", [
            Row(command: "top", says: "What is running; q quits"),
            Row(command: "df -h", says: "Free space"),
            Row(command: "uptime", says: "How long since it started"),
        ]),
        ("Help", [
            Row(command: "help", says: "Every command, by topic"),
            Row(command: "history", says: "What was typed before"),
            Row(command: "clear", says: "A clean screen"),
        ]),
    ]

    private static let background = Color(red: 0.020, green: 0.024, blue: 0.032)    // #05060a
    private static let strip = Color(red: 12 / 255, green: 12 / 255, blue: 19 / 255)  // #0c0c13
    private static let indigo = Color(red: 0.388, green: 0.400, blue: 0.945)          // #6366f1
    private static let violet = Color(red: 0.659, green: 0.333, blue: 0.969)          // #a855f7
    private static let stop = Color(red: 1.0, green: 0.40, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            header
            ConsoleTerminalView(scene: scene, session: session,
                                lineCount: session.console.count,
                                lastLine: session.console.last?.id,
                                isRunning: session.isRunning,
                                focusRequest: focusRequest,
                                typeRequest: typeRequest,
                                fontSize: fontSize,
                                onSize: { columns, rows in size = "\(columns)×\(rows)" })
        }
        .background(Self.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(LinearGradient(colors: [Self.indigo, Self.violet],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 7, height: 7)
            Text("Terminal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(white: 0.88))
                .lineLimit(1)
            // Which prompt it is at: the shell, or the Python `python` opened.
            Text(session.consoleMode == .python ? "Python" : "shell")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(session.consoleMode == .python ? Self.violet : Color(white: 0.62))
                .lineLimit(1)
            Text(size)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(white: 0.45))
                .lineLimit(1)
            if !session.isRealRuntime {
                Text("command subset")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Self.indigo)
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Self.indigo.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Self.indigo.opacity(0.25), lineWidth: 0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                commandsMenu
                Button { session.stopScript() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Self.stop)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Self.stop.opacity(0.18), in: Capsule())
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(!session.isRunning)
                .opacity(session.isRunning ? 1 : 0.45)

                stripButton("doc.on.doc", label: "Copy Console") {
                    UIPasteboard.general.string = ConsoleTranscript.plainText(session.console)
                }
                stripButton("trash", label: "Clear Console") { session.clearConsole() }
                    // Clearing mid-run would throw away the lines the run is
                    // still writing.
                    .disabled(session.isRunning)
                    .opacity(session.isRunning ? 0.4 : 1)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 44)
        .background(Self.strip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.03)).frame(height: 1)
        }
    }

    /// Commands: a row types its command at the prompt and runs it, with
    /// `!` in front of a shell command at the Python prompt.
    private var commandsMenu: some View {
        Menu {
            ForEach(Self.groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1) { row in
                        Button {
                            let atPython = session.consoleMode == .python
                            if row.command == "python", atPython { return }
                            let text = row.shell && atPython ? "!" + row.command : row.command
                            typeRequest = ConsoleTypeRequest(id: typeRequest.id + 1, text: text)
                        } label: {
                            Text(row.command)
                            Text(row.says)
                        }
                        .disabled(row.command == "python" && session.consoleMode == .python)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                Text("Commands")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Color(white: 0.85))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .disabled(session.isRunning)
        .accessibilityIdentifier("console.commands")
    }

    private func stripButton(_ symbol: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}
