import Combine
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published var state = MeetingState()
    @Published var isHovered = false
    @Published var sessionID: String?
    @Published var topChromeWidth: CGFloat = 200
    @Published var topChromeHeight: CGFloat = 34
    var backendSessionID: String?
    var uiPreviewMode: String?

    let backend: BackendClientProtocol
    let capture: NativeAudioCaptureCoordinating
    let companion: CompanionLaunching
    let screenshotController: ScreenshotCaptureControlling
    let suggestionDebounce: Duration
    let meetingPreferences: MeetingPreferences
    let now: @MainActor () -> Date
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

    init(
        backend: BackendClientProtocol = BackendClient(),
        capture: NativeAudioCaptureCoordinating = NativeAudioCaptureCoordinator(),
        companion: CompanionLaunching = CompanionLauncher(),
        screenshotController: ScreenshotCaptureControlling = ScreenCaptureController(),
        suggestionDebounce: Duration = .milliseconds(350),
        meetingPreferences: MeetingPreferences = MeetingPreferences(),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.backend = backend
        self.capture = capture
        self.companion = companion
        self.screenshotController = screenshotController
        self.suggestionDebounce = suggestionDebounce
        self.meetingPreferences = meetingPreferences
        self.now = now
    }

    var presentation: IslandPresentation {
        state.islandPresentation(isHovered: isHovered)
    }

    var hasMeetingContext: Bool {
        backendSessionID != nil || uiPreviewMode != nil
    }

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
        switch mode {
        case "live":
            state = .previewAura
            isHovered = false
        case "paused":
            state = .previewPaused
            isHovered = false
        case "hover":
            state = .previewAura
            isHovered = true
        case "quick-ask":
            state = .previewQuickAsk
            isHovered = false
        case "workspace", "workspace-compact", "workspace-large":
            state = .previewWorkspace
            isHovered = false
        case "reader-short":
            state = .previewReader
            isHovered = false
        case "reader-long":
            state = .previewLongReader
            isHovered = false
        default:
            state = MeetingState()
            isHovered = false
        }
    }
}
