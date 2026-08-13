import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var state = MeetingState()
    @Published var isHovered = false
    @Published var sessionID: String?
    @Published var topChromeWidth: CGFloat = 200
    @Published var topChromeHeight: CGFloat = 34
    var backendSessionID: String?
    var meetingStartedAt: Date?
    var uiPreviewMode: String?

    let backend: BackendClientProtocol
    let capture: NativeAudioCaptureCoordinating
    let companion: CompanionLaunching
    let screenshotController: ScreenshotCaptureControlling
    let suggestionDebounce: Duration
    let meetingPreferences: MeetingPreferences
    let transcriptOutbox: TranscriptOutboxStoring
    let now: @MainActor () -> Date
    let subtitleStreamDriver = SubtitleStreamDriver()
    var suggestionDebounceTask: Task<Void, Never>?
    var suggestionGenerationTask: Task<Void, Never>?
    var pendingSuggestionRevision: Int?
    var suggestionContextRevision = 0
    var lastRequestedSuggestionRevision = -1
    var activeSuggestionGenerationID: UUID?
    var suggestionContextTokens: Set<String> = []
    var automationScheduler: MeetingAutomationScheduler?
    var automationClockTask: Task<Void, Never>?
    var meetingInputRevision = 0
    var meetingInputTokens: Set<String> = []
    var pendingCompanionConfigurationReload = false
    var reconnectTask: Task<Void, Never>?
    var reconnectInProgress = false
    var meetingGeneration = UUID()
    var transcriptSyncTask: Task<Bool, Never>?
    var transcriptSyncGeneration: UUID?

    init(
        backend: BackendClientProtocol = BackendClient(),
        capture: NativeAudioCaptureCoordinating = NativeAudioCaptureCoordinator(),
        companion: CompanionLaunching = CompanionLauncher(),
        screenshotController: ScreenshotCaptureControlling = ScreenCaptureController(),
        suggestionDebounce: Duration = .milliseconds(350),
        meetingPreferences: MeetingPreferences = MeetingPreferences(),
        transcriptOutbox: TranscriptOutboxStoring = TranscriptOutboxStore(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.backend = backend
        self.capture = capture
        self.companion = companion
        self.screenshotController = screenshotController
        self.suggestionDebounce = suggestionDebounce
        self.meetingPreferences = meetingPreferences
        self.transcriptOutbox = transcriptOutbox
        self.now = now
    }

    var presentation: IslandPresentation {
        state.islandPresentation(isHovered: isHovered)
    }

    var hasMeetingContext: Bool {
        backendSessionID != nil || uiPreviewMode != nil
    }

    var isMeetingActive: Bool {
        switch state.phase {
        case .idle, .failed:
            return state.recordingActivity != .inactive
        case .connecting, .live, .stopping:
            return true
        }
    }

    var canDeleteMeetingHistory: Bool { !isMeetingActive }

    var nextMeetingCaptureDescription: String {
        meetingPreferences.includeLocalMicrophone
            ? "下次会议：系统音频 + 本机麦克风"
            : "下次会议：仅系统音频，不会请求麦克风权限"
    }

    var summaryAutomationDescription: String {
        switch state.summaryAutomation {
        case .idle: return "自动摘要尚未开始"
        case .off: return "自动摘要已关闭"
        case .waiting(let minute): return "将在第 \(minute) 个有效录音分钟生成摘要与待办"
        case .generating(let minute):
            return minute.map { "正在生成第 \($0) 分钟摘要与待办" } ?? "正在生成摘要与待办"
        case .completed(let revision, let minute):
            return minute.map { "第 \($0) 分钟生成完成 · 修订 \(revision)" } ?? "生成完成 · 修订 \(revision)"
        case .noAction(_, let message): return message
        case .failed(let message): return "自动摘要失败：\(message)"
        }
    }

    func setHovered(_ hovered: Bool) {
        isHovered = hovered
    }

    func updateNotchInfo(_ notch: NotchInfo) {
        topChromeWidth = max(100, notch.width)
        topChromeHeight = max(24, notch.height)
    }

    func configureUIPreview(_ mode: String) {
        uiPreviewMode = mode
        subtitleStreamDriver.reset()
        state = Self.previewStates[mode] ?? MeetingState()
        isHovered = mode == "hover"
    }

    private static let previewStates: [String: MeetingState] = [
        "live": .previewAura,
        "paused": .previewPaused,
        "hover": .previewAura,
        "quick-ask": .previewQuickAsk,
        "workspace": .previewWorkspace,
        "workspace-compact": .previewWorkspace,
        "workspace-large": .previewWorkspace,
        "workspace-formula": .previewFormulaWorkspace,
        "workspace-formula-streaming": .previewFormulaWorkspaceStreaming,
        "reader-short": .previewReader,
        "reader-long": .previewLongReader,
        "reader-formula": .previewFormulaReader
    ]

    func dispatch(_ action: MeetingAction) {
        state.reduce(action)
    }

    func modify<Value>(_ keyPath: WritableKeyPath<MeetingState, Value>, to value: Value) {
        objectWillChange.send()
        state[keyPath: keyPath] = value
    }
}
