import AVFoundation
import CoreMedia
import Testing
@testable import StudyAICore

@Suite struct ChunkerTests {
    @Test func respectsLimitAndKeepsAllText() {
        let text = (1...200).map { "Esta es la frase número \($0) de la clase de derecho." }.joined(separator: " ")
        let chunks = Chunker.chunk(text, maxChars: 500)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 500 })
        #expect(chunks.joined(separator: " ") == text)
    }

    @Test func splitsSentenceLongerThanLimit() {
        let chunks = Chunker.chunk(String(repeating: "a", count: 1250), maxChars: 500)
        #expect(chunks.map(\.count) == [500, 500, 250])
    }

    @Test func emptyText() {
        #expect(Chunker.chunk("   ", maxChars: 100).isEmpty)
    }
}

@Suite struct RetrieverTests {
    @Test func ranksByMatchesAndKeepsLectureOrder() {
        let chunks = [
            "La fotosíntesis convierte la luz en energía química.",
            "El ciclo de Krebs ocurre en la mitocondria.",
            "La mitocondria produce ATP. La mitocondria tiene doble membrana.",
        ]
        #expect(Retriever.top(chunks, for: "¿Qué hace la MITOCONDRIA?", k: 2) == [chunks[1], chunks[2]])
        #expect(Retriever.top(chunks, for: "fotosintesis", k: 2) == [chunks[0]]) // sin tilde también
    }
}

@Suite struct FormatTests {
    @Test func clock() {
        #expect(TimeFormat.clock(0) == "0:00")
        #expect(TimeFormat.clock(75.9) == "1:15")
        #expect(TimeFormat.clock(3725) == "1:02:05")
    }

    @Test func markdownHasAllSections() {
        let md = MarkdownExport.render(
            title: "Tema 3", subject: "Biología", date: Date(timeIntervalSince1970: 0), duration: 3600,
            summary: "Resumen.", notes: "### Bloque\n- idea", questions: ["¿Qué es el ATP?"], userNotes: "Entra en el examen",
            segments: [.init(start: 0, text: "Hola.", isGap: false, speaker: "Ana"),
                       .init(start: 30, text: "Sigo.", isGap: false, speaker: "Ana"),
                       .init(start: 60, text: "audio interrumpido", isGap: true),
                       .init(start: 90, text: "Pregunto.", isGap: false, speaker: "Luis")])
        for needle in ["# Tema 3", "Biología", "Duración 1:00:00", "## Resumen", "## Apuntes",
                       "1. ¿Qué es el ATP?", "**0:00** **Ana:** Hola.", "**0:30** Sigo.", "**1:30** **Luis:** Pregunto.",
                       "*[1:00 · audio interrumpido]*", "1970", "## Mis notas\n\nEntra en el examen"] {
            #expect(md.contains(needle), "falta \(needle)")
        }
    }
}

@Suite struct AudioTests {
    static func sine(frames: Int, rate: Double, amplitude: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buf.floatChannelData![0][i] = amplitude * sin(Float(i) * 2 * .pi * 440 / Float(rate)) }
        return buf
    }

    /// Construye un CMSampleBuffer como los de ScreenCaptureKit.
    static func sampleBuffer(from pcm: AVAudioPCMBuffer) -> CMSampleBuffer {
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: desc, sampleCount: CMItemCount(pcm.frameLength), sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        CMSampleBufferSetDataBufferFromAudioBufferList(sb!, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: pcm.audioBufferList)
        return sb!
    }

    @Test func sampleBufferRoundTrip() {
        let pcm = Self.sine(frames: 1024, rate: 48_000, amplitude: 0.5)
        let out = PCMConversion.pcmBuffer(from: Self.sampleBuffer(from: pcm))
        #expect(out?.frameLength == 1024)
        #expect(out?.format.sampleRate == 48_000)
        #expect(out?.floatChannelData?[0][100] == pcm.floatChannelData![0][100])
    }

    @Test func resamplesTo16kInt16() {
        let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let resampler = AudioResampler(outputFormat: target)
        var total: AVAudioFrameCount = 0
        for _ in 0..<100 { total += resampler.convert(Self.sine(frames: 4800, rate: 48_000, amplitude: 0.5))?.frameLength ?? 0 }
        // 100 × 4800 a 48 kHz = 10 s → ~160.000 frames. El filtro retiene ~200 fijos: sin deriva en clases largas.
        #expect(abs(Int(total) - 160_000) < 100, "total=\(total)")
    }

    @Test func rms() {
        #expect(AudioLevel.rms(Self.sine(frames: 4800, rate: 48_000, amplitude: 0)) == 0)
        let level = AudioLevel.rms(Self.sine(frames: 4800, rate: 48_000, amplitude: 1))
        #expect(abs(level - 0.707) < 0.01)
    }

    @Test func spectrumFollowsTheSound() {
        let analyzer = SpectrumAnalyzer(bands: 7)
        analyzer.process(Self.sine(frames: 2048, rate: 48_000, amplitude: 0.3))
        // 440 Hz cae en la tercera banda (400-730 Hz; 120 Hz-8 kHz en escala logarítmica) y es la más alta.
        let tone = analyzer.bands
        #expect(tone.firstIndex(of: tone.max()!) == 2, "\(tone)")
        #expect(tone[2] > 0.5 && tone[6] < 0.2, "\(tone)")
        // En silencio, las bandas caen hasta casi cero.
        for _ in 0..<40 { analyzer.process(Self.sine(frames: 960, rate: 48_000, amplitude: 0)) }
        #expect(analyzer.bands.allSatisfy { $0 < 0.02 }, "\(analyzer.bands)")
    }
}

@Suite struct ParagrapherTests {
    @Test func splitsAtSentenceEndAfterMinimum() {
        let words = "Uno dos tres. Cuatro cinco seis. Siete ocho.".split(separator: " ")
        let pieces = words.enumerated().map { i, w in
            Paragrapher.Piece(text: (i == 0 ? "" : " ") + w, start: Double(i), end: Double(i) + 0.9)
        }
        let paras = Paragrapher.split(pieces, fallbackStart: 0, fallbackEnd: 8, minChars: 10)
        #expect(paras.map(\.text) == ["Uno dos tres.", "Cuatro cinco seis.", "Siete ocho."])
        #expect(paras.map(\.start) == [0, 3, 6])
        #expect(paras.last?.end == 7.9)
    }

    @Test func piecesWithoutTimesUseFallback() {
        let paras = Paragrapher.split([.init(text: "Hola.", start: nil, end: nil)], fallbackStart: 12, fallbackEnd: 15)
        #expect(paras.count == 1)
        #expect(paras[0].start == 12)
    }

    @Test func shortResultsJoinThePreviousParagraph() {
        let long = String(repeating: "El contrato exige consentimiento, objeto y causa. ", count: 10).trimmingCharacters(in: .whitespaces)
        let merged = Paragrapher.mergeShort([
            (start: 0, end: 4, text: "Buenos días."),
            (start: 4, end: 6, text: "Vamos a empezar"),
            (start: 6, end: 40, text: long),
            (start: 40, end: 41, text: "¿Vale?"),
            (start: 41, end: 75, text: long),
        ])
        // Los trozos cortos se pegan; un párrafo largo y cerrado abre otro.
        #expect(merged.count == 2)
        #expect(merged[0].text.hasPrefix("Buenos días. Vamos a empezar El contrato"))
        #expect(merged[0].text.hasSuffix("¿Vale?"))
        #expect(merged[0].end == 41)
        #expect(merged[1].start == 41)
        // Repetirlo no cambia nada.
        #expect(Paragrapher.mergeShort(merged).map(\.text) == merged.map(\.text))
    }

    @Test func doesNotJoinAcrossPauseSpeakerOrLimit() {
        #expect(!Paragrapher.continues(previous: "Hola.", previousEnd: 10, next: "Seguimos.", nextStart: 45))
        #expect(!Paragrapher.continues(previous: "Hola.", previousEnd: 10, next: "Seguimos.", nextStart: 11, sameSpeaker: false))
        #expect(!Paragrapher.continues(previous: String(repeating: "a", count: 1_195), previousEnd: 10, next: "Seguimos.", nextStart: 11))
        #expect(Paragrapher.continues(previous: "Hola.", previousEnd: 10, next: "Seguimos.", nextStart: 11))
    }
}

@Suite struct CitationsTests {
    let paragraphs = [
        "Buenas tardes, hoy empezamos el tema de la teoría general del contrato.",
        "Los vicios del consentimiento son el error, la violencia, la intimidación y el dolo.",
        "La anulabilidad solo la puede ejercitar la parte perjudicada y el plazo es de cuatro años.",
        "El objeto debe ser posible, lícito y determinado. No se puede contratar sobre la herencia futura.",
    ]

    @Test func findsTheParagraphBehindEachSentence() {
        let c = Citations(paragraphs: paragraphs)
        #expect(c.source(for: "El consentimiento puede estar viciado por error, violencia o dolo.") == 1)
        #expect(c.source(for: "La acción de anulabilidad prescribe a los cuatro años.") == 2)
        #expect(c.source(for: "No cabe contratar sobre una herencia futura.") == 3)
        #expect(c.source(for: "El tiempo hoy es soleado en Madrid.") == nil)
    }

    @Test func numbersSourcesInOrderAndReusesThem() {
        let c = Citations(paragraphs: paragraphs)
        let out = c.annotate("La herencia futura no puede ser objeto. Los vicios son error y dolo. El objeto ha de ser lícito y posible.")
        #expect(out.map(\.number) == [1, 2, 1])
        #expect(out.map(\.source) == [3, 1, 3])
    }
}

@Suite struct MCPTests {
    let server = MCPServer {
        LibraryExport(lectures: [.init(
            id: "1", title: "Tema 2: inventarios", subject: "Gestión de almacenes", date: .now, duration: 3600, language: "Español",
            summary: "El stock de seguridad cubre la demanda incierta.", notes: nil, questions: ["¿Qué es el EOQ?"], userNotes: "",
            transcript: [.init(start: 75, text: "El lote económico de pedido equilibra costes.", speaker: nil)])])
    }

    func call(_ json: String) -> [String: Any] {
        let out = server.handle(json) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]) ?? [:]
    }

    func text(_ r: [String: Any]) -> String {
        (((r["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    @Test func handshakeAndTools() {
        let i = call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
        #expect((i["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
        #expect(server.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let t = call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(((t["result"] as? [String: Any])?["tools"] as? [Any])?.count == 3)
    }

    @Test func listReadSearch() {
        #expect(text(call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"listar_clases","arguments":{"asignatura":"almacenes"}}}"#)).contains("id: 1"))
        let read = text(call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"leer_clase","arguments":{"id":"1"}}}"#))
        #expect(read.contains("stock de seguridad") && read.contains("EOQ"))
        let hit = text(call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"buscar","arguments":{"texto":"lote economico"}}}"#))
        #expect(hit.contains("1:15"))
    }
}

@Suite struct SlideTests {
    @Test func readsSlideXML() {
        let xml = """
            <p:sld><a:p><a:r><a:rPr lang="es"/><a:t>Vicios del </a:t></a:r><a:r><a:t>consentimiento</a:t></a:r></a:p>\
            <a:p><a:r><a:t xml:space="preserve">Error, dolo &amp; violencia</a:t></a:r></a:p></p:sld>
            """
        #expect(SlideText.fromXML(xml) == "Vicios del consentimiento\nError, dolo & violencia")
    }

    @Test func followsTheLectureThroughTheSlides() {
        let pages = [
            "Tema 4. Teoría general del contrato. Concepto: acuerdo de voluntades",
            "Elementos esenciales: consentimiento, objeto y causa. Artículo 1261",
            "Vicios del consentimiento: error, violencia, intimidación y dolo",
            "Nulidad y anulabilidad. Plazo de caducidad de cuatro años",
        ]
        let paragraphs = [
            "Buenas tardes, empezamos.",
            "El contrato es un acuerdo de voluntades que crea obligaciones.",
            "El artículo 1261 dice que hacen falta consentimiento, objeto y causa.",
            "Vale, seguimos.",
            "El dolo y la intimidación vician el consentimiento, igual que el error.",
            "La anulabilidad tiene un plazo de caducidad de cuatro años.",
        ]
        #expect(SlideAligner.align(paragraphs: paragraphs, pages: pages) == [nil, 0, 1, 1, 2, 3])
    }
}
