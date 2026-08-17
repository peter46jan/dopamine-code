import SwiftUI

/// Liquid Glass, met een terugval voor macOS 14 en 15.
///
/// `.glassEffect()` bestaat pas vanaf macOS 26 en `build.sh` bouwt voor 14.0. Dat blijft zo:
/// de terugval is één aftakking op één plek, en niemand wegsturen weegt zwaarder dan een
/// schonere aanroep. Op 14 en 15 ziet het er soberder uit; de indeling is dezelfde.
///
/// `.ultraThinMaterial` en niet een egale kleur, omdat het paneel dan op beide versies
/// doorschijnend blijft — de indeling rekent op een achtergrond die meebeweegt.
struct Glas: ViewModifier {
    var straal: CGFloat = 12
    var oplichtend = false

    func body(content: Content) -> some View {
        let vorm = RoundedRectangle(cornerRadius: straal, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: vorm)
                .overlay(randje(vorm))
        } else {
            content
                .background(.ultraThinMaterial, in: vorm)
                .overlay(vorm.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .overlay(randje(vorm))
        }
    }

    /// Een lopende sessie krijgt een accentrandje en verder niets.
    ///
    /// Eerst stond hier `.tint(.accentColor)` op het glas zelf. Dat overspoelde de hele kaart
    /// met de accentkleur — bij de standaardinstelling een egaal blauw vlak waar zwarte tekst
    /// nauwelijks in te lezen was. Glas dat je volgooit met kleur is geen glas meer.
    ///
    /// Dat de sessie loopt staat toch al drie keer op de kaart: de zon, de gevulde boog en de
    /// schakelaar. Een randje is genoeg.
    @ViewBuilder private func randje(_ vorm: RoundedRectangle) -> some View {
        if oplichtend {
            vorm.strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
        }
    }
}

extension View {
    /// Zet dit onderdeel op glas. `oplichtend` is voor de statuskaart tijdens een sessie.
    func glas(straal: CGFloat = 12, oplichtend: Bool = false) -> some View {
        modifier(Glas(straal: straal, oplichtend: oplichtend))
    }
}
