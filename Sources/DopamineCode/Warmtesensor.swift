import Foundation

/// De temperatuur van de chip, uit de sensoren die macOS zelf ook uitleest.
///
/// `ProcessInfo.thermalState` geeft vier namen en geen graden, en daar is dit paneel lang van
/// uitgegaan. Dat klopte niet: onder IOKit zit een sensorenlaag die wél graden geeft, zonder
/// root. Gemeten op deze Mac: 47 sensoren, waarvan 45 een bruikbare waarde teruggeven.
///
/// **Dit is een privé-API.** `IOHIDEventSystemClient` staat niet in de SDK; de symbolen worden
/// met `dlsym` uit IOKit gehaald. Apple kan dat bij elke uitgave veranderen. Daarom faalt alles
/// hier stil: lukt het niet, dan is de uitkomst `nil` en tekent het paneel wat het zonder
/// graden ook tekende. Een app die over slaapstand gaat mag niet omvallen over een sierletter.
///
/// **En het is duur.** Gemeten mediaan 45 ms voor een ronde langs alle sensoren, ook met een
/// hergebruikte client. Ter vergelijking: `KeyboardBacklight.canPostEvents` kost 9,3 ms en is
/// in dit project al uit de body gehaald. Vandaar de eigen wachtrij — dit raakt de hoofddraad
/// niet, want daar draait de guardian die de vangnetten bedient.
final class Warmtesensor {

    static let shared = Warmtesensor()

    /// Eigen wachtrij, en `utility`: dit is achtergrondwerk waar niemand op wacht.
    private let wachtrij = DispatchQueue(label: "com.peter46jan.dopaminecode.warmte",
                                         qos: .utility)

    /// De client móet blijven leven zolang zijn diensten gebruikt worden. Loslaten en dan nog
    /// lezen is een use-after-free; dat kostte bij het uitproberen een harde SIGKILL.
    private var client: AnyObject?
    private var diensten: [AnyObject] = []
    private var opgezet = false

    private init() {}

    /// Meet, buiten de hoofddraad, en meld het resultaat daar weer terug.
    ///
    /// `nil` betekent: niet te lezen. Dat is geen fout om te melden maar een reden om niets te
    /// tonen — zie de opmerking hierboven over stil falen.
    func meet(_ klaar: @escaping (Double?) -> Void) {
        wachtrij.async { [weak self] in
            let waarde = self?.lees()
            DispatchQueue.main.async { klaar(waarde) }
        }
    }

    // MARK: - De privé-kant

    private func lees() -> Double? {
        if !opgezet { zetOp() }
        guard !diensten.isEmpty, let leesEvent = Self.leesEvent, let leesFloat = Self.leesFloat,
              let leesEigenschap = Self.leesEigenschap else { return nil }

        var alle: [Double] = []
        var vanDeDie: [Double] = []
        for dienst in diensten {
            guard let ev = leesEvent(dienst, Self.soortTemperatuur, 0, 0)?.takeRetainedValue()
            else { continue }
            let graden = leesFloat(ev, Self.veldTemperatuur)
            // Onmogelijke waarden weg. Een sensor die niets meet geeft 0, en een die kapot is
            // geeft iets absurds; allebei zou de hoogste waarde onbruikbaar maken.
            guard graden > 0, graden < 150 else { continue }
            alle.append(graden)
            let naam = (leesEigenschap(dienst, "Product" as CFString)?
                .takeRetainedValue() as? String)?.lowercased() ?? ""
            if naam.contains("tdie") { vanDeDie.append(graden) }
        }

        // `tdie` is de temperatuur van de die zelf — de chip. Die heeft de voorkeur boven de
        // hoogste van alles, want daar zitten ook sensoren tussen die iets anders meten
        // (`tcal` is een ijkpunt, `NAND` is de opslag). Gemeten verschil op deze Mac in rust:
        // 45,8 tegen 51,8 graden.
        //
        // De terugval is er omdat de namen per chip verschillen: op andere modellen bestaat
        // `tdie` niet en heten de kernsensoren anders. Liever de hoogste van alles dan niets.
        if let heetste = vanDeDie.max() { return heetste }
        return alle.max()
    }

    private func zetOp() {
        opgezet = true
        guard let maakClient = Self.maakClient, let zetMatching = Self.zetMatching,
              let kopieerDiensten = Self.kopieerDiensten,
              let c = maakClient(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        // 0xff00 is Apples eigen usage page, 5 daarbinnen is temperatuur.
        zetMatching(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let lijst = kopieerDiensten(c)?.takeRetainedValue() as? [AnyObject] else { return }
        client = c
        diensten = lijst
    }

    // MARK: - De symbolen, met de hand opgezocht

    private typealias MaakClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias ZetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Void
    private typealias KopieerDiensten = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias LeesEigenschap =
        @convention(c) (AnyObject?, CFString?) -> Unmanaged<AnyObject>?
    private typealias LeesEvent =
        @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias LeesFloat = @convention(c) (AnyObject?, Int32) -> Double

    private static let soortTemperatuur: Int64 = 15         // kIOHIDEventTypeTemperature
    private static let veldTemperatuur: Int32 = Int32(15 << 16)

    private static let iokit: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func symbool<T>(_ naam: String, _ type: T.Type) -> T? {
        guard let iokit, let p = dlsym(iokit, naam) else { return nil }
        return unsafeBitCast(p, to: type)
    }

    private static let maakClient =
        symbool("IOHIDEventSystemClientCreate", MaakClient.self)
    private static let zetMatching =
        symbool("IOHIDEventSystemClientSetMatching", ZetMatching.self)
    private static let kopieerDiensten =
        symbool("IOHIDEventSystemClientCopyServices", KopieerDiensten.self)
    private static let leesEigenschap =
        symbool("IOHIDServiceClientCopyProperty", LeesEigenschap.self)
    private static let leesEvent =
        symbool("IOHIDServiceClientCopyEvent", LeesEvent.self)
    private static let leesFloat =
        symbool("IOHIDEventGetFloatValue", LeesFloat.self)
}
