import SwiftUI

struct QuickAskField: View {
    @ObservedObject var store: MeetingStore
    var showsBackground = true
    @FocusState private var isFocused: Bool

    private var draft: Binding<String> {
        Binding(
            get: { store.state.quickPromptDraft },
            set: { value in store.setQuickPromptDraft(value) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(VisualTokens.sky)

                TextField(
                    "",
                    text: draft,
                    prompt: Text("问问这场会议…")
                        .foregroundStyle(Color.white.opacity(0.64))
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .focused($isFocused)
                    .onSubmit(store.submitQuickPrompt)
                    .disabled(store.state.aiRequest.isBusy)

                if store.state.aiRequest.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VisualTokens.sky)
                } else {
                    Button(action: store.submitQuickPrompt) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(VisualTokens.sky)
                            .foregroundStyle(Color.white)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(showsBackground ? Color.white.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(showsBackground ? 0.16 : 0), lineWidth: 1)
            }

            if let error = store.state.aiRequest.errorMessage,
               store.state.aiRequest.phase == .failed {
                Text(error)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualTokens.danger)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
        }
        .onAppear { isFocused = store.state.isQuickAskPresented }
        .onChange(of: store.state.isQuickAskPresented) { _, isPresented in
            isFocused = isPresented
        }
        .onExitCommand { store.setQuickAskPresented(false) }
    }
}
