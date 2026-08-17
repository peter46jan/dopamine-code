import SwiftUI

/// The menu bar panel.
///
/// This uses `.window` style rather than `.menu`: menu style drops non-text views and
/// does not re-render its body when opened, which makes a live countdown impossible.
///
/// Het paneel schildert zijn eigen achtergrond. Dat is de kern van deze indeling en niet een
/// smaakje: `.glassEffect()` breekt wat er ín hetzelfde venster achter ligt, en een
/// `MenuBarExtra` heeft een egale systeemachtergrond — dus tot nu toe viel er niets te breken
/// en zag je grijs op grijs. Zie `Palet`.
struct MenuView: View {
    @ObservedObject var model: AppModel

    /// Eén keer opgehaald bij het openen, niet in de body. De body wordt elke seconde
    /// opnieuw geëvalueerd door de kloktik, en `NSWorkspace.runningApplications` daarin
    /// zetten is een systeemaanroep per seconde zolang het paneel openstaat.
    @State private var runningApps: [RunningApps.Item] = []

    /// De officiële manier om de Settings-scene te openen (macOS 14+). Vervangt het
    /// `showSettingsWindow:`-selectorspel: dat faalde stil vanuit een MenuBarExtra-paneel —
    /// de activation policy ging wél naar `.regular` (Dock-icoon verscheen) maar er kwam geen
    /// venster, dus je bleef met een icoon en niets zitten.
    @Environment(\.openSettings) private var openSettings

    /// De gekozen eindtijd bij "Tot", en wat daaruit volgde. Lokaal, want dit is een vraag die
    /// je stelt en geen instelling die bewaard wordt — wat er van de vraag terechtkwam staat
    /// daarna in `Prefs.autoOffMinutes`, op de enige plek waar een duur hoort te staan.
    @State private var untilTime = Date()
    @State private var untilExplanation: String?

    @ObservedObject private var updates = UpdateCheck.shared

    /// De eenmalige uitleg dat de app bij GitHub kijkt. Lokaal en niet uit `Prefs` gelezen
    /// in de body: die body draait elke seconde door de kloktik, en dan zou elke tik een
    /// UserDefaults-uitlezing zijn voor een vraag die per paneelopening één keer telt.
    @State private var showUpdateNotice = false

    /// `KeyboardBacklight.canPostEvents` is `CGPreflightPostEventAccess()` en kost gemeten
    /// mediaan 9,3 ms. De body draait elke seconde — en blijft dat doen nadat het paneel
    /// dicht is — dus in de body stond hier negen milliseconde blokkerende IPC per seconde
    /// op de hoofddraad, en dat is de draad die de guardian aandrijft. Eén keer per opening.
    @State private var kanToetsenbord = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            heldentegel
            triggerregel
            duurkiezer
            vangnetten
            aandachtsblok
            updateNotice
            updateRow
            scheiding
            voet
        }
        .padding(13)
        // 360 en niet 320. Op 320 liep de segmentkiezer met vijf duren plus een afwijkende
        // waarde het paneel uit, en werd "62% · aan de lader" afgekapt tot "62% · aan d…".
        .frame(width: 360)
        .background(Palet.achtergrond)
        .foregroundStyle(Palet.inkt)
        // Eén vaste look, licht of donker systeem. Dit is de prijs van een eigen achtergrond
        // en hij is bewust betaald: op een donkerpaars verloop is `Color.primary` in lichte
        // modus zwart, en zwart leest daar niet op. Wat het paneel zelf tekent haalt zijn
        // kleur uit `Palet`; wat AppKit tekent — de segmentkiezer, de tijdkiezer, de
        // schakelaar, de knoppen — luistert alleen hiernaar.
        .environment(\.colorScheme, .dark)
        .tint(Palet.accent)
        .onAppear {
            runningApps = RunningApps.list()
            showUpdateNotice = !Prefs.updateNoticeShown
            untilTime = model.deadline
                ?? Date().addingTimeInterval(Double(model.autoOffMinutes) * 60)
            untilExplanation = nil
            kanToetsenbord = KeyboardBacklight.canPostEvents
        }
    }

    // MARK: - De heldentegel

    /// Wat er aan de hand is, in één tegel: de boog, het grote getal, en de schakelaar.
    private var heldentegel: some View {
        Tegel(stijl: model.kaart.isAan ? .op : .rustig) {
            HStack(spacing: 13) {
                BoogIcoon(toestand: model.kaart, fout: model.status.isError)
                VStack(alignment: .leading, spacing: 2) {
                    grote
                    onderregel
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { model.intendedOn },
                                         set: { model.setKeepAwake($0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.busy)
            }
        }
    }

    @ViewBuilder private var grote: some View {
        switch model.kaart.fase {
        case .uit:
            // "Slaapt normaal" is een bewering over het systeem, en die mogen we niet doen
            // terwijl de app weet dat er iets mis is — bij een onleesbare kernelvlag weet de
            // guardian juist níet of de Mac mag slapen. Dan staat de fout er zelf.
            if model.status.isError {
                // Kort en zonder de zin zelf: die staat rood in het aandachtsblok, dat bij een
                // fout altijd zichtbaar is. Hem hier hérhalen zette hem twee keer op één paneel.
                Text("kaart.fout").font(.headline).foregroundStyle(Palet.alarm)
            } else {
                Text("kaart.uit").font(.headline).foregroundStyle(Palet.inktFel)
            }
        case .gearmd:
            Text("kaart.gearmd").font(.headline).foregroundStyle(Palet.inktFel)
        case .aan:
            Text(model.kaartAftelling ?? "—")
                .font(.system(size: 32, weight: .light))
                .monospacedDigit()
                .foregroundStyle(Palet.inktFel)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    @ViewBuilder private var onderregel: some View {
        switch model.kaart.fase {
        case .uit:
            Button("menu.arm.aanzetten") { model.armForLidClose() }
                .buttonStyle(.link).font(.caption).disabled(model.busy)
        case .gearmd:
            HStack(spacing: 6) {
                if let arm = model.lidArm {
                    Text(arm.resterendeTekst(op: model.now))
                        .font(.caption).monospacedDigit().foregroundStyle(Palet.inktZacht)
                }
                Button("menu.arm.intrekken") { model.cancelArming() }
                    .buttonStyle(.link).font(.caption)
            }
        case .aan:
            // Twee regels mogen. Op één regel werd het Franse "éveillé jusqu'à 21:56 · écran
            // ouvert" afgekapt tot "… écran ouv…", en juist die laatste twee woorden zijn de
            // klepstand — het onderwerp van deze app. Krimpen tot 8 pt was het alternatief en
            // is slechter: dan staat de belangrijkste regel het kleinst.
            Text(onderregelAan)
                .font(.caption)
                .foregroundStyle(Palet.inktZacht)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var onderregelAan: String {
        var delen: [String] = []
        if let tot = model.deadlineText { delen.append(L10n.t("kaart.tot", tot)) }
        delen.append(L10n.t(model.lidClosed ? "sub.klepdicht" : "sub.klepopen"))
        return delen.joined(separator: " · ")
    }

    /// Hoe deze sessie begonnen is.
    ///
    /// Altijd zichtbaar zolang er iets loopt — dat stond zo in het oude paneel, met de reden
    /// erbij: "een regel die er soms wel en soms niet staat maakt zijn afwezigheid
    /// dubbelzinnig, en dan is 'welke trigger heeft dit gestart?' niet te beantwoorden."
    @ViewBuilder private var triggerregel: some View {
        if let regel = model.triggerLine {
            Text(regel)
                .font(.caption2)
                .foregroundStyle(Palet.inktZacht)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 2)
        }
    }

    // MARK: - De duur

    private var duurkiezer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.autoOffMinutes },
                                          set: { model.setAutoOff(minutes: $0) })) {
                // Compacte labels: zes segmenten met "30 min" en "10 u 30 min" erin liepen het
                // paneel links en rechts uit.
                ForEach(quickDurations, id: \.self) { totaal in
                    Text(AppModel.durationTextKort(totaal)).tag(totaal)
                }
                // Een waarde die niet in de vijf zit — via de tijdkiezer of via
                // `dopamine on --for` — krijgt een eigen segment. Zonder dit zou de kiezer
                // leeg staan bij een duur die er wél is, en dat leest als "geen duur".
                if !quickDurations.contains(model.autoOffMinutes) {
                    Text(AppModel.durationTextKort(model.autoOffMinutes)).tag(model.autoOffMinutes)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.busy)

            HStack(spacing: 6) {
                Text("kaart.eindigt").font(.caption).foregroundStyle(Palet.inktZacht)
                DatePicker("", selection: $untilTime, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).controlSize(.small)
                // Met een knop en niet bij elke wijziging van de kiezer: elke keer zetten
                // schrijft ook de standaardduur voor de vólgende sessie, en dat hoort te
                // gebeuren op het moment dat je het vraagt — niet terwijl je nog aan het
                // typen bent. Deze regel stond al in de oude untilRow en blijft gelden.
                Button("menu.tot.zetten") { untilExplanation = model.setAutoOffUntil(untilTime) }
                    .buttonStyle(.link).font(.caption)
                    .fixedSize()          // anders breekt "Zetten" over twee regels
                Spacer(minLength: 4)
            }

            // Eigen regel. Naast de tijdkiezer erbij liep de rij in het Frans met een
            // gekoppelde app 19 punten buiten het paneel, en "Se termine à" werd dan tot
            // drie regels platgedrukt omdat het als enige mocht krimpen.
            HStack(spacing: 6) {
                procesKiezer
                Spacer(minLength: 0)
            }

            if let untilExplanation {
                Text(untilExplanation).font(.caption2).foregroundStyle(Palet.inktZacht)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var quickDurations: [Int] { [30, 2 * 60, 4 * 60, 6 * 60, 8 * 60] }

    /// Koppel de sessie aan een draaiende app: hij stopt dan zodra die app klaar is.
    ///
    /// Dit maakt een sessie alleen korter, nooit langer — de tijdslimiet blijft er als
    /// plafond overheen gaan, precies zoals bij `dopamine on --until-exit`. Willekeurige
    /// procesnummers blijven werk voor de opdrachtregel; een lijst van álle processen is
    /// honderden regels systeemwerk waar niemand iets aan heeft.
    private var procesKiezer: some View {
        Menu {
            if runningApps.isEmpty {
                Text("menu.stoppenals.geenapps")
            } else {
                ForEach(runningApps) { item in
                    Button("\(item.naam) (\(item.pid))") { model.keepAwakeUntilQuit(of: item) }
                }
            }
        } label: {
            Text(model.binding.map { L10n.t("menu.stoppenals.klaar", $0.identity.naam) }
                 ?? L10n.t("menu.stoppenals.placeholder"))
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.busy)
    }

    // MARK: - De vangnetten

    /// De drie vangnetten als tegels: accu en warmte naast elkaar, de wachter eronder.
    ///
    /// Elk is een paar: waar je nu bent, en waar het ingrijpt. Dat tweede getal is de hele
    /// reden dat dit blok bestaat — een percentage zonder grens zegt niets over wat er straks
    /// gaat gebeuren. In de oude rij vochten die twee om één kolom; nu heeft elk zijn regel.
    private var vangnetten: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectieKop(tekst: "vangnet.kop")

            HStack(alignment: .top, spacing: 9) {
                // Alleen als er werkelijk een accumeting is. Nul tonen op een Mac zonder accu
                // is een lege balk voor iets wat nooit gemeten is.
                if let accu = model.accuMeter, let battery = model.battery {
                    MeterTegel(symbool: "battery.50",
                               naam: "tegel.accu",
                               waarde: "\(battery.percent)%",
                               grens: accu.sluimert ? L10n.t("vangnet.accu.lader")
                                                    : L10n.t("tegel.grens.accu", Prefs.batteryFloor),
                               gedempt: accu.sluimert) {
                        AccuMeterView(meter: accu)
                    }
                }

                MeterTegel(symbool: "thermometer.medium",
                           naam: "tegel.warmte",
                           waarde: model.warmteLabel,
                           grens: L10n.t("tegel.grens.warmte",
                                         model.warmteMeter.stopBij, model.warmteMeter.aantal)) {
                    WarmteMeterView(meter: model.warmteMeter)
                }
            }

            WachterTegel(zin: model.wachterZin,
                         interval: L10n.t("vangnet.wachter.interval"),
                         leeft: model.wachterLeeft)

            if let limiet = model.cpuSpeedLimit, limiet < 100 {
                Text(L10n.t("vangnet.afgeknepen", limiet))
                    .font(.caption2).foregroundStyle(Palet.let_op)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: - Het aandachtsblok

    /// Alle waarschuwingen als tegels, op ernst geordend door `AppModel.aandacht`.
    ///
    /// Uitgevouwen en niet meer achter een driehoekje. Rood dwong dat al af; nu is het de
    /// normale toestand. Een waarschuwing die je moet openklappen om te zien, is een
    /// waarschuwing die je niet ziet.
    @ViewBuilder private var aandachtsblok: some View {
        let aandacht = model.aandacht
        if let kop = aandacht.kop {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    SectieKop(tekst: "aandacht.kop")
                    if aandacht.telling > 1 {
                        Text("\(aandacht.telling)")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Palet.kleur(kop.soort.ernst), in: Capsule())
                            .foregroundStyle(Color.black.opacity(0.75))
                    }
                    Spacer(minLength: 0)
                }
                ForEach(aandacht.lijst, id: \.soort) { melding in
                    Tegel(stijl: .aandacht(melding.soort.ernst)) {
                        meldingVak(melding)
                    }
                }
            }
        }
    }

    /// De zin, de uitleg en de knoppen die bij één melding horen. De zin zelf is in `AppModel`
    /// samengesteld; hier staat alleen wat je ermee kunt doen.
    @ViewBuilder private func meldingVak(_ melding: Aandacht.Melding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(melding.tekst)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palet.kleur(melding.soort.ernst))
                .fixedSize(horizontal: false, vertical: true)
            switch melding.soort {
            case .vangnettenUit:
                Text("menu.ontwapend.uitleg").font(.caption2).foregroundStyle(Palet.inktZacht)
                    .fixedSize(horizontal: false, vertical: true)
                Text("sudo pmset -a disablesleep 0")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(Palet.inkt)
            case .geenToestemming:
                Text("menu.grant.uitleg").font(.caption2).foregroundStyle(Palet.inktZacht)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("menu.grant.installeren") { model.installGrant() }.disabled(model.busy)
                    Button("menu.grant.opnieuw") { model.refreshGrant() }
                }
                .controlSize(.small)
                // De Terminal-route, voor als het autorisatievenster zich misdraagt. Het is
                // ook de eerlijke route: je leest het script voordat je het als root draait.
                if !SudoersGrant.manualCommand.isEmpty {
                    Text("menu.grant.terminal").font(.caption2).foregroundStyle(Palet.inktZacht)
                    Text(SudoersGrant.manualCommand)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(Palet.inktZacht)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .storingen:
                ForEach(model.outages.suffix(3)) { storing in
                    Text("• " + storing.describe()).font(.caption2)
                        .foregroundStyle(storing.isOngoing ? Palet.let_op : Palet.inktZacht)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .belofteGebroken:
                Text("menu.gebroken.uitleg.wel").font(.caption2).foregroundStyle(Palet.inktZacht)
                    .fixedSize(horizontal: false, vertical: true)
                Text("./verify.sh --after")
                    .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(Palet.inkt)
            case .wasGeslapen:
                Text("menu.gebroken.uitleg.niet").font(.caption2).foregroundStyle(Palet.inktZacht)
                    .fixedSize(horizontal: false, vertical: true)
            // `.foutstatus` draagt zijn eigen zin uit `AppModel.status` en heeft geen knop:
            // de twintig plekken die hem zetten hebben elk hun eigen herstelpad, en één
            // algemene actie zou bij de meeste het verkeerde doen.
            case .foutstatus, .wachterStil, .laatsteMelding, .laatsteMededeling,
                 .updateBeschikbaar, .updateMededeling:
                EmptyView()
            }
        }
    }

    // MARK: - Bijwerken

    /// Eén keer, bij de eerste keer dat het paneel opengaat.
    ///
    /// De app doet iets met het netwerk dat de gebruiker niet gevraagd heeft, dus hoort hij
    /// het te weten vóórdat het opvalt — en niet via een regel in een instellingenvenster
    /// dat hij misschien nooit opent. Met de uitknop er direct naast, want een mededeling
    /// zonder keuze is geen mededeling maar een aankondiging.
    @ViewBuilder
    private var updateNotice: some View {
        if showUpdateNotice {
            Tegel {
                VStack(alignment: .leading, spacing: 6) {
                    Label("menu.update.mededeling.titel", systemImage: "info.circle")
                        .font(.caption)
                    Text("menu.update.mededeling.tekst")
                        .font(.caption2)
                        .foregroundStyle(Palet.inktZacht)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("menu.update.mededeling.prima") { dismissUpdateNotice(disable: false) }
                        Button("menu.update.mededeling.uit") { dismissUpdateNotice(disable: true) }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func dismissUpdateNotice(disable: Bool) {
        if disable { Prefs.updateCheckEnabled = false }
        Prefs.updateNoticeShown = true
        showUpdateNotice = false
    }

    /// Alleen zichtbaar als er werkelijk een nieuwere versie is. Geen "je bent bij"-regel:
    /// dat is de normale toestand, en die hoeft geen ruimte in een paneel dat over iets
    /// anders gaat.
    @ViewBuilder
    private var updateRow: some View {
        if case let .beschikbaar(versie, notities) = updates.toestand {
            Tegel {
                VStack(alignment: .leading, spacing: 6) {
                    Label(updates.huidige == nil
                          ? L10n.t("menu.update.nieuwste", versie.description)
                          : L10n.t("menu.update.beschikbaar", versie.description),
                          systemImage: "arrow.down.circle")
                        .font(.caption)
                    Text(updates.huidige == nil
                         ? "menu.update.uitleg.onbekend"
                         : "menu.update.uitleg")
                        .font(.caption2)
                        .foregroundStyle(Palet.inktZacht)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Installatie.huidige.bijwerkCommando)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(Palet.inktZacht)
                    HStack {
                        Button("menu.update.kopieer") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(Installatie.huidige.bijwerkCommando, forType: .string)
                        }
                        // Ontbreekt als de URL uit het antwoord de controle in `UpdateCheck`
                        // niet haalde. Dan blijft het versienummer staan en verdwijnt alleen
                        // deze knop — zie `veiligeNotitieURL`.
                        if let notities {
                            Button("menu.update.watnieuw") { NSWorkspace.shared.open(notities) }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - De voet

    /// Eigen streep en geen `Divider()`: die haalt zijn kleur uit de systeemscheiding, en op
    /// een eigen verloop is dat of onzichtbaar of een harde balk.
    private var scheiding: some View {
        Rectangle()
            .fill(Color.white.opacity(0.13))
            .frame(height: 0.5)
    }

    private var voet: some View {
        HStack(spacing: 6) {
            Button { model.sleepNow() } label: {
                Label("menu.nuslapen", systemImage: "powersleep")
            }
            .disabled(model.busy)

            if model.backlight.hasDirectControl || kanToetsenbord {
                Button { model.toggleBacklight() } label: {
                    Image(systemName: "keyboard")
                }
                .foregroundStyle(model.backlightOn == true ? Palet.accent : Palet.inktZacht)
                .help(Text("menu.verlichting.titel"))
            }

            Spacer()

            Button {
                // Een accessory-app kan geen venster naar voren halen; even naar `.regular`,
                // en `SettingsView.onDisappear` zet hem weer terug op `.accessory` zodat er
                // geen Dock-icoon blijft hangen. Daarna de scene openen via de nette API.
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            Button("menu.voet.stop") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}
