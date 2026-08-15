import Foundation

/// Wie de lopende sessie gestart heeft.
///
/// Puur een waardetype: het weet niets, het doet niets en het houdt niets bij. Latere fases
/// voegen hier alleen cases aan toe (het schema, een app die begint, de sneltoets), zodat
/// het paneel en het logboek altijd één plek hebben om te vragen "hoe kwam dit aan".
///
/// Fase 3 voegde de drie triggers toe. Dat ze hier een *waarde* zijn en geen object is de
/// hele afspraak van die fase: een object zou vroeg of laat zijn eigen "loopt er een sessie"
/// gaan bijhouden, en dat is precies de tweede waarheid waar de guardian uit voortkomt.
enum SessionTrigger: Equatable {
    case schakelaar
    case cli
    /// Je hebt vooraf gezegd "ga aan zodra ik de klep dichtdoe", en dat is gebeurd.
    case klepArming
    /// Een app die je als trigger gekozen hebt begon te draaien.
    case app(bundleID: String, naam: String)
    /// Het ingestelde venster ging open.
    case schema(omschrijving: String)
    /// De globale sneltoets is ingedrukt.
    case sneltoets

    /// Wat er in het paneel staat, in gewone taal. Met een hoofdletter aan het begin is het
    /// ook los een zin, en dat is precies hoe het paneel hem gebruikt.
    var zin: String {
        switch self {
        case .schakelaar: return L10n.t("trigger.schakelaar")
        case .cli: return L10n.t("trigger.cli")
        case .klepArming: return L10n.t("trigger.kleparming")
        case .app(_, let naam): return L10n.t("trigger.app", naam)
        case .schema(let omschrijving): return L10n.t("trigger.schema", omschrijving)
        case .sneltoets: return L10n.t("trigger.sneltoets")
        }
    }

    /// Wat er in het logboek komt te staan, kaal — bedoeld voor tussen haakjes.
    var logNaam: String {
        switch self {
        case .schakelaar: return "schakelaar"
        case .cli: return "opdrachtregel"
        case .klepArming: return "klep"
        case .app(_, let naam): return "app \(naam)"
        case .schema: return "schema"
        case .sneltoets: return "sneltoets"
        }
    }

    /// Dezelfde naam, mét het lidwoord dat erbij hoort.
    ///
    /// Nodig omdat één logregel er een lopende zin van maakt ("Gestart via …"), en een vast
    /// "de" ervoor plakken leverde "Gestart via de schema" op — in het logboek én in
    /// Instellingen → Geschiedenis, die deze regel terugleest. Het lidwoord hoort bij het
    /// woord, dus staat het hier en niet op de plek die de zin bouwt.
    var metLidwoord: String {
        switch self {
        case .schakelaar: return L10n.t("aanleiding.schakelaar")
        case .cli: return L10n.t("aanleiding.cli")
        case .klepArming: return L10n.t("aanleiding.klep")
        case .app(_, let naam): return L10n.t("aanleiding.app", naam)
        case .schema: return L10n.t("aanleiding.schema")
        case .sneltoets: return L10n.t("aanleiding.sneltoets")
        }
    }

    /// Mag deze ingang een wachtwoordvenster oproepen?
    ///
    /// Alleen als er aantoonbaar iemand aan het toetsenbord zit. Een buildscript is dat
    /// niet, en `Shell.runAsAdmin` wacht tot 180 seconden op een antwoord dat nooit komt —
    /// dat is een script dat drie minuten stilstaat zonder te zeggen waarom. Een trigger is
    /// het al helemaal niet: die gaat af om 09:00 terwijl jij in de trein zit, of op het
    /// moment dat de klep net dicht is en het scherm op slot staat.
    /// De sneltoets mag het wél: je hebt er net drie toetsen voor ingedrukt, dus je zit er.
    var mayPrompt: Bool {
        switch self {
        case .schakelaar, .sneltoets: return true
        case .cli, .klepArming, .app, .schema: return false
        }
    }

    /// Ging dit vanzelf, zonder dat iemand er op dat moment iets voor deed?
    ///
    /// Bepaalt of een geweigerde start een melding waard is. Bij de schakelaar staat het
    /// antwoord al in het paneel waar je net op geklikt hebt, en bij de opdrachtregel krijgt
    /// het script de weigerzin woordelijk terug; bij een trigger ziet niemand iets, en dan
    /// is stil blijven precies de fout die harde regel 3 verbiedt.
    var isAutomatisch: Bool {
        switch self {
        case .schakelaar, .cli, .sneltoets: return false
        case .klepArming, .app, .schema: return true
        }
    }
}
