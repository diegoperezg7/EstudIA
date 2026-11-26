import Accelerate
import AVFoundation
import CoreMedia

public enum PCMConversion {
    /// CMSampleBuffer de audio (lo que entrega ScreenCaptureKit) → AVAudioPCMBuffer.
    public static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard sampleBuffer.isValid,
              let desc = sampleBuffer.formatDescription,
              var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

/// Convierte buffers de un formato (48 kHz float del sistema) al que pide el analizador de voz.
/// No es thread-safe: se usa siempre desde la misma cola.
public final class AudioResampler {
    public let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    public func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == outputFormat { return input }
        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
            converter?.primeMethod = .none // sin silencio de cebado entre buffers contiguos
            inputFormat = input.format
        }
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { return nil }
        return output
    }
}

public enum AudioLevel {
    /// Nivel RMS de 0 a 1 de un buffer float32. Para otros formatos devuelve 0.
    public static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for ch in 0..<Int(buffer.format.channelCount) {
            let p = data[ch]
            for i in 0..<n { sum += p[i] * p[i] }
        }
        return min(1, (sum / Float(n * Int(buffer.format.channelCount))).squareRoot())
    }

    /// Por debajo de este RMS (≈ -54 dBFS) se considera silencio.
    public static let silenceThreshold: Float = 0.002
}

/// Espectro del audio en bandas para dibujar ondas que siguen al sonido de verdad: graves, voz, agudos.
/// FFT de 1.024 muestras (unos 21 ms a 48 kHz) con ventana de Hann y bandas logarítmicas.
/// Sube al instante y baja despacio, como un vúmetro. No es thread-safe: se usa siempre desde la cola de audio.
public final class SpectrumAnalyzer {
    public static let size = 1_024
    public let bandCount: Int
    public private(set) var bands: [Float]
    private var ring: [Float]
    private var filled = 0
    private let window: [Float]
    private let dft: vDSP.DiscreteFourierTransform<Float>?
    private let zeros: [Float]

    public init(bands: Int = 7) {
        bandCount = bands
        self.bands = Array(repeating: 0, count: bands)
        ring = Array(repeating: 0, count: Self.size)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)
        dft = try? vDSP.DiscreteFourierTransform(count: Self.size, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        zeros = Array(repeating: 0, count: Self.size)
    }

    /// Añade un buffer (primer canal, float32) y recalcula las bandas.
    public func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: data[0], count: n)
        if n >= Self.size {
            ring = Array(samples.suffix(Self.size))
        } else {
            ring.removeFirst(n)
            ring.append(contentsOf: samples)
        }
        filled = min(Self.size, filled + n)
        update(sampleRate: Float(buffer.format.sampleRate))
    }

    private func update(sampleRate: Float) {
        guard let dft, filled == Self.size else { return }
        let windowed = vDSP.multiply(ring, window)
        let (re, im) = dft.transform(real: windowed, imaginary: zeros)
        let half = Self.size / 2
        let scale: Float = 2 / Float(Self.size)
        var magnitudes = [Float](repeating: 0, count: half)
        for i in 0..<half {
            let power: Float = re[i] * re[i] + im[i] * im[i]
            magnitudes[i] = power.squareRoot() * scale
        }

        // Bandas logarítmicas de 120 Hz a 8 kHz: donde está la voz.
        let low: Float = 120, high = min(8_000, sampleRate / 2)
        let binHz = sampleRate / Float(Self.size)
        for b in 0..<bandCount {
            let f0 = low * pow(high / low, Float(b) / Float(bandCount))
            let f1 = low * pow(high / low, Float(b + 1) / Float(bandCount))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(half, Int(f1 / binHz)))
            let peak = magnitudes[i0..<i1].max() ?? 0
            // -66 dB = silencio, -28 dB = voz fuerte (medido con una clase en el navegador a volumen normal).
            let db = 20 * log10(max(peak, 1e-7))
            let value = min(1, max(0, (db + 66) / 38))
            bands[b] = value > bands[b] ? value : bands[b] * 0.82
        }
    }
}
