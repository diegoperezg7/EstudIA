import AVFoundation
import CoreImage
import os
import ScreenCaptureKit
import StudyAICore

enum CaptureError: LocalizedError {
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No se encontró ninguna pantalla que capturar."
        case .permissionDenied: "EstudIA no tiene permiso de «Grabación de pantalla y audio del sistema»."
        }
    }
}

/// Captura el audio interno del Mac con ScreenCaptureKit. El micrófono queda desactivado.
/// Al capturar todo el sistema, da igual que la clase suene en Safari, Chrome u otra app.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Se llama en la cola de audio con cada buffer (~20 ms).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// El stream se detuvo por un error o porque la usuaria paró la captura desde el menú del sistema.
    var onStop: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "studyai.audio", qos: .userInitiated)
    /// Con fotogramas, la pantalla se muestrea cada pocos segundos para saber quién habla. Nunca se guarda.
    private let wantsFrames: Bool
    /// Último fotograma y cuántos distintos han llegado: SCK solo entrega «completo» cuando la pantalla cambia.
    private let frame = OSAllocatedUnfairLock<(image: CGImage?, count: Int)>(initialState: (nil, 0))
    private let ciContext = CIContext()

    init(wantsFrames: Bool = false) {
        self.wantsFrames = wantsFrames
    }

    /// El último fotograma de la pantalla (sin las ventanas de StudyAI), si se pidieron.
    var latestFrame: (image: CGImage?, count: Int) { frame.withLock { $0 } }

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenAudioPermission.isGranted ? error : CaptureError.permissionDenied
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = false // requisito: nada de micrófono
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        if wantsFrames {
            // Un fotograma cada 2 s al tamaño de la pantalla en puntos: los rótulos de nombre tienen que poder leerse.
            config.width = display.width
            config.height = display.height
            config.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        } else {
            // ScreenCaptureKit siempre captura vídeo; lo dejamos en lo mínimo y se descarta.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        config.queueDepth = 3
        config.showsCursor = false

        // Sin la píldora ni la ventana de StudyAI en el fotograma.
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // Sin salida de pantalla, SCK registra un error por cada fotograma descartado.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        queue.sync {} // espera a que termine el último buffer en vuelo antes de cerrar el transcriptor
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            guard let pcm = PCMConversion.pcmBuffer(from: sampleBuffer) else { return }
            onBuffer?(pcm)
        case .screen:
            guard wantsFrames, Self.isComplete(sampleBuffer), let pixels = sampleBuffer.imageBuffer else { return }
            let image = CIImage(cvPixelBuffer: pixels)
            // Se copia a un CGImage para no retener el búfer de SCK (su reserva es de solo 3).
            if let cg = ciContext.createCGImage(image, from: image.extent) { frame.withLock { $0 = (cg, $0.count + 1) } }
        default:
            break
        }
    }

    /// SCK también entrega fotogramas «sin cambios» o vacíos: solo sirven los completos.
    private static func isComplete(_ buffer: CMSampleBuffer) -> Bool {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream else { return }
        self.stream = nil
        onStop?(error)
    }
}

extension Error {
    /// La usuaria pulsó «Dejar de compartir» en el indicador de grabación del sistema.
    var isUserStoppedCapture: Bool {
        (self as NSError).domain == SCStreamErrorDomain && (self as NSError).code == SCStreamError.Code.userStopped.rawValue
    }
}
