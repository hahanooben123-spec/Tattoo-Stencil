import Foundation

enum LocalAIError: LocalizedError {
    case busy, notInstalled, memory, storage, noImage, dimensions, invalidImage, checksum(String)
    var errorDescription: String? {
        switch self {
        case .busy: return "En behandling afsluttes stadig. Vent et øjeblik."
        case .notInstalled: return "Hent og kontrollér modellen først."
        case .memory: return "Prototypen kræver en iPad med mindst 8 GB RAM."
        case .storage: return "Der skal være mindst 12 GB ledig plads til modellen."
        case .noImage: return "Modellen leverede ikke et billede."
        case .dimensions: return "Modellen ændrede billedets størrelse. Resultatet blev afvist."
        case .invalidImage: return "Billedet kunne ikke åbnes. Vælg et andet referencebillede."
        case .checksum(let file): return "Modelfilen \(file) bestod ikke kontrollen. Hent modellen igen."
        }
    }
}
