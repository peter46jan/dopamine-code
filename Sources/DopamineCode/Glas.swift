import SwiftUI

/// Waar een tegel voor staat. Bepaalt zijn vulling en zijn rand, en verder niets.
enum Tegelstijl {
    /// De normale tegel: melkglas op het verloop.
    case rustig
    /// Er loopt een sessie. Alleen de heldentegel krijgt deze.
    case op
    /// Een waarschuwing, in de kleur van zijn ernst.
    case aandacht(Aandacht.Ernst)
}

/// Liquid Glass op een eigen ondergrond, met een terugval voor macOS 14 tot en met 25.
///
/// `.glassEffect()` breekt wat er ín hetzelfde venster achter ligt. Een `MenuBarExtra` heeft
/// een egale systeemachtergrond, dus tot nu toe was er niets om te breken en zag je grijs op
/// grijs. `MenuView` schildert nu eerst `Palet.achtergrond`; pas daardoor heeft dit effect
/// betekenis.
///
/// De aftakking blijft, want `build.sh` bouwt voor 14.0 en dat verandert niet. Let op welke
/// tak je ziet: deze Mac draait macOS 26.5, dus hier loopt altijd de bovenste. De terugval is
/// apart nagegaan door hem in een proef af te dwingen (glasproef).
///
/// Beide takken dragen dezelfde rand en dezelfde kleurlaag; alleen de ondergrond eronder
/// verschilt. Wat er op 14 en 15 anders is, is dus hooguit de doorschijnendheid en nooit de
/// indeling.
struct Glas: ViewModifier {
    var straal: CGFloat = 13
    var stijl: Tegelstijl = .rustig

    func body(content: Content) -> some View {
        let vorm = RoundedRectangle(cornerRadius: straal, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: vorm)
                .overlay(kleurlaag(vorm))
                .overlay(rand(vorm))
        } else {
            content
                .background(vulling, in: vorm)
                .overlay(rand(vorm))
        }
    }

    /// De vulling van de tegel. Van linksboven naar rechtsonder, net als de achtergrond, zodat
    /// een tegel niet tegen het verloop in lijkt te lichten.
    private var vulling: LinearGradient {
        LinearGradient(colors: [boven, onder],
                       startPoint: UnitPoint(x: 0.1, y: 0), endPoint: UnitPoint(x: 0.9, y: 1))
    }

    /// Op macOS 26 doet het glas de ondergrond; hier komt alleen de kleur van de stijl
    /// overheen. Bij `.rustig` is dat niets — glas dat je volgooit met kleur is geen glas meer,
    /// en dat was precies de fout van de vorige ronde.
    @ViewBuilder private func kleurlaag(_ vorm: RoundedRectangle) -> some View {
        switch stijl {
        case .rustig, .aandacht(.grijs):
            EmptyView()
        default:
            vorm.fill(vulling).allowsHitTesting(false)
        }
    }

    private var boven: Color {
        switch stijl {
        case .rustig:            return Color.white.opacity(0.15)
        case .op:                return Palet.accent.opacity(0.26)
        case .aandacht(.grijs):  return Color.white.opacity(0.15)
        case .aandacht(let e):   return Palet.kleur(e).opacity(0.22)
        }
    }

    private var onder: Color {
        switch stijl {
        case .rustig:            return Color.white.opacity(0.055)
        case .op:                return Palet.accent.opacity(0.08)
        case .aandacht(.grijs):  return Color.white.opacity(0.055)
        case .aandacht(let e):   return Palet.kleur(e).opacity(0.06)
        }
    }

    /// Rand en glansje in één streek: een verloop van licht naar bijna niets langs de bovenkant
    /// geeft de tegel dezelfde opstaande rand als in het ontwerp, zonder een tweede laag.
    ///
    /// `allowsHitTesting(false)`, want deze laag ligt over de inhoud heen en de heldentegel
    /// heeft een schakelaar onder zijn bovenrand zitten.
    private func rand(_ vorm: RoundedRectangle) -> some View {
        vorm.strokeBorder(
            LinearGradient(colors: [randkleur.opacity(1), randkleur.opacity(0.35)],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 0.5)
            .allowsHitTesting(false)
    }

    private var randkleur: Color {
        switch stijl {
        case .rustig:            return Color.white.opacity(0.16)
        case .op:                return Palet.accent.opacity(0.45)
        case .aandacht(.grijs):  return Color.white.opacity(0.16)
        case .aandacht(let e):   return Palet.kleur(e).opacity(0.40)
        }
    }
}

extension View {
    /// Zet dit onderdeel op glas.
    func glas(straal: CGFloat = 13, stijl: Tegelstijl = .rustig) -> some View {
        modifier(Glas(straal: straal, stijl: stijl))
    }
}
