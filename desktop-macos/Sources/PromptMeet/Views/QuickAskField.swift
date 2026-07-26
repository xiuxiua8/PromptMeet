import SwiftUI

enum QuickAskAppearance {
    case standard
    case aura
}

struct QuickAskField: View {
    @ObservedObject var store: MeetingStore
    var showsBackground = true
    var appearance: QuickAskAppearance = .standard
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

                ZStack(alignment: .leading) {
                    if draft.wrappedValue.isEmpty {
                        Text("问问这场会议…")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(appearance == .aura ? 0.72 : 0.64))
                            .allowsHitTesting(false)
                    }

                    TextField("", text: draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .focused($isFocused)
                        .onSubmit(store.submitQuickPrompt)
                        .disabled(store.state.aiRequest.isBusy)
                }

                if store.state.aiRequest.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VisualTokens.sky)
                } else {
                    Button(action: store.submitQuickPrompt) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 24, height: 24)
                            .background(VisualTokens.sky)
                            .foregroundStyle(Color.black.opacity(0.82))
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: appearance == .aura ? 9 : 12,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(
                showsBackground
                    ? Color.white.opacity(appearance == .aura ? 0.080 : 0.14)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: appearance == .aura ? 14 : 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: appearance == .aura ? 14 : 12, style: .continuous)
                    .stroke(
                        Color.white.opacity(
                            showsBackground ? (appearance == .aura ? 0.10 : 0.16) : 0
                        ),
                        lineWidth: appearance == .aura ? 0.5 : 1
                    )
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
