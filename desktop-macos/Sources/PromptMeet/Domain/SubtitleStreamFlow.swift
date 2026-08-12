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
/// The flow speed tracks the generation rate in real time: subtitles (and
/// their translations, which are part of each page's measured width) scroll
/// past as fast as they are produced, so the buffer never accumulates. A
/// quiet stream moves at the natural base pace, and a burst raises the speed
/// (up to a safety cap) until the backlog drains. Speed is a pure function of
/// the measured entry rate and the pending width, so it changes smoothly and
/// never jumps.
enum SubtitleFlowMetrics {
    /// Natural flow pace when nothing is being generated.
    static let baseSpeed: CGFloat = 26
    /// Safety cap: high enough to clear any realistic meeting's generation
    /// rate while keeping the stream readable during traversal.
    static let maximumSpeed: CGFloat = 260
    /// Headroom over the measured entry rate so the flow outruns generation
    /// and the backlog drains instead of growing.
    static let keepUpGain: CGFloat = 1.15
    /// Extra speed per point of pending (buffered) width during bursts.
    static let drainGain: CGFloat = 0.08
    /// Sliding window over which the entry rate is measured, matching the
    /// per-segment transcription cadence.
    static let rateWindow: TimeInterval = 8
    /// Visual gap between consecutive subtitle pages.
    static let traverseGap: CGFloat = 28

    /// Flow speed in points/second for the given measured generation rate
    /// (points of content entering the buffer per second) and pending width.
    static func speed(
        entryRatePtsPerSecond: CGFloat,
        pendingWidth: CGFloat
    ) -> CGFloat {
        let rateDriven = keepUpGain * max(0, entryRatePtsPerSecond)
        let drainDriven = drainGain * max(0, pendingWidth)
        return min(baseSpeed + rateDriven + drainDriven, maximumSpeed)
    }
}

/// A bounded, continuously flowing subtitle buffer.
///
/// New subtitles accumulate in the buffer (they never replace the page being
/// read) and flow through the viewport at the adaptive pace. The cursor tracks
/// how far the stream has moved; fully traversed pages drop off the head, and
/// the buffer is bounded so memory stays constant over long meetings.
struct SubtitleStreamFlow: Equatable, Sendable {
    private struct AppendEntry: Equatable, Sendable {
        let time: TimeInterval
        let id: UUID
    }

    private(set) var pages: [SubtitleStreamPage] = []
    /// Strip position in points, relative to the head page (0 = head page
    /// left-aligned with the viewport).
    private(set) var cursor: CGFloat = 0
    let maximumPages: Int
    let maximumCharacters: Int
    /// Model time in seconds, advanced by `tick`.
    private var modelTime: TimeInterval = 0
    /// Pages appended within the rate window, for the generation-rate estimate.
    private var appendWindow: [AppendEntry] = []

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

    /// Width still buffered, including traverse gaps.
    var pendingWidth: CGFloat {
        guard !pages.isEmpty else { return 0 }
        return pages.reduce(CGFloat(0)) { $0 + $1.width }
            + CGFloat(pages.count - 1) * SubtitleFlowMetrics.traverseGap
    }

    /// Measured generation rate: points of content appended within the rate
    /// window, per second. Translations count through each page's measured
    /// width, so subtitles and translations together keep the flow caught up.
    var entryRatePtsPerSecond: CGFloat {
        guard !appendWindow.isEmpty else { return 0 }
        let windowedWidth = appendWindow.reduce(CGFloat(0)) { sum, entry in
            let width = pages.first { $0.id == entry.id }?.width ?? 0
            return sum + width
        }
        return windowedWidth / CGFloat(SubtitleFlowMetrics.rateWindow)
    }

    /// Buffers a new subtitle page. Never replaces existing content.
    mutating func append(_ page: SubtitleStreamPage) {
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pages.append(page)
        appendWindow.append(AppendEntry(time: modelTime, id: page.id))
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
        modelTime += deltaTime
        pruneAppendWindow()
        let speed = SubtitleFlowMetrics.speed(
            entryRatePtsPerSecond: entryRatePtsPerSecond,
            pendingWidth: pendingWidth
        )
        cursor += speed * CGFloat(deltaTime)
        var changed = speed > 0
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

    private mutating func pruneAppendWindow() {
        let cutoff = modelTime - SubtitleFlowMetrics.rateWindow
        while let first = appendWindow.first, first.time < cutoff {
            appendWindow.removeFirst()
        }
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
        modelTime = 0
        appendWindow = []
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
