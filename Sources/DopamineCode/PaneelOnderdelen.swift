import SwiftUI

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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(meter.sluimert ? Color.secondary : Color.accentColor)
                    .frame(width: geo.size.width * meter.vulling)
                Capsule()
                    .fill(Color.red.opacity(meter.sluimert ? 0.18 : 0.40))
                    .frame(width: geo.size.width * meter.zone)
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 1.5, height: 9)
                    .offset(x: max(0, geo.size.width * meter.vulling - 0.75))
            }
        }
        .frame(height: 4)
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
        if index == meter.stopBij && !meter.brandt(index) { return Color.red.opacity(0.30) }
        if meter.brandt(index) { return index >= meter.stopBij ? .red : .accentColor }
        return Color.primary.opacity(0.12)
    }
}

/// De wachter: een kloppende stip.
///
/// Geen balk, want er valt niets te vullen. Wat er te zeggen valt is dat hij nog leeft, en
/// dat zegt een hartslag beter dan een getal. Dit is het enige vangnet dat een `SIGKILL`
/// van de app overleeft, en het stond tot nu toe nergens in de interface.
struct WachterStip: View {
    @Environment(\.accessibilityReduceMotion) private var minderBeweging
    @State private var groot = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 5, height: 5)
            .overlay(
                Circle()
                    .stroke(Color.green.opacity(groot ? 0 : 0.55), lineWidth: 3)
                    .scaleEffect(groot ? 2.6 : 1)
            )
            .onAppear {
                guard !minderBeweging else { return }
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
                    groot = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// Eén regel in het vangnettenblok: icoon, meter, waarde.
///
/// De waardekolom heeft een vaste breedte zodat de drie regels onder elkaar uitlijnen, en
/// `monospacedDigit` zodat een tikkende waarde de kolom niet laat verspringen.
struct MeterRij<Inhoud: View>: View {
    let symbool: String
    let inhoud: Inhoud
    let waarde: String
    let grens: String?
    var gedempt = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbool)
                .font(.system(size: 9))
                .frame(width: 13)
                .foregroundStyle(.secondary)
            inhoud
            HStack(spacing: 3) {
                if !waarde.isEmpty {
                    Text(waarde)
                        .foregroundStyle(gedempt ? Color.secondary : Color.primary)
                }
                if let grens {
                    Text(waarde.isEmpty ? grens : "· " + grens)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10.5))
            .monospacedDigit()
            // 100 en niet 74: "62% · aan de lader" werd afgekapt tot "62% · aan d…", en dat is
            // net de helft van de mededeling die ertoe doet.
            .frame(width: 100, alignment: .trailing)
        }
    }
}

/// De boog om het icoon: het verstreken deel van de sessie.
///
/// `voortgang` komt uit `KaartToestand` en is daar geklemd op 0…1. Dat is niet cosmetisch:
/// `.trim(to:)` krijgt hier een waarde die bij een deling door nul `NaN` zou zijn, en NaN is
/// in Core Animation een ongeldige numerieke waarde. De bewaking staat in `KaartToestand`
/// en wordt daar getest.
struct BoogIcoon: View {
    let toestand: KaartToestand

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: 4)
            Circle()
                .trim(from: 0, to: toestand.voortgang)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbool)
                .font(.system(size: 17))
                .foregroundStyle(toestand.isAan ? Color.accentColor : Color.secondary)
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    private var symbool: String {
        switch toestand.fase {
        case .uit:    return "moon.fill"
        case .gearmd: return "laptopcomputer.and.arrow.down"
        case .aan:    return "sun.max.fill"
        }
    }
}
