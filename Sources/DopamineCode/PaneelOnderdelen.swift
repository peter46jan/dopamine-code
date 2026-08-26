import SwiftUI

/// De maten van het paneel, als vaste getallen.
///
/// Ze stónden niet vast: de meters gebruikten een `GeometryReader` en de teksten een
/// `minimumScaleFactor`, allebei manieren om SwiftUI zelf te laten uitrekenen wat er past.
/// Los kwam elk blok daarmee tot rust, maar samen niet — dan bleef AppKit het venster bij elke
/// beeldwissel opnieuw indelen. Gemeten na het openen en sluiten van het paneel: elk blok
/// apart 0,3 tot 0,8% van een kern, alle blokken samen 9,8%, en dat bleef dag en nacht doorgaan
/// met het paneel dicht.
///
/// De getallen waren toch al bekend — ze staan sinds het tegelontwerp in de commit-berichten,
/// nagemeten met `NSAttributedString` in vier talen. Ze hier neerzetten scheelt SwiftUI het
/// werk om ze elke keer opnieuw af te leiden.
enum Maten {
    /// De breedte van het paneel. Zie `MenuView`.
    static let paneel: CGFloat = 360
    static let buitenrand: CGFloat = 13
    /// 360 − 2 × 13.
    static let inhoud = paneel - 2 * buitenrand          // 334
    static let kier: CGFloat = 9
    static let tegelrand: CGFloat = 11
    /// De binnenmaat van een halve tegel: (334 − 9) / 2 − 2 × 11.
    static let halveTegelInhoud = (inhoud - kier) / 2 - 2 * tegelrand   // 140,5
}

// MARK: - De tegel zelf

/// Eén tegel: glas op de eigen achtergrond, met de inhoud erin.
///
/// De randafstand staat hier en niet bij de aanroepers, zodat twee tegels naast elkaar altijd
/// dezelfde binnenmaat hebben. Gemeten met die maat: de langste warmtelabel — het Franse
/// "légèrement élevée" — is 131,4 pt in een tegel die 140,5 pt inhoud heeft.
struct Tegel<Inhoud: View>: View {
    var stijl: Tegelstijl = .rustig
    var straal: CGFloat = 13
    var rand: CGFloat = 11
    @ViewBuilder let inhoud: Inhoud

    var body: some View {
        inhoud
            .padding(rand)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glas(straal: straal, stijl: stijl)
    }
}

/// De kop van een tegel: symbool, naam in hoofdletters, en rechts iets kleins.
///
/// Hoofdletters en niet vetgedrukt: dit is een etiket en geen bewering. De waarde eronder moet
/// het eerst gelezen worden.
struct TegelKop: View {
    let symbool: String
    let naam: LocalizedStringKey
    var rechts: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbool)
                .font(.system(size: 9.5))
                .frame(width: 13)
            Text(naam)
                .font(.system(size: 10, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.5)
            if let rechts {
                Spacer(minLength: 6)
                Text(rechts).font(.system(size: 10)).monospacedDigit()
            }
        }
        .foregroundStyle(Palet.inktFlauw)
        .lineLimit(1)
    }
}

/// De kop boven een groep tegels.
struct SectieKop: View {
    let tekst: LocalizedStringKey

    var body: some View {
        Text(tekst)
            .font(.system(size: 10, weight: .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Palet.inktFlauw)
            .padding(.leading, 2)
    }
}

// MARK: - De vangnettegels

/// Een vangnet als tegel: naam, waarde, meter, en waar het stopt.
///
/// De grens staat er altijd bij, en dat is de hele reden dat dit blok bestaat — een percentage
/// zonder grens zegt niets over wat er straks gaat gebeuren. In de oude rij vochten de waarde
/// en de grens om één kolom van honderd punten; hier heeft elk zijn eigen regel.
///
/// Alle drie de regels zijn `lineLimit(1)`. Dat is niet cosmetisch: twee tegels naast elkaar
/// horen even hoog te zijn, en één afbrekende zin zou de rij scheeftrekken.
struct MeterTegel<Meter: View>: View {
    let symbool: String
    let naam: LocalizedStringKey
    let waarde: String
    let grens: String
    var gedempt = false
    /// Klein en rechts in de kop: een tweede meting die erbij hoort maar niet de hoofdzaak is.
    ///
    /// De warmtetegel zet hier de gemeten graden neer. Niet in `waarde`, want daar staat wat
    /// het vangnet beoordeelt — en dat is bij warmte een stand van vier en geen temperatuur.
    /// In het Frans zou "légèrement élevée · s'arrête à 4 sur 4" op één regel 170 pt worden in
    /// een tegel die er 140,5 heeft; dit slot is de enige plek waar het past.
    var rechts: String?
    @ViewBuilder let meter: Meter

    var body: some View {
        Tegel {
            VStack(alignment: .leading, spacing: 0) {
                TegelKop(symbool: symbool, naam: naam, rechts: rechts)
                Text(waarde)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(gedempt ? Palet.inktZacht : Palet.inktFel)
                    .lineLimit(1)
                    // Geen `minimumScaleFactor`: die laat SwiftUI de tekst bij elke indeling
                    // op meerdere schalen opmeten, en dat was mede waarom de indeling niet tot
                    // rust kwam. Het past ook zo — de langste is het Franse "légèrement
                    // élevée", 131,4 pt in een tegel van 140,5.
                    .padding(.top, 5)
                meter
                    .padding(.top, 7)
                Text(grens)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(Palet.inktFlauw)
                    .lineLimit(1)
                    // Past: de langste is het Duitse "stoppt bei 4 von 4", 88,0 van 140,5 pt.
                    .padding(.top, 6)
            }
        }
    }
}

/// De wachter, over de volle breedte.
///
/// Breed en niet half, omdat hier een zin staat en geen getal — en omdat dit het enige vangnet
/// is dat een `SIGKILL` van de app overleeft. Het verdient de onderste regel voor zichzelf.
struct WachterTegel: View {
    let zin: String
    let interval: String
    let leeft: Bool
    /// Zie `WachterStip.klopt`.
    var klopt = true

    var body: some View {
        Tegel {
            VStack(alignment: .leading, spacing: 6) {
                TegelKop(symbool: "shield", naam: "tegel.wachter", rechts: interval)
                // 11 en niet 8: de hartslag van de stip zwelt tot 2,6 keer zijn maat en raakte
                // bij 8 de eerste letter van de zin.
                HStack(spacing: 11) {
                    WachterStip(leeft: leeft, klopt: klopt)
                    Text(zin)
                        .font(.system(size: 11))
                        .foregroundStyle(leeft ? Palet.inktZacht : Palet.alarm)
                        .lineLimit(1)
                        // Past: de langste is het Duitse "hat noch nicht nachgesehen",
                        // 148,1 pt in een brede tegel van 298.
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - De meters

/// Een vloeiende meter: een balk met de rode zone erin en een streepje op de stand.
///
/// De zone ligt óver de vulling en niet ernaast: waar je staat en waar het stopt horen op
/// dezelfde as te liggen, anders moet de lezer twee schalen bij elkaar optellen.
///
/// Aan de lader is de meter gedempt. Het accuvangnet kan dan niet afgaan — `AppModel` eist
/// `!battery.onAC` — en een scherpe kleur zou iets beloven wat niet gebeurt.
struct AccuMeterView: View {
    let meter: AccuMeter
    /// De breedte waarop gerekend wordt. Een vast getal en geen `GeometryReader`.
    ///
    /// Die reader was een van de dingen die de indeling niet lieten uitconvergeren: hij meet de
    /// ruimte die hij krijgt, en zijn inhoud bepaalt mede hoeveel ruimte dat is. In een tegel
    /// naast andere tegels blijft dat rondzingen. De maat ligt toch vast — zie `Maten`.
    var breedte: CGFloat = Maten.halveTegelInhoud

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Palet.baan)
            Capsule()
                .fill(meter.sluimert ? Palet.inktFlauw : Palet.accent)
                .frame(width: breedte * meter.vulling)
            Capsule()
                .fill(Palet.alarm.opacity(meter.sluimert ? 0.20 : 0.42))
                .frame(width: breedte * meter.zone)
            Rectangle()
                .fill(Palet.inktFel)
                .frame(width: 1.5, height: 9)
                .offset(x: max(0, breedte * meter.vulling - 0.75))
        }
        .frame(width: breedte, height: 4)
    }
}

/// Een gestapelde meter: vier blokjes, het laatste rood en leeg.
///
/// Gestapeld en niet vloeiend omdat het gegeven zelf gestapeld is — macOS geeft vier namen
/// en geen graden. De vorm hoort te zeggen wat voor gegeven het is; een balk zou een
/// precisie suggereren die er niet is.
struct WarmteMeterView: View {
    let meter: WarmteMeter

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...meter.aantal, id: \.self) { index in
                Capsule()
                    .fill(kleur(index))
                    .frame(height: 4)
            }
        }
    }

    private func kleur(_ index: Int) -> Color {
        // Het laatste blokje is de grens: rood en leeg zolang je hem niet haalt, zodat je
        // ziet wáár het stopt voordat het zover is.
        if index == meter.stopBij && !meter.brandt(index) { return Palet.alarm.opacity(0.30) }
        if meter.brandt(index) { return index >= meter.stopBij ? Palet.alarm : Palet.accent }
        return Palet.baan
    }
}

/// De wachter: een kloppende stip.
///
/// Geen balk, want er valt niets te vullen. Wat er te zeggen valt is dat hij nog leeft, en
/// dat zegt een hartslag beter dan een getal. Dit is het enige vangnet dat een `SIGKILL`
/// van de app overleeft, en het stond tot voor kort nergens in de interface.
struct WachterStip: View {
    /// Keek de wachter recent genoeg? Zo niet, dan hoort de stip dat te zeggen.
    ///
    /// Hij was hard groen en klopte altijd door — ook als de LaunchAgent uitgezet was bij
    /// Systeeminstellingen → Inloggen en extensies, en ook als er nog nooit iemand gekeken
    /// had. Een indicator die per constructie geen storing kan melden is erger dan geen
    /// indicator, zeker voor het enige vangnet dat een `SIGKILL` van de app overleeft.
    var leeft = true

    /// Staat het paneel open? Zo niet, dan klopt er niets.
    ///
    /// `repeatForever` neemt dat woord letterlijk. Een MenuBarExtra-paneel wordt bij het sluiten
    /// niet afgebroken, dus de animatie bleef lopen voor een paneel dat niemand ziet — en elke
    /// beeldwissel deelde AppKit het venster opnieuw in. Gemeten in een monster van 10 seconden
    /// met het paneel dícht: 765 van de 8366 metingen op de hoofddraad zaten in de
    /// CoreAnimation-tekencyclus, oftewel 9% van een kern, de hele dag door.
    ///
    /// Het stoppen gebeurt door de animatie wég te laten en niet door de waarde terug te zetten:
    /// een lopende `repeatForever` gaat niet uit van een nieuwe waarde erin schrijven.
    var klopt = true

    @Environment(\.accessibilityReduceMotion) private var minderBeweging
    @State private var groot = false

    var body: some View {
        Circle()
            .fill(leeft ? Palet.leeft : Palet.alarm)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(Palet.leeft.opacity(groot ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(groot ? 2.6 : 1)
                    .opacity(leeft ? 1 : 0)
            )
            .onAppear { stelIn() }
            .onChange(of: klopt) { _, _ in stelIn() }
            .accessibilityHidden(true)
    }

    /// Start of stop de hartslag.
    ///
    /// Alleen kloppen als er werkelijk iets klopt: een hartslag naast een dode wachter is
    /// precies de geruststelling die hier niet mag staan.
    private func stelIn() {
        if klopt, leeft, !minderBeweging {
            withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                groot = true
            }
        } else {
            // Zonder animatie terugzetten, anders blijft de lopende herhaling eraan hangen.
            var zonder = Transaction()
            zonder.disablesAnimations = true
            withTransaction(zonder) { groot = false }
        }
    }
}

// MARK: - De heldentegel

/// De boog om het icoon: het verstreken deel van de sessie.
///
/// `voortgang` komt uit `KaartToestand` en is daar geklemd op 0…1. Dat is niet cosmetisch:
/// `.trim(to:)` krijgt hier een waarde die bij een deling door nul `NaN` zou zijn, en NaN is
/// in Core Animation een ongeldige numerieke waarde. De bewaking staat in `KaartToestand`
/// en wordt daar getest.
struct BoogIcoon: View {
    let toestand: KaartToestand

    /// Staat de app in een foutstatus? Het paneel kleurde het icoon dan oranje. Rood nu, en
    /// niet uit smaak: dezelfde toestand levert in `Aandacht` een `.foutstatus`, en die is
    /// rood. Twee kleuren voor één feit maakt de rangorde onleesbaar.
    var fout = false

    var body: some View {
        ZStack {
            Circle().stroke(Palet.baan, lineWidth: 4)
            Circle()
                .trim(from: 0, to: toestand.voortgang)
                .stroke(fout ? Palet.alarm : Palet.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbool)
                .font(.system(size: 17))
                .foregroundStyle(kleur)
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    private var kleur: Color {
        if fout { return Palet.alarm }
        return toestand.isAan ? Palet.accent : Palet.inktZacht
    }

    private var symbool: String {
        if fout { return "exclamationmark.triangle.fill" }
        switch toestand.fase {
        case .uit:    return "moon.fill"
        case .gearmd: return "laptopcomputer.and.arrow.down"
        case .aan:    return "sun.max.fill"
        }
    }
}
