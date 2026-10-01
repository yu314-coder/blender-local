import SwiftUI
import UIKit

/// The Scripting tab's Python console, drawn as BenchCode draws its terminal:
/// a slim strip over the screen, with Stop, Copy and Clear at its right.
struct ConsoleTerminalPane: View {
    var scene: BKScene
    var session: BpySession
    var focusRequest: Int = 0
    var fontSize: Int = 14
    @State private var size = ""

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
            Text("Python Console")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(white: 0.88))
                .lineLimit(1)
            Text(size.isEmpty ? "· bpy" : "· bpy · \(size)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(white: 0.52))
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
            HStack(spacing: 8) {
                Button { session.stopScript() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.octagon.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Self.stop)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    .background(Self.stop.opacity(0.18), in: Capsule())
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
        .frame(height: 22)
        .background(Self.strip)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.03)).frame(height: 1)
        }
    }

    private func stripButton(_ symbol: String, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(white: 0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(label)
    }
}
