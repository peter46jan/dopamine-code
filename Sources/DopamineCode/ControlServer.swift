import Foundation
import Darwin

/// Luistert op de unix socket waar de `dopamine`-opdrachtregel mee praat.
///
/// Dit object weet **niets** van sessies. Het leest een regel JSON, controleert wie er aan
/// de andere kant zit, en geeft de vraag door aan de handler die `AppModel` meegeeft; het
/// antwoord schrijft het terug en daarna gaat de verbinding dicht. Er wordt niets onthouden
/// tussen twee verzoeken door — een socketlaag die zelf bijhoudt of er "iets loopt" is
/// precies de tweede waarheid die de guardian moet voorkomen.
///
/// Alles gebeurt naast de hoofdthread. Die draait de guardian, en een `accept()` of een
/// blokkerende `read()` vóór de run loop is een blokkade van het enige dat de vlag nog kan
/// terugzetten (zie ook `Shell.run`, regel 78-85, waar deze codebase daar eerder streng in
/// werd om dezelfde reden).
final class ControlServer: @unchecked Sendable {

    typealias Handler = @Sendable @MainActor (ControlChannel.Request) async -> ControlChannel.Response

    private let handler: Handler
    /// Alleen voor het opzetten, het accepteren en het opruimen. Het afhandelen van een
    /// verbinding gebeurt ergens anders: `dopamine on` kan seconden duren (de privileged
    /// schrijf plus de verificatieladder), en zolang mag een tweede `dopamine status` daar
    /// niet achter blijven staan.
    private let queue = DispatchQueue(label: "com.peter46jan.dopaminecode.besturing")
    private let workQueue = DispatchQueue(label: "com.peter46jan.dopaminecode.besturing.verbinding",
                                          attributes: .concurrent)

    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var toestand = L10n.t("kanaal.nogniet")

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Wat Instellingen → Diagnose laat zien. Eén zin, geen jargon.
    var toestandsTekst: String {
        queue.sync { toestand }
    }

    // MARK: - Opzetten

    func start() {
        queue.async { [self] in setUp() }
    }

    private func setUp() {
        let path = ControlChannel.socketPath

        guard path.utf8.count <= ControlChannel.maxPathLength else {
            fail(L10n.t("kanaal.fout.padtelang", path.utf8.count, ControlChannel.maxPathLength, path),
                 L10n.nl("kanaal.fout.padtelang", path.utf8.count, ControlChannel.maxPathLength, path))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: ControlChannel.directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            fail(L10n.t("kanaal.fout.mapniet", error.localizedDescription),
                 L10n.nl("kanaal.fout.mapniet", error.localizedDescription))
            return
        }

        // Ligt er al een socket waar iets op antwoordt, dan draait er een tweede instantie.
        // Die overnemen zou betekenen dat twee apps commando's van dezelfde CLI opvangen,
        // en dat is dezelfde soort ruzie als twee schrijvers op de kernelvlag.
        if case .verbonden(let probe) = ControlChannel.connect(timeoutSeconds: 2) {
            close(probe)
            fail(L10n.t("kanaal.fout.aleeniets", path),
                 L10n.nl("kanaal.fout.aleeniets", path))
            return
        }

        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            fail(L10n.t("kanaal.fout.socket", ControlChannel.errnoText()),
                 L10n.nl("kanaal.fout.socket", ControlChannel.errnoText()))
            return
        }
        ControlChannel.suppressSigPipe(fd)

        guard var addr = ControlChannel.address(for: path) else {
            close(fd)
            fail(L10n.t("kanaal.fout.padpastniet", path),
                 L10n.nl("kanaal.fout.padpastniet", path))
            return
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let text = ControlChannel.errnoText()
            close(fd)
            fail(L10n.t("kanaal.fout.bind", path, text),
                 L10n.nl("kanaal.fout.bind", path, text))
            return
        }

        // Alleen deze gebruiker mag er iets in stoppen. De map staat al op 0700; dit is de
        // tweede grendel, voor het geval de map ooit ruimer gezet wordt.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            let text = ControlChannel.errnoText()
            close(fd)
            unlink(path)
            fail(L10n.t("kanaal.fout.listen", text),
                 L10n.nl("kanaal.fout.listen", text))
            return
        }

        // Niet blokkerend, zodat `accept()` in de leeslus nooit blijft hangen op een
        // verbinding die alweer weg is voordat we erbij waren.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()

        toestand = L10n.t("kanaal.luistert", path)
        EventLog.shared.info("Besturingskanaal luistert op \(path).")
    }

    /// De reden komt er twee keer in: vertaald voor `toestand`, dat in Instellingen →
    /// Diagnose staat, en Nederlands voor het logboek. Zie `L10n.nl`. Eén `String` volstond
    /// niet zodra deze zinnen sleutels werden, want ze gaan naar beide.
    private func fail(_ reden: String, _ redenNL: String) {
        toestand = L10n.t("kanaal.werktniet", reden)
        // Nooit stil: zonder deze regel doet `dopamine` het gewoon niet en zegt de app niets.
        EventLog.shared.error(L10n.nl("kanaal.werktniet.log", redenNL))
    }

    // MARK: - Verbindingen

    private func acceptPending() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                let saved = errno
                if saved == EINTR { continue }
                if saved != EAGAIN && saved != EWOULDBLOCK {
                    EventLog.shared.warn("Besturingskanaal: accept() gaf \(ControlChannel.errnoText(saved)).")
                }
                return
            }
            ControlChannel.suppressSigPipe(fd)
            // Op BSD — en dus op macOS — erft een geaccepteerde socket de O_NONBLOCK van de
            // luisteraar. Hier gemeten: zonder deze regel geeft de eerste `read()` meteen
            // EAGAIN, meldt de app "verbinding zonder leesbaar verzoek" en krijgt de CLI een
            // EPIPE te zien. Wij lezen blokkerend met een tijdslimiet, dus zet hem terug.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
            // Ruim, maar niet oneindig: een CLI die zijn regel niet afmaakt mag geen
            // verbinding voor altijd openhouden.
            ControlChannel.setTimeouts(fd, seconds: 15)
            workQueue.async { [weak self] in self?.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        guard peerIsOwner(fd) else {
            EventLog.shared.warn("Besturingskanaal: verbinding van een andere gebruiker geweigerd.")
            close(fd)
            return
        }
        guard let line = ControlChannel.readLine(from: fd), !line.isEmpty else {
            EventLog.shared.warn("Besturingskanaal: verbinding zonder leesbaar verzoek.")
            close(fd)
            return
        }
        guard let verzoek = try? ControlChannel.decoder().decode(ControlChannel.Request.self, from: line) else {
            EventLog.shared.warn("Besturingskanaal: onbegrijpelijk verzoek ontvangen.")
            reply(.lokaal(zin: L10n.t("kanaal.nietbegrepen"), code: 2), to: fd)
            return
        }

        let handler = self.handler
        Task { @MainActor in
            let antwoord = await handler(verzoek)
            // Het terugschrijven hoort niet op de hoofdthread: een socket-write vóór de run
            // loop staat voor de guardian, en de kant die moet lezen is een los proces dat
            // er even niet meer kan zijn.
            self.reply(antwoord, to: fd)
        }
    }

    private func reply(_ antwoord: ControlChannel.Response, to fd: Int32) {
        workQueue.async {
            defer { close(fd) }
            guard let data = try? ControlChannel.line(antwoord) else {
                EventLog.shared.error("Besturingskanaal: antwoord kon niet gecodeerd worden.")
                return
            }
            if !ControlChannel.write(data, to: fd) {
                EventLog.shared.warn("Besturingskanaal: antwoord kon niet verstuurd worden "
                                     + "(\(ControlChannel.errnoText())). De opdracht zelf is wel uitgevoerd.")
            }
        }
    }

    /// Alleen de ingelogde gebruiker zelf. `LOCAL_PEERCRED` geeft de uid van de andere kant
    /// van de socket; hier gemeten levert dat 501 op voor een gewone terminal.
    ///
    /// De constanten staan er met de hand in omdat de macro's uit `<sys/un.h>` niet altijd
    /// door de Swift-importer heen komen; ze zijn onderdeel van het ABI en veranderen niet.
    private func peerIsOwner(_ fd: Int32) -> Bool {
        let solLocal: Int32 = 0
        let localPeerCred: Int32 = 0x001
        var cred = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, solLocal, localPeerCred, &cred, &size) == 0 else {
            EventLog.shared.warn("Besturingskanaal: kon niet vaststellen wie er verbindt "
                                 + "(\(ControlChannel.errnoText())); verbinding geweigerd.")
            return false
        }
        return cred.cr_uid == getuid()
    }

    // MARK: - Opruimen

    func stop() {
        queue.sync { [self] in
            acceptSource?.cancel()
            acceptSource = nil
            listener = -1
            ControlServer.removeSocketFile()
            toestand = "gestopt"
        }
    }

    /// Ook aangeroepen vanuit de signaalafhandeling, vlak vóór `exit(0)`: een achtergebleven
    /// socketbestand geeft de volgende `dopamine`-aanroep een ECONNREFUSED. Dat wordt netjes
    /// gemeld als "de app draait niet", maar een dood bestand laten liggen is slordig en
    /// maakt de volgende start onnodig ingewikkeld.
    static func removeSocketFile() {
        unlink(ControlChannel.socketPath)
    }
}
