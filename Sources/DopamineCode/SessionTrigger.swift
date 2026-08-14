import Foundation

/// Wie de lopende sessie gestart heeft.
///
/// Puur een waardetype: het weet niets, het doet niets en het houdt niets bij. Latere fases
/// voegen hier alleen cases aan toe (het schema, een app die begint, de sneltoets), zodat
/// het paneel en het logboek altijd één plek hebben om te vragen "hoe kwam dit aan".
enum SessionTrigger: Equatable {
    case schakelaar
    case cli

    /// Wat er in het paneel staat, in gewone taal.
    var zin: String {
        switch self {
        case .schakelaar: return "met de schakelaar aangezet"
        case .cli: return "vanaf de opdrachtregel aangezet"
        }
    }

    /// Wat er in het logboek komt te staan.
    var logNaam: String {
        switch self {
        case .schakelaar: return "schakelaar"
        case .cli: return "opdrachtregel"
        }
    }

    /// Mag deze ingang een wachtwoordvenster oproepen?
    ///
    /// Alleen als er aantoonbaar iemand aan het toetsenbord zit. Een buildscript is dat
    /// niet, en `Shell.runAsAdmin` wacht tot 180 seconden op een antwoord dat nooit komt —
    /// dat is een script dat drie minuten stilstaat zonder te zeggen waarom.
    var mayPrompt: Bool {
        switch self {
        case .schakelaar: return true
        case .cli: return false
        }
    }
}
