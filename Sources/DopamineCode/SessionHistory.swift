import Foundation

/// Het logboek, leesbaar gemaakt: welke sessies er zijn geweest en hoe ze eindigden.
///
/// Dit is uitdrukkelijk een lézer. Hij start niets, hij stopt niets, en hij weet niet of er
/// nú iets loopt — het woord "nu" staat hier nergens. Een parser die een AAN-regel zonder
/// afsluitregel als "loopt nog" zou uitleggen, is een tweede idee van "er loopt een sessie",
/// gebaseerd op tekst in plaats van op de kernelvlag. Wat er op dit moment aan de hand is komt
/// uit `AppModel`, en nergens anders vandaan.
///
/// De markeringen waarop gezocht wordt zijn een contract: `verify.sh` grept op exact dezelfde
/// zinnen, en `AppModel` legt bij elke ervan vast dat de aanhef niet verandert. Dus past deze
/// parser zich aan het logboek aan en niet andersom. Beide spellingen doen mee — de schakelaar
/// heette tot 14 augustus 2026 "Blijf actief" — anders verdwijnt alles van vóór die dag
/// geruisloos uit de geschiedenis.
///
/// Alleen Foundation, geen `EventLog`, geen `AppModel`: zo is hij los te compileren tegen een
/// kopie van een echt logboek, en dat is de enige manier om te controleren of hij een sessie
/// zonder afsluitregel écht laat zien in plaats van hem stilletjes te laten vallen.
struct SessionHistory {

    struct Sessie: Identifiable {
        /// Volgnummer in het logboek. Genoeg om een lijst stabiel te houden, en het zegt
        /// meteen iets: hoger is later.
        let id: Int
        var begin: Date
        /// `nil` betekent: er staat geen afsluitregel in het logboek. Niet "hij loopt nog" —
        /// dat kan deze parser niet weten en mag hij dus ook niet beweren.
        var eind: Date?
        /// De gedraaide tijd zoals de afsluitregel hem zelf noemt ("3 u 54 m").
        var gedraaid: String?
        /// Wat er verder in de afsluitregel stond: accu, scherm opnieuw uitgezet, storingen.
        var bijzonderheden: [String] = []
        /// Waarom het wakker houden uitging ("handmatig", "vangnet-timer verlopen").
        var reden: String?
        /// Als een vangnet ingreep: wat het vangnet zei.
        var vangnet: String?
        /// De Mac heeft tijdens deze sessie geslapen terwijl de blokkade aan stond.
        var beloofdeNietGehaald = false
        /// Hoe de sessie begon, als de startregel dat vermeldt (vanaf fase 1).
        var trigger: String?

        var duurdeSeconden: TimeInterval? {
            guard let eind else { return nil }
            return eind.timeIntervalSince(begin)
        }
    }

    var sessies: [Sessie] = []
    /// Hoeveel regels er gelezen zijn. Staat in beeld omdat een leeg lijstje anders niet te
    /// onderscheiden is van "er is nooit een sessie geweest": 0 regels betekent dat er niets
    /// te lezen viel, 4000 regels met 0 sessies betekent dat er iets anders mis is.
    var gelezenRegels = 0
    /// Sessies waarvan het einde niet in het logboek staat.
    var zonderAfsluitregel = 0
    /// Afsluitingen zonder bijbehorend begin — het logboek is geroteerd en het begin is weg.
    var zonderBegin = 0
    var leesfout: String?

    // MARK: - Lezen

    /// Leest het logboek en het archief ernaast.
    ///
    /// Het pad komt van buiten in plaats van hier opnieuw uitgerekend te worden: `EventLog`
    /// bepaalt waar het logboek staat, en twee plekken die dat weten is één plek te veel. Voor
    /// een proefopstelling kan er net zo goed een kopie in.
    static func lees(logboek: URL, limiet: Int = 25) -> SessionHistory {
        var resultaat = SessionHistory()

        // Zoals `verify.sh` het ook doet: het archief eerst, want daar staan de oudste regels.
        // Een sessie die begon vlak voordat het logboek rolde heeft zijn begin in het archief
        // en zijn einde in het huidige bestand.
        let archief = logboek.deletingPathExtension().appendingPathExtension("1.log")
        var regels: [String] = []
        for bestand in [archief, logboek] {
            guard FileManager.default.fileExists(atPath: bestand.path) else {
                // Het archief hoort er meestal niet te zijn; het huidige logboek wel.
                if bestand == logboek {
                    resultaat.leesfout = "Het logboek staat niet op \(bestand.path)."
                }
                continue
            }
            do {
                let inhoud = try String(contentsOf: bestand, encoding: .utf8)
                regels.append(contentsOf: inhoud.split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init))
            } catch {
                // Nooit stil: een onleesbaar logboek levert anders een leeg lijstje op dat er
                // precies zo uitziet als "je hebt de app nog nooit aangezet".
                resultaat.leesfout = "\(bestand.lastPathComponent) kon niet gelezen worden: "
                    + error.localizedDescription
            }
        }
        resultaat.gelezenRegels = regels.count
        resultaat.vulSessies(uit: regels)
        resultaat.sessies = Array(resultaat.sessies.suffix(limiet).reversed())
        return resultaat
    }

    // MARK: - Ontleden

    private static let stempel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private mutating func vulSessies(uit regels: [String]) {
        var open: Sessie?
        /// De laatst gesloten sessie, zolang er nog een UIT-regel achteraan kan komen.
        /// `endSession()` schrijft de afsluitregel namelijk vóór "Wakker houden UIT (…)", en
        /// bij het afsluiten van de app komt die tweede regel helemaal niet.
        var netGesloten: Int?
        var vangnetInDeWacht: String?
        var nummer = 0

        func sluitAf(_ sessie: Sessie) {
            sessies.append(sessie)
            netGesloten = sessies.count - 1
        }

        for regel in regels {
            guard let tijd = Self.tijdstip(van: regel) else { continue }
            let tekst = Self.boodschap(van: regel)

            if Self.isStart(tekst) {
                if var lopende = open {
                    // Een AAN-regel terwijl er nog een sessie openstond: de vorige is nooit
                    // afgesloten. Dat is precies het gat waar het vangnet uit fase 2 voor
                    // bestaat — de app is met kill -9 of een SIGTERM verdwenen — en het hoort
                    // zichtbaar te zijn in plaats van weg te vallen.
                    lopende.vangnet = lopende.vangnet ?? vangnetInDeWacht
                    zonderAfsluitregel += 1
                    sluitAf(lopende)
                }
                nummer += 1
                var nieuw = Sessie(id: nummer, begin: tijd)
                nieuw.trigger = Self.waarde(na: "Gestart via ", in: tekst)
                open = nieuw
                vangnetInDeWacht = nil
                netGesloten = nil
                continue
            }

            if tekst.contains("Vangnet grijpt in: ") {
                vangnetInDeWacht = Self.waarde(na: "Vangnet grijpt in: ", in: tekst)
                open?.vangnet = vangnetInDeWacht
                continue
            }

            if tekst.contains("BELOFTE NIET GEHAALD") {
                open?.beloofdeNietGehaald = true
                continue
            }

            if let staart = Self.rest(na: "Sessie afgesloten — ", in: tekst) {
                guard var lopende = open else {
                    zonderBegin += 1
                    continue
                }
                lopende.eind = tijd
                let delen = staart.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                for deel in delen {
                    if deel.hasPrefix("gedraaid ") {
                        lopende.gedraaid = String(deel.dropFirst("gedraaid ".count))
                    } else {
                        lopende.bijzonderheden.append(deel)
                    }
                }
                lopende.vangnet = lopende.vangnet ?? vangnetInDeWacht
                open = nil
                vangnetInDeWacht = nil
                sluitAf(lopende)
                continue
            }

            // Sluit de app af met een sessie aan, dan schrijft `endSession` wél een afsluitregel
            // maar komt er geen UIT-regel meer achteraan. Zonder deze tak zou zo'n sessie een
            // einde hebben zonder dat er ooit staat waaróm — terwijl het antwoord één regel
            // verderop in het logboek staat.
            if tekst.hasPrefix("Dopamine Code afgesloten"), let index = netGesloten,
               sessies[index].reden == nil {
                sessies[index].reden = "de app werd afgesloten"
                continue
            }

            if let reden = Self.reden(uit: tekst) {
                if var lopende = open {
                    // Een UIT-regel zonder afsluitregel ervoor: dat gebeurt als de sessie
                    // gestopt werd terwijl `endSession` niets te melden had.
                    lopende.eind = tijd
                    lopende.reden = reden
                    lopende.vangnet = lopende.vangnet ?? vangnetInDeWacht
                    open = nil
                    vangnetInDeWacht = nil
                    sluitAf(lopende)
                } else if let index = netGesloten, sessies[index].reden == nil {
                    sessies[index].reden = reden
                }
                continue
            }
        }

        if var lopende = open {
            lopende.vangnet = lopende.vangnet ?? vangnetInDeWacht
            zonderAfsluitregel += 1
            sessies.append(lopende)
        }
    }

    /// De laatste 19 tekens-regel: hetzelfde formaat als `EventLog` schrijft, en hetzelfde
    /// stuk dat `verify.sh` eruit knipt.
    private static func tijdstip(van regel: String) -> Date? {
        guard regel.count >= 19 else { return nil }
        return stempel.date(from: String(regel.prefix(19)))
    }

    /// Alles ná "[INFO] ", "[WARN] " of "[FOUT] ".
    private static func boodschap(van regel: String) -> String {
        guard let haakje = regel.range(of: "] ") else { return regel }
        return String(regel[haakje.upperBound...])
    }

    private static func isStart(_ tekst: String) -> Bool {
        tekst.hasPrefix("Wakker houden AAN") || tekst.hasPrefix("Blijf actief AAN")
    }

    /// De reden tussen de haakjes van "Wakker houden UIT (handmatig)."
    private static func reden(uit tekst: String) -> String? {
        for aanhef in ["Wakker houden UIT (", "Blijf actief UIT ("] where tekst.hasPrefix(aanhef) {
            let staart = tekst.dropFirst(aanhef.count)
            guard let sluit = staart.lastIndex(of: ")") else { return String(staart) }
            return String(staart[staart.startIndex..<sluit])
        }
        return nil
    }

    /// Alles ná een markering tot het eind van de regel, zonder de punt.
    ///
    /// Apart van `waarde` hieronder, dat op de eerste punt stopt: de afsluitregel is één lange
    /// opsomming waarin best een punt kan staan ("LET OP: …"), en die mag niet halverwege
    /// afgekapt worden.
    private static func rest(na markering: String, in tekst: String) -> String? {
        guard let bereik = tekst.range(of: markering) else { return nil }
        var staart = String(tekst[bereik.upperBound...]).trimmingCharacters(in: .whitespaces)
        if staart.hasSuffix(".") { staart.removeLast() }
        return staart.isEmpty ? nil : staart
    }

    /// Het stuk zin na een markering, tot de punt aan het eind van die zin.
    private static func waarde(na markering: String, in tekst: String) -> String? {
        guard let bereik = tekst.range(of: markering) else { return nil }
        let staart = tekst[bereik.upperBound...]
        let einde = staart.firstIndex(of: ".") ?? staart.endIndex
        let waarde = staart[staart.startIndex..<einde].trimmingCharacters(in: .whitespaces)
        return waarde.isEmpty ? nil : waarde
    }
}
