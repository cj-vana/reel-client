import Accelerate
import Foundation

/// Finds the stretch of audio two episodes share, such as the theme over the opening titles or the music under
/// the end credits. Each 64 ms step becomes 32 bits, one per pair of neighboring frequency bands, set when the
/// energy difference between the two bands grows from the step before (Haitsma and Kalker's audio fingerprint).
/// Matching steps from the same recording differ in a few bits; unrelated audio differs in about half of them.
///
/// This follows `apps/web/src/audio-fingerprint.ts` step for step, so every client finds the same boundaries.
enum AudioFingerprint {
    static let sampleRate = 8000.0
    static let frame = 2048
    static let hop = 512
    static let stepSeconds = Double(hop) / sampleRate
    private static let bands = 33
    private static let lowHz = 300.0
    private static let highHz = 3400.0
    /// Steps quieter than about -55 dBFS carry no usable spectrum; two silent stretches would otherwise match.
    private static let quietLevel = 3.2e-6
    /// The same audio a fraction of a step out of line differs in about 8 of 32 bits; unrelated audio in 16.
    private static let matchBits = 12.5
    private static let window = 15
    /// A run survives up to 4 seconds of poorer matches, such as a sound effect over the theme.
    private static let gap = 64
    private static let keys = 1 << 16
    private static let bucketLimit = 256
    private static let candidates = 8
    private static let minVotes = 6

    struct Print: Sendable, Equatable {
        let bits: [UInt32]
        let quiet: [Bool]
    }

    /// Seconds from the start of each print.
    struct Run: Sendable, Equatable {
        let aStart: Double, aEnd: Double, bStart: Double, bEnd: Double
    }

    private static let hann: [Float] = (0..<frame).map { 0.5 - 0.5 * Float(cos(2 * Double.pi * Double($0) / Double(frame - 1))) }
    private static let bandRanges: [Range<Int>] = (0..<bands).map { band in
        let edge = { (index: Int) -> Int in Int((lowHz * pow(highHz / lowHz, Double(index) / Double(bands)) * Double(frame) / sampleRate).rounded()) }
        let from = edge(band)
        return from..<max(from + 1, edge(band + 1))
    }

    /// Fingerprints mono samples at `sampleRate`.
    static func make(_ samples: [Float]) -> Print {
        let steps = samples.count < frame ? 0 : (samples.count - frame) / hop + 1
        guard steps > 0 else { return Print(bits: [], quiet: []) }
        let log2n = vDSP_Length(log2(Double(frame)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return Print(bits: [], quiet: []) }
        defer { vDSP_destroy_fftsetup(setup) }
        let windowPower = hann.reduce(0) { $0 + Double($1 * $1) }
        var energy = [Double](repeating: 0, count: steps * bands)
        var quiet = [Bool](repeating: true, count: steps)
        var windowed = [Float](repeating: 0, count: frame)
        var real = [Float](repeating: 0, count: frame / 2), imaginary = [Float](repeating: 0, count: frame / 2)
        for step in 0..<steps {
            var power = 0.0
            for i in 0..<frame {
                let value = samples[step * hop + i] * hann[i]
                windowed[i] = value; power += Double(value * value)
            }
            quiet[step] = power / windowPower < quietLevel
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frame / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frame / 2)) }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            for band in 0..<bands {
                var sum = 0.0
                for k in bandRanges[band] { sum += Double(real[k] * real[k] + imaginary[k] * imaginary[k]) }
                energy[step * bands + band] = sum
            }
        }
        var bits = [UInt32](repeating: 0, count: steps)
        for step in 1..<max(1, steps) {
            var value: UInt32 = 0
            let now = step * bands, before = now - bands
            for band in 0..<(bands - 1) where energy[now + band] - energy[now + band + 1] - (energy[before + band] - energy[before + band + 1]) > 0 {
                value |= 1 << UInt32(band)
            }
            bits[step] = value
        }
        quiet[0] = true
        return Print(bits: bits, quiet: quiet)
    }

    /// The longest stretch of audio both prints contain, if it lasts between the two limits. A longer match means
    /// the two files share far more than a theme, such as two copies of one episode, so it is not reported.
    static func sharedRun(_ a: Print, _ b: Print, minSeconds: Double, maxSeconds: Double) -> Run? {
        guard !a.bits.isEmpty, !b.bits.isEmpty else { return nil }
        var best: (first: Int, last: Int, offset: Int)?
        for candidate in candidateOffsets(a, b) {
            for offset in [candidate - 1, candidate, candidate + 1] {
                if let run = longestRun(a, b, offset: offset), best == nil || run.last - run.first > best!.last - best!.first {
                    best = (run.first, run.last, offset)
                }
            }
        }
        guard let best else { return nil }
        let seconds = Double(best.last + 1 - best.first) * stepSeconds
        guard seconds >= minSeconds, seconds <= maxSeconds else { return nil }
        return Run(aStart: Double(best.first) * stepSeconds, aEnd: Double(best.last + 1) * stepSeconds,
                   bStart: Double(best.first - best.offset) * stepSeconds, bEnd: Double(best.last + 1 - best.offset) * stepSeconds)
    }

    /// Offsets (a step minus b step) where many 16-bit halves of the two prints are equal.
    private static func candidateOffsets(_ a: Print, _ b: Print) -> [Int] {
        let n = a.bits.count, m = b.bits.count
        var start = [Int](repeating: 0, count: 2 * keys + 1)
        for j in 0..<m where !b.quiet[j] { start[Int(b.bits[j] >> 16) + 1] += 1; start[keys + Int(b.bits[j] & 0xffff) + 1] += 1 }
        for key in 1...(2 * keys) { start[key] += start[key - 1] }
        var fill = start, positions = [Int](repeating: 0, count: start[2 * keys])
        for j in 0..<m where !b.quiet[j] {
            positions[fill[Int(b.bits[j] >> 16)]] = j; fill[Int(b.bits[j] >> 16)] += 1
            positions[fill[keys + Int(b.bits[j] & 0xffff)]] = j; fill[keys + Int(b.bits[j] & 0xffff)] += 1
        }
        var votes = [Int](repeating: 0, count: n + m + 1)
        for i in 0..<n where !a.quiet[i] {
            for key in [Int(a.bits[i] >> 16), keys + Int(a.bits[i] & 0xffff)] {
                let from = start[key], to = start[key + 1]
                // Halves shared by hundreds of steps come from tones and hum, not from anything worth lining up.
                guard to - from <= bucketLimit else { continue }
                for p in from..<to { votes[i - positions[p] + m] += 1 }
            }
        }
        var peaks: [(total: Int, offset: Int)] = []
        for k in 1..<(votes.count - 1) {
            let total = votes[k - 1] + votes[k] + votes[k + 1]
            if total >= minVotes, votes[k] >= votes[k - 1], votes[k] >= votes[k + 1] { peaks.append((total, k - m)) }
        }
        // Stable on ties, like the web client's sort, so both clients consider the same candidates.
        let ordered = peaks.enumerated().sorted { $0.element.total != $1.element.total ? $0.element.total > $1.element.total : $0.offset < $1.offset }.map(\.element)
        var chosen: [Int] = []
        for peak in ordered where !chosen.contains(where: { abs($0 - peak.offset) <= 2 }) {
            chosen.append(peak.offset)
            if chosen.count == candidates { break }
        }
        return chosen
    }

    private static func differingBits(_ value: UInt32) -> Int { value.nonzeroBitCount }

    /// The longest stretch of matching steps at one offset, as a step range in `a`, allowing short gaps.
    private static func longestRun(_ a: Print, _ b: Print, offset: Int) -> (first: Int, last: Int)? {
        let from = max(0, offset), to = min(a.bits.count, b.bits.count + offset), length = to - from
        guard length > 0 else { return nil }
        var total = [Double](repeating: 0, count: length + 1)
        for t in 0..<length {
            let i = from + t, j = i - offset
            total[t + 1] = total[t] + Double(a.quiet[i] || b.quiet[j] ? 16 : differingBits(a.bits[i] ^ b.bits[j]))
        }
        func average(_ first: Int, _ last: Int) -> Double {
            let low = max(0, first), high = min(length - 1, last)
            return (total[high + 1] - total[low]) / Double(high - low + 1)
        }
        var best: (Int, Int)?, runStart = -1, lastMatch = -1
        func close() { if runStart >= 0, best == nil || lastMatch - runStart > best!.1 - best!.0 { best = (runStart, lastMatch) } }
        for t in 0..<length where average(t - window, t + window) <= matchBits {
            if runStart < 0 || t - lastMatch > gap { close(); runStart = t }
            lastMatch = t
        }
        close()
        guard var (first, last) = best else { return nil }
        // The averaging window lets a run spill a little past the shared audio; trim edges that do not match closely.
        while first < last, average(first, first + 4) > matchBits { first += 1 }
        while last > first, average(last - 4, last) > matchBits { last -= 1 }
        return (from + first, from + last)
    }
}
