import CoreGraphics
import Foundation

/// One buffered subtitle line (a finalized transcript utterance) plus its
/// optional live translation.
struct SubtitleStreamPage: Equatable, Sendable, Identifiable {
    let id: UUID
    var text: String
    var translation: String?
    var timestamp: Date?
    /// Measured content width in points; set by the presenting view.
    var width: CGFloat = 0
}

/// Adaptive flow metrics for the subtitle stream.
///
/// The flow speed adapts in real time to the volume of pending text: a quiet
/// stream moves at the base pace while a burst raises the speed (up to a
/// readable cap) so buffered subtitles drain without ever covering what the
/// user is reading. Speed is a pure function of the pending character count,
/// so it changes smoothly and never jumps.
enum SubtitleFlowMetrics {
    /// Natural flow pace when the buffer is empty or nearly empty.
    static let baseSpeed: CGFloat = 26
    /// Readable cap: faster than this and the text stops being readable.
    static let maximumSpeed: CGFloat = 74
    /// Speed gained per pending character; bounded by `maximumSpeed`.
    static let speedPerPendingCharacter: CGFloat = 0.25
    /// Visual gap between consecutive subtitle pages.
    static let traverseGap: CGFloat = 28

    static func speed(pendingCharacters: Int) -> CGFloat {
        min(
            baseSpeed + CGFloat(max(0, pendingCharacters)) * speedPerPendingCharacter,
            maximumSpeed
        )
    }
}

/// A bounded, continuously flowing subtitle buffer.
///
/// New subtitles accumulate in the buffer (they never replace the page being
/// read) and flow through the viewport at the adaptive pace. The cursor tracks
/// how far the stream has moved; fully traversed pages drop off the head, and
/// the buffer is bounded so memory stays constant over long meetings.
struct SubtitleStreamFlow: Equatable, Sendable {
    private(set) var pages: [SubtitleStreamPage] = []
    /// Strip position in points, relative to the head page (0 = head page
    /// left-aligned with the viewport).
    private(set) var cursor: CGFloat = 0
    let maximumPages: Int
    let maximumCharacters: Int

    init(
        maximumPages: Int = 30,
        maximumCharacters: Int = 2_400
    ) {
        self.maximumPages = maximumPages
        self.maximumCharacters = maximumCharacters
    }

    var isEmpty: Bool { pages.isEmpty }

    /// Characters still buffered (including the page currently flowing).
    var pendingCharacterCount: Int {
        pages.reduce(0) { $0 + $1.text.count }
    }

    /// Buffers a new subtitle page. Never replaces existing content.
    mutating func append(_ page: SubtitleStreamPage) {
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pages.append(page)
        trimToBounds()
    }

    mutating func updateTranslation(id: UUID, translation: String?) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].translation = translation
    }

    mutating func updateWidth(_ width: CGFloat, for id: UUID) {
        guard width > 0 else { return }
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].width = width
    }

    /// Advances the stream by `deltaTime` at the adaptive speed and drops
    /// fully traversed pages. Returns true when the cursor moved.
    @discardableResult
    mutating func tick(deltaTime: TimeInterval) -> Bool {
        guard !pages.isEmpty, deltaTime > 0 else { return false }
        let distance = SubtitleFlowMetrics.speed(pendingCharacters: pendingCharacterCount)
            * CGFloat(deltaTime)
        cursor += distance
        var changed = distance > 0
        // An unmeasured page (width 0) is never popped: the measured width
        // arrives within a frame of appending.
        while !pages.isEmpty,
              pages[0].width > 0,
              cursor >= pages[0].width + SubtitleFlowMetrics.traverseGap {
            cursor -= pages[0].width + SubtitleFlowMetrics.traverseGap
            pages.removeFirst()
            changed = true
        }
        if pages.isEmpty {
            cursor = 0
        }
        return changed
    }

    /// Pages (and their strip positions) currently overlapping the viewport.
    /// Pure: does not mutate the flow.
    func visiblePages(viewportWidth: CGFloat) -> [(page: SubtitleStreamPage, x: CGFloat)] {
        guard !pages.isEmpty else { return [] }
        var result: [(SubtitleStreamPage, CGFloat)] = []
        var positionX = -cursor
        for page in pages {
            if positionX + page.width > 0, positionX < viewportWidth {
                result.append((page, positionX))
            }
            positionX += page.width + SubtitleFlowMetrics.traverseGap
            if positionX >= viewportWidth { break }
        }
        return result
    }

    /// Strip position where a fresh live tail (the current partial) should be
    /// rendered, immediately after the last buffered page.
    var liveTailPosition: CGFloat {
        guard !pages.isEmpty else { return 0 }
        let width = pages.reduce(CGFloat(0)) { $0 + $1.width }
        return width + CGFloat(pages.count - 1) * SubtitleFlowMetrics.traverseGap - cursor
    }

    mutating func reset() {
        pages = []
        cursor = 0
    }

    private mutating func trimToBounds() {
        var removedWidth: CGFloat = 0
        var removedGapCount = 0
        while pages.count > maximumPages {
            removedWidth += pages[0].width
            removedGapCount += 1
            pages.removeFirst()
        }
        var total = pages.reduce(0) { $0 + $1.text.count }
        while total > maximumCharacters, pages.count > 1 {
            removedWidth += pages[0].width
            removedGapCount += 1
            total -= pages[0].text.count
            pages.removeFirst()
        }
        // The cursor is relative to the head page; trimmed pages shift it.
        if removedGapCount > 0 {
            cursor -= removedWidth + CGFloat(removedGapCount) * SubtitleFlowMetrics.traverseGap
            cursor = max(0, cursor)
        }
    }
}
