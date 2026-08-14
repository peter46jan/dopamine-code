import AppKit
import Carbon.HIToolbox

/// Eén globale sneltoets, die precies één ding doet: een closure aanroepen.
///
/// **Waarom Carbon en niet `NSEvent.addGlobalMonitorForEvents`.** Die tweede route leest álle
/// toetsaanslagen van het hele systeem mee en vraagt daarom Toegankelijkheid — een recht dat
/// op deze Mac uit staat (`logEnvironment` schrijft elke start "gebeurtenissen posten
/// toegestaan: false"). `RegisterEventHotKey` vraagt niets: je zegt macOS wélke combinatie je
/// wilt, en je hoort alleen díe. Hier gemeten met exact de swiftc-regel uit `build.sh`:
/// Carbon wordt automatisch meegelinkt (`otool -L` noemt hem), registreren geeft status 0 en
/// er komt geen enkel toestemmingsvenster aan te pas. Dat de API oud is verandert daar niets
/// aan; het alternatief kost een recht dat deze app niet nodig heeft.
///
/// **Dit bestand weet niet of er een sessie loopt.** Het houdt geen aan/uit-stand bij, het
/// kent `SleepFlag` niet en het beslist niets. Het roept de closure aan en verder niets — wat
/// er dan gebeurt is aan `AppModel`, want daar staan de accugrens, de temperatuurbewaking en
/// de controle op de wachtwoordvrijstelling. Een sneltoets met een eigen idee van "hij staat
/// aan" loopt uit de pas met de kernel zodra een vangnet ingrijpt.
final class GlobalShortcut {

    /// Wat er van een poging terechtkwam. Nooit stil: elke tak hier komt in het logboek én in
    /// Instellingen te staan, want een sneltoets die niets doet is anders niet te onderscheiden
    /// van een sneltoets die je verkeerd onthouden hebt.
    enum Uitkomst: Equatable {
        /// Geregistreerd, met de leesbare combinatie erbij.
        case gezet(String)
        /// Er is geen combinatie opgenomen. Geen fout.
        case geen
        case mislukt(String)
    }

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    /// Waarmee macOS onze sneltoets van die van andere apps onderscheidt. 'DOPA'.
    private static let signature: OSType = 0x444F5041

    /// Esc, voor het afbreken van een opname. Hier en niet in de instellingen, zodat er maar
    /// één bestand toetscodes hoeft te kennen.
    static let escapeKeyCode = kVK_Escape

    /// Zet de sneltoets op deze combinatie, of haalt hem weg als er geen is.
    ///
    /// Idempotent: hij ruimt eerst de vorige registratie op. De instellingen roepen dit aan bij
    /// elke wijziging, en twee registraties tegelijk zouden betekenen dat een oude combinatie
    /// blijft werken nadat je hem hebt vervangen.
    @discardableResult
    func apply(keyCode: Int?, modifierFlags: UInt, action: @escaping () -> Void) -> Uitkomst {
        stop()
        self.action = action

        guard let keyCode else { return .geen }

        let carbon = Self.carbonModifiers(modifierFlags)
        // Zonder ⌘, ⌥ of ⌃ zou deze toets in élke app opgeslokt worden: typ je een D, dan komt
        // hij hier terecht en niet in je tekst. ⇧ alleen telt niet mee, want ⇧D is gewoon een
        // hoofdletter D. Dit is de enige weigering die niet over een fout gaat maar over
        // schade, en daarom staat hij vóór het registreren.
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            return .mislukt("Een sneltoets heeft minstens ⌘, ⌥ of ⌃ nodig. Zonder zo'n toets "
                            + "zou hij die toets in elke app opslokken.")
        }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(), Self.hotKeyCallback, 1, &spec,
            Unmanaged.passUnretained(self).toOpaque(), &handler
        )
        guard handlerStatus == noErr else {
            handler = nil
            return .mislukt("macOS wilde de sneltoets niet aannemen (foutcode \(handlerStatus)).")
        }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), carbon, id,
                                         GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr, hotKey != nil else {
            stop()
            let combinatie = Self.beschrijving(keyCode: keyCode, modifierFlags: modifierFlags)
            // Deze code komt terug als de combinatie al bezet is. In gewone taal erbij wat je
            // eraan doet, want "foutcode -9878" vertelt niemand iets.
            if status == OSStatus(eventHotKeyExistsErr) {
                return .mislukt("\(combinatie) is al in gebruik door iets anders. Kies een "
                                + "andere combinatie.")
            }
            return .mislukt("\(combinatie) kon niet ingesteld worden (foutcode \(status)).")
        }
        return .gezet(Self.beschrijving(keyCode: keyCode, modifierFlags: modifierFlags))
    }

    /// Haalt de registratie weg. Wordt ook aangeroepen bij het afsluiten, naast de timers.
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit { stop() }

    /// De C-callback. `@convention(c)` kan niets vangen, dus gaat het object er als `userData`
    /// in — dezelfde constructie als elke andere Carbon-handler.
    ///
    /// Er is er precies één van deze registraties in de app, dus de gebeurtenis hoeft niet
    /// uitgepakt te worden om te weten welke sneltoets het was.
    private static let hotKeyCallback: EventHandlerUPP = { _, _, userData in
        guard let userData else { return OSStatus(eventNotHandledErr) }
        let sneltoets = Unmanaged<GlobalShortcut>.fromOpaque(userData).takeUnretainedValue()
        sneltoets.action?()
        return noErr
    }

    // MARK: - Vertalen

    /// De vier hulptoetsen die meetellen, in de volgorde waarin macOS ze zelf schrijft.
    ///
    /// Alleen deze vier. `NSEvent.ModifierFlags` bevat ook Caps Lock, het numerieke toetsenblok
    /// en de functietoets-vlag, en die komen ongevraagd mee in wat een toetsaanslag rapporteert
    /// — een sneltoets die alleen werkt met Caps Lock aan is niet wat iemand opnam.
    private static let hulptoetsen: [(vlag: NSEvent.ModifierFlags, carbon: Int, teken: String)] = [
        (.control, controlKey, "⌃"),
        (.option, optionKey, "⌥"),
        (.shift, shiftKey, "⇧"),
        (.command, cmdKey, "⌘"),
    ]

    /// Houdt van een toetsaanslag alleen de vier hulptoetsen over die ertoe doen.
    static func schoon(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(hulptoetsen.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.vlag) })
    }

    /// `NSEvent.ModifierFlags` → de getallen waarmee Carbon rekent. Op één plek, zodat de
    /// opgeslagen instelling en de registratie nooit uit elkaar kunnen lopen.
    static func carbonModifiers(_ flags: UInt) -> UInt32 {
        let ingedrukt = NSEvent.ModifierFlags(rawValue: flags)
        return hulptoetsen.reduce(into: UInt32(0)) { totaal, hulptoets in
            if ingedrukt.contains(hulptoets.vlag) { totaal |= UInt32(hulptoets.carbon) }
        }
    }

    /// De combinatie zoals een mens hem leest: ⌃⌥⌘D.
    static func beschrijving(keyCode: Int, modifierFlags: UInt) -> String {
        let ingedrukt = NSEvent.ModifierFlags(rawValue: modifierFlags)
        let tekens = hulptoetsen.filter { ingedrukt.contains($0.vlag) }.map(\.teken).joined()
        return tekens + toetsnaam(keyCode)
    }

    /// De naam van één toets.
    ///
    /// Eerst de toetsen die geen teken opleveren (functietoetsen, spatie, pijltjes): daar geeft
    /// de vertaling hieronder een leeg antwoord of een onzichtbaar teken op. Voor de rest wordt
    /// de láyout gevraagd in plaats van een vaste tabel aan te houden, zodat een Azerty- of
    /// Dvorak-toetsenbord de letter toont die er ook echt op staat.
    static func toetsnaam(_ keyCode: Int) -> String {
        if let vast = vasteToetsnamen[keyCode] { return vast }
        if let teken = tekenVoorToets(keyCode), !teken.isEmpty { return teken }
        return "toets \(keyCode)"
    }

    private static let vasteToetsnamen: [Int: String] = [
        kVK_Space: "Spatie", kVK_Return: "Return", kVK_Tab: "Tab", kVK_Escape: "Esc",
        kVK_Delete: "Backspace", kVK_ForwardDelete: "Delete", kVK_Help: "Help",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page up", kVK_PageDown: "Page down",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11",
        kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static func tekenVoorToets(_ keyCode: Int) -> String? {
        let bron = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let bron,
              let ruw = TISGetInputSourceProperty(bron, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ruw).takeUnretainedValue() as Data

        var dodeToets: UInt32 = 0
        var lengte = 0
        var tekens = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { ruimte -> OSStatus in
            guard let layout = ruimte.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dodeToets, tekens.count, &lengte, &tekens)
        }
        guard status == noErr, lengte > 0 else { return nil }
        return String(utf16CodeUnits: tekens, count: lengte).uppercased()
    }
}
