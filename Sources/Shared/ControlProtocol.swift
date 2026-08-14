import Foundation
import Darwin

/// Het besturingskanaal tussen de app en de `dopamine`-opdrachtregel.
///
/// Dit bestand wordt in **beide** binaries meegecompileerd en mag daarom niets kennen van
/// de app: geen `EventLog` (dat is het bestand dat `verify.sh` leest — de CLI heeft daar
/// niets te zoeken), geen `SleepFlag`, geen IOKit, geen `pmset`. Het beschrijft alleen hoe
/// een vraag en een antwoord eruitzien en hoe je de socket opent.
///
/// **Waarom een unix domain socket en niet XPC of een bestand-mailbox.**
/// XPC vraagt een Mach-servicenaam, en die kun je alleen registreren via een launchd-job.
/// Deze app heeft die niet gegarandeerd — `LaunchAtLogin` schrijft er hooguit één als
/// terugval — dus XPC zou een LaunchAgent verplicht maken en daarmee een keuze uit fase 2
/// vooruit beslissen. Een bestand-mailbox valt af omdat er geen antwoordkanaal is: dan kan
/// `dopamine on` niet melden dát de kernelschrijf mislukte, en blijft een commando liggen
/// dat later wordt uitgevoerd in een situatie waarin niemand erom vroeg. De socket bestaat
/// alleen zolang de app draait, dus "de app draait niet" is gewoon een `connect()`-fout die
/// eerlijk gemeld kan worden in plaats van gegokt.
enum ControlChannel {

    // MARK: - Waar hij staat

    static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Dopamine Code", isDirectory: true)
    }

    static var socketPath: String {
        directoryURL.appendingPathComponent("beheer.sock").path
    }

    /// `sun_path` is 104 bytes inclusief de afsluitende nul, dus 103 bruikbare tekens.
    /// Gemeten op deze Mac: het pad is 74 bytes. Een langere gebruikersnaam kan daar
    /// overheen gaan, en dan moet je dat lezen in plaats van een onverklaarbare bind-fout.
    static let maxPathLength = 103

    // MARK: - Wat er over de lijn gaat

    /// Eén regel JSON per bericht, afgesloten met `\n`. Eén vraag per verbinding, daarna
    /// gaat hij dicht: een commandoregel is geen sessie.
    struct Request: Codable, Sendable {
        enum Soort: String, Codable, Sendable {
            case aan
            case uit
            case status
        }

        var soort: Soort
        /// Gevraagde duur in minuten. `nil` = de duur die in het paneel staat.
        var minuten: Int?
        /// Waaraan de sessie gekoppeld moet worden. `nil` = alleen de timer.
        var pid: Int32?
        /// Harde bovengrens (`--until`). De tijdslimiet blijft er als plafond overheen gaan.
        var nietLaterDan: Date?
    }

    /// Het antwoord bevat de kernelvlag én het beeld van de app als twee losse velden.
    /// Onenigheid tussen die twee is precies waar deze app voor bestaat; die wegpoetsen tot
    /// één "aan/uit" zou de enige interessante toestand onzichtbaar maken.
    struct Response: Codable, Sendable {
        var gelukt: Bool
        /// Eén Nederlandse zin, ook wat de CLI zonder `--json` afdrukt.
        var zin: String
        /// 0 gelukt, 1 geweigerd door een vangnet, 2 verkeerd gebruik, 4 app draait niet.
        var code: Int32

        /// Vers uit de kernel gelezen bij elk verzoek, nooit uit een cache. Ontbreekt als de
        /// eigenschap niet te lezen was — dat is iets anders dan "de Mac mag slapen".
        var kernelvlag: Bool? = nil
        /// Wat de app zelf denkt. Wijkt dit af van `kernelvlag`, dan is er iets aan de hand.
        var sessieLoopt: Bool = false
        var appStatus: String = "onbekend"
        var vangnettenUitgeschakeld: Bool = false

        var gestartOp: Date? = nil
        var eindtijd: Date? = nil
        var duurMinuten: Int? = nil
        var trigger: String? = nil
        var procesPid: Int32? = nil
        var procesNaam: String? = nil

        var accuProcent: Int? = nil
        var opLader: Bool? = nil
        var klepDicht: Bool? = nil

        /// Voor de gevallen waarin de app niet eens bereikt werd.
        static func lokaal(zin: String, code: Int32) -> Response {
            Response(gelukt: false, zin: zin, code: code)
        }
    }

    // MARK: - Coderen

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder().encode(value)
        data.append(0x0A)
        return data
    }

    // MARK: - Sockets

    /// Vult een `sockaddr_un`. Geeft `nil` als het pad niet past — nooit stilzwijgend
    /// afkappen, want dan bind je op een ander pad dan je denkt.
    static func address(for path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8)
        guard bytes.count <= maxPathLength else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let ruimte = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: ruimte) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return addr
    }

    /// Een dichte kant van de verbinding mag dit proces niet omleggen. Zonder dit levert een
    /// CLI die na een timeout weggelopen is een SIGPIPE op — en die zou de app afschieten
    /// terwijl de vlag aan staat, wat exact de fout is die dit project nooit mag maken.
    static func suppressSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    enum ConnectResult {
        case verbonden(Int32)
        /// Geen socket, of niemand die luistert: de app draait niet. Een verweesd
        /// socketbestand na `kill -9` geeft ECONNREFUSED en hoort in dezelfde bak.
        case appDraaitNiet
        case fout(String)
    }

    /// Verbindt met de draaiende app. Start hem nooit zelf: twee processen die allebei de
    /// vlag beheren is exact het conflict dat we Amphetamine verwijten.
    static func connect(timeoutSeconds: Int = 90) -> ConnectResult {
        let path = socketPath
        guard let addr = address(for: path) else {
            return .fout("Het pad naar het besturingskanaal is te lang (\(path.utf8.count) van \(maxPathLength) tekens): \(path)")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .fout("socket() mislukte: \(errnoText())") }
        suppressSigPipe(fd)
        setTimeouts(fd, seconds: timeoutSeconds)

        var target = addr
        let rc = withUnsafePointer(to: &target) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            let saved = errno
            close(fd)
            if saved == ENOENT || saved == ECONNREFUSED { return .appDraaitNiet }
            return .fout("Verbinden met \(path) mislukte: \(errnoText(saved))")
        }
        return .verbonden(fd)
    }

    /// Leest één regel. Geeft `nil` bij een fout of een tijdslimiet — nooit een lege regel
    /// die als een leeg verzoek gelezen zou worden.
    static func readLine(from fd: Int32, limit: Int = 64 * 1024) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while out.count < limit {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
                if out.contains(0x0A) { break }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        guard let newline = out.firstIndex(of: 0x0A) else { return out.isEmpty ? nil : out }
        return Data(out[out.startIndex..<newline])
    }

    @discardableResult
    static func write(_ data: Data, to fd: Int32) -> Bool {
        var rest = data
        while !rest.isEmpty {
            let sent = rest.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if sent > 0 {
                rest = rest.dropFirst(sent)
            } else if sent < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    static func errnoText(_ code: Int32 = errno) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}
