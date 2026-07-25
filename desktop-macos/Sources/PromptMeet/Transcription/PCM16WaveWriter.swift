import Foundation

enum PCM16WaveWriter {
    static func data(samples: [Int16], sampleRate: Int) -> Data {
        let payload = samples.withUnsafeBytes { Data($0) }
        var output = Data()
        output.appendASCII("RIFF")
        output.appendLittleEndian(UInt32(36 + payload.count))
        output.appendASCII("WAVE")
        output.appendASCII("fmt ")
        output.appendLittleEndian(UInt32(16))
        output.appendLittleEndian(UInt16(1))
        output.appendLittleEndian(UInt16(1))
        output.appendLittleEndian(UInt32(sampleRate))
        output.appendLittleEndian(UInt32(sampleRate * 2))
        output.appendLittleEndian(UInt16(2))
        output.appendLittleEndian(UInt16(16))
        output.appendASCII("data")
        output.appendLittleEndian(UInt32(payload.count))
        output.append(payload)
        return output
    }

    static func write(_ segment: PCMTranscriptionSegment, to url: URL) throws {
        try data(samples: segment.samples, sampleRate: segment.sampleRate).write(to: url, options: .atomic)
    }
}

enum PCM16SampleEncoder {
    static func data(floatSamples: [Float]) -> Data {
        let samples = floatSamples.map { sample -> Int16 in
            let clamped = max(-1, min(1, sample))
            return clamped <= -1 ? Int16.min + 1 : Int16(clamped * Float(Int16.max))
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    static func data(float32Data: Data) -> Data {
        let samples: [Float] = float32Data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
        return data(floatSamples: samples)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(value.data(using: .ascii)!)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
