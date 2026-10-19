import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

// Candidato 2 de #22: Gemma 4 corriendo en el iPhone con MLX Swift.
// A diferencia del modelo del sistema, los pesos se descargan de Hugging Face (MLX Community) la primera vez.

enum GemmaVariant: String, CaseIterable, Identifiable {
    case e2b, e4b
    var id: String { rawValue }
    var title: String { self == .e2b ? "Gemma 4 E2B" : "Gemma 4 E4B" }
    var sizeNote: String { self == .e2b ? "≈ 3,5 GB" : "más grande y lento" }
    var configuration: ModelConfiguration { self == .e2b ? LLMRegistry.gemma4_e2b_it_4bit : LLMRegistry.gemma4_e4b_it_4bit }
}

@MainActor final class GemmaEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)     // 0…1
        case loading                 // pesos ya en disco, pasándolos a memoria
        case ready
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published private(set) var loadSeconds: Double?
    private(set) var variant: GemmaVariant?
    private var container: ModelContainer?

    var isReady: Bool { state == .ready }

    /// Descarga (si hace falta) y carga el modelo. Con otra variante, descarta la anterior.
    func load(_ v: GemmaVariant) async {
        if variant == v, container != nil { return }
        unload()
        variant = v
        state = .downloading(0)
        let t0 = ContinuousClock.now
        do {
            let c = try await #huggingFaceLoadModelContainer(configuration: v.configuration) { [weak self] p in
                let f = p.fractionCompleted
                Task { @MainActor in
                    guard let self, case .downloading = self.state else { return }
                    self.state = f >= 1 ? .loading : .downloading(f)
                }
            }
            container = c
            let d = ContinuousClock.now - t0
            loadSeconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
            state = .ready
        } catch {
            variant = nil
            state = .failed(error.localizedDescription)
        }
    }

    func unload() {
        container = nil
        variant = nil
        loadSeconds = nil
        state = .idle
    }

    /// Respuesta en streaming: `onText` recibe el texto acumulado; devuelve los tokens generados según MLX.
    func respond(instructions: String, prompt: String, onText: @MainActor (String) -> Void) async throws -> Int? {
        guard let container else { return nil }
        let session = ChatSession(container, instructions: instructions,
                                  generateParameters: GenerateParameters(maxTokens: 400, temperature: 0.3))
        var text = "", tokens: Int?
        for try await event in session.streamDetails(to: prompt) {
            if let c = event.chunk { text += c; onText(text) }
            if let i = event.info { tokens = i.generationTokenCount }
        }
        return tokens
    }
}
