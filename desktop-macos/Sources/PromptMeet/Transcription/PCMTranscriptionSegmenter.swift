import Foundation

struct PCMTranscriptionSegment: Equatable, Sendable {
    let source: NativeAudioSource
    let sampleRate: Int
    let samples: [Int16]
}

struct PCMTranscriptionUpdate: Equatable, Sendable {
    let preview: PCMTranscriptionSegment?
    let finalized: [PCMTranscriptionSegment]
}

struct PCMTranscriptionSegmenter {
    private let targetSampleRate = 16_000
    private let segmentSampleCount: Int
    private let minimumFlushSampleCount: Int
    private let previewIntervalSampleCount: Int
    private let minimumPreviewSampleCount: Int
    private let minimumRMS: Double
    private var samplesBySource: [NativeAudioSource: [Int16]] = [:]
    private var lastPreviewSampleCountBySource: [NativeAudioSource: Int] = [:]

    init(
        segmentDuration: TimeInterval = 3,
        minimumFlushDuration: TimeInterval = 0.5,
        previewInterval: TimeInterval = 1.25,
        minimumPreviewDuration: TimeInterval = 1,
        minimumRMS: Double = 80
    ) {
        segmentSampleCount = max(1, Int(segmentDuration * 16_000))
        minimumFlushSampleCount = max(1, Int(minimumFlushDuration * 16_000))
        previewIntervalSampleCount = max(1, Int(previewInterval * 16_000))
        minimumPreviewSampleCount = max(1, Int(minimumPreviewDuration * 16_000))
        self.minimumRMS = minimumRMS
    }

    mutating func consume(_ pcm: CapturedPCM) -> [PCMTranscriptionSegment] {
        consumeStreaming(pcm).finalized
    }

    mutating func consumeStreaming(_ pcm: CapturedPCM) -> PCMTranscriptionUpdate {
        guard pcm.channels > 0, pcm.sampleRate > 0 else {
            return PCMTranscriptionUpdate(preview: nil, finalized: [])
        }
        let decoded = Self.decodePCM16(pcm.payload, channels: pcm.channels)
        let normalized = Self.resample(decoded, from: pcm.sampleRate, to: targetSampleRate)
        samplesBySource[pcm.source, default: []].append(contentsOf: normalized)
        let finalized = drainFullSegments(for: pcm.source)
        let preview = makePreviewIfNeeded(for: pcm.source)
        return PCMTranscriptionUpdate(preview: preview, finalized: finalized)
    }

    mutating func flush() -> [PCMTranscriptionSegment] {
        var output: [PCMTranscriptionSegment] = []
        for source in samplesBySource.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            output.append(contentsOf: drainFullSegments(for: source))
            guard let remainder = samplesBySource[source], remainder.count >= minimumFlushSampleCount else {
                samplesBySource[source] = []
                continue
            }
            if isAudible(remainder) {
                output.append(
                    PCMTranscriptionSegment(source: source, sampleRate: targetSampleRate, samples: remainder)
                )
            }
            samplesBySource[source] = []
            lastPreviewSampleCountBySource[source] = 0
        }
        return output
    }

    private mutating func drainFullSegments(for source: NativeAudioSource) -> [PCMTranscriptionSegment] {
        var output: [PCMTranscriptionSegment] = []
        while let samples = samplesBySource[source], samples.count >= segmentSampleCount {
            let segment = Array(samples.prefix(segmentSampleCount))
            if isAudible(segment) {
                output.append(
                    PCMTranscriptionSegment(
                        source: source,
                        sampleRate: targetSampleRate,
                        samples: segment
                    )
                )
            }
            samplesBySource[source] = Array(samples.dropFirst(segmentSampleCount))
            lastPreviewSampleCountBySource[source] = 0
        }
        return output
    }

    private mutating func makePreviewIfNeeded(for source: NativeAudioSource) -> PCMTranscriptionSegment? {
        guard let samples = samplesBySource[source], samples.count >= minimumPreviewSampleCount else {
            return nil
        }
        let previousCount = lastPreviewSampleCountBySource[source, default: 0]
        guard samples.count - previousCount >= previewIntervalSampleCount, isAudible(samples) else {
            return nil
        }
        lastPreviewSampleCountBySource[source] = samples.count
        return PCMTranscriptionSegment(source: source, sampleRate: targetSampleRate, samples: samples)
    }

    private func isAudible(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return false }
        let sum = samples.reduce(0.0) { partial, sample in
            let value = Double(sample)
            return partial + value * value
        }
        return sqrt(sum / Double(samples.count)) >= minimumRMS
    }

    private static func decodePCM16(_ data: Data, channels: Int) -> [Int16] {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return [] }
        let interleaved: [Int16] = data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Int16.self).prefix(sampleCount))
        }
        guard channels > 1 else { return interleaved }
        return stride(from: 0, to: interleaved.count, by: channels).map { frameStart in
            let frame = interleaved[frameStart..<min(frameStart + channels, interleaved.count)]
            let total = frame.reduce(Int64(0)) { $0 + Int64($1) }
            return Int16(total / Int64(frame.count))
        }
    }

    private static func resample(_ samples: [Int16], from sourceRate: Int, to targetRate: Int) -> [Int16] {
        guard !samples.isEmpty, sourceRate != targetRate else { return samples }
        let outputCount = Int((Double(samples.count) * Double(targetRate) / Double(sourceRate)).rounded())
        guard outputCount > 0 else { return [] }
        return (0..<outputCount).map { outputIndex in
            let sourcePosition = Double(outputIndex) * Double(sourceRate) / Double(targetRate)
            let lower = min(Int(sourcePosition), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = sourcePosition - Double(lower)
            let value = Double(samples[lower]) * (1 - fraction) + Double(samples[upper]) * fraction
            return Int16(max(Double(Int16.min), min(Double(Int16.max), value.rounded())))
        }
    }
}
