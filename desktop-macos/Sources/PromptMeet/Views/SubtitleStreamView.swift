import SwiftUI

/// The island's live subtitle stream.
///
/// Newly recognized lines accumulate in a `SubtitleStreamFlow` buffer and flow
/// through the viewport at a speed adapted to the pending volume: a burst
/// queues pages (never covering what the user is reading) while a quiet
/// stream flows at the natural base pace. The stream never restarts and the
/// cursor never jumps - pages enter, traverse, and exit continuously.
struct SubtitleStreamView: View {
    @ObservedObject var store: MeetingStore
    var font: Font = .system(size: 12, weight: .medium, design: .rounded)
    var viewportHeight: CGFloat = 21

    @StateObject private var driver = SubtitleStreamDriver()

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width

            ZStack(alignment: .leading) {
                ForEach(driver.flow.visiblePages(viewportWidth: viewportWidth), id: \.page.id) { entry in
                    subtitleRow(entry.page)
                        .offset(x: entry.x)
                        .background {
                            measureWidth(for: entry.page.id)
                        }
                }

                if let liveText = driver.normalizedLiveText, !liveText.isEmpty {
                    subtitleRow(
                        SubtitleStreamPage(id: driver.liveTailID, text: liveText)
                    )
                    .offset(x: max(0, driver.flow.liveTailPosition))
                    .background {
                        measureLiveTailWidth
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.035),
                        .init(color: .black, location: 0.965),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        .frame(height: viewportHeight)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(driver.accessibilityCaption)
        .onAppear {
            driver.start(store: store)
        }
        .onDisappear {
            driver.stop()
        }
        .onChange(of: store.state.subtitleFlow) { _, newFlow in
            driver.syncPages(newFlow.pages)
        }
        .onChange(of: store.state.activeTranscript) { _, text in
            driver.updateLiveText(text)
        }
        .onPreferenceChange(SubtitlePageWidthKey.self) { widths in
            for (id, width) in widths {
                driver.updateWidth(width, for: id)
            }
        }
        .onPreferenceChange(SubtitleLiveTailWidthKey.self) { width in
            driver.updateLiveTailWidth(width)
        }
    }

    private func subtitleRow(_ page: SubtitleStreamPage) -> some View {
        HStack(spacing: 9) {
            Text(page.text)
                .font(font)
                .foregroundStyle(VisualTokens.primaryText)

            if let translation = normalizedTranslation(page.translation) {
                Circle()
                    .fill(VisualTokens.sky.opacity(0.55))
                    .frame(width: 3, height: 3)

                Text(translation)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(VisualTokens.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func normalizedTranslation(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func measureWidth(for id: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SubtitlePageWidthKey.self,
                value: [id: proxy.size.width]
            )
        }
    }

    private var measureLiveTailWidth: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: SubtitleLiveTailWidthKey.self,
                value: proxy.size.width
            )
        }
    }
}

private struct SubtitlePageWidthKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct SubtitleLiveTailWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Drives the subtitle flow at 30 fps outside view updates and keeps the
/// measured widths and live partial alongside the pure flow model.
@MainActor
final class SubtitleStreamDriver: ObservableObject {
    @Published private(set) var flow = SubtitleStreamFlow()
    @Published private(set) var liveTailWidth: CGFloat = 0

    private var timer: Timer?
    private var lastTickDate: Date?
    private var liveText: String = ""

    let liveTailID = UUID()

    var normalizedLiveText: String? {
        let value = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var accessibilityCaption: String {
        let buffered = flow.pages.last?.text ?? ""
        if let live = normalizedLiveText {
            return buffered.isEmpty ? live : "\(buffered)。\(live)"
        }
        return buffered
    }

    func start(store: MeetingStore) {
        flow = store.state.subtitleFlow
        liveText = store.state.activeTranscript
        lastTickDate = Date()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func syncPages(_ newPages: [SubtitleStreamPage]) {
        let existing = Set(flow.pages.map(\.id))
        for page in newPages where !existing.contains(page.id) {
            flow.append(page)
        }
    }

    func updateLiveText(_ text: String) {
        liveText = text
    }

    func updateWidth(_ width: CGFloat, for id: UUID) {
        flow.updateWidth(width, for: id)
    }

    func updateLiveTailWidth(_ width: CGFloat) {
        guard width > 0 else { return }
        liveTailWidth = width
    }

    private func tick() {
        let now = Date()
        guard let last = lastTickDate else {
            lastTickDate = now
            return
        }
        let delta = now.timeIntervalSince(last)
        lastTickDate = now
        flow.tick(deltaTime: min(delta, 0.5))
    }
}
