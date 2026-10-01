import SwiftUI

/// Blender's Info editor. Every action taken with the tools is reported here as
/// the Python that performs it — the bridge between the two tabs, and the way
/// users learn the API in Blender.
struct InfoLogView: View {
    var session: BpySession
    var onSendToEditor: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(BTheme.textDim)
                Text("Info").font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                Spacer()
                if !session.infoLog.isEmpty {
                    BButton("Copy to Editor", icon: "arrow.up.doc") {
                        onSendToEditor(session.infoLog.joined(separator: "\n"))
                    }
                }
            }

            if session.infoLog.isEmpty {
                // Nothing to show. The pane may be collapsed to its header, so
                // this must not insist on room for a placeholder.
                Color.clear.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(session.infoLog.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(BTheme.Font.mono(11))
                                .foregroundStyle(BTheme.textDim)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(BTheme.info)
    }
}
