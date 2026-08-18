import Foundation

/// De klok van de app: hoeveel hele minuten er nog te gaan zijn.
///
/// Eén functie, en dat is het hele punt. Drie plekken telden dit zelf uit — de menubalk, de
/// statuskaart en de zin in het logboek — en twee daarvan rondden naar boven af terwijl de
/// derde afkapte met een gehele deling op seconden. Dat scheelde structureel een minuut: de
/// menubalk zei `3:13` boven een logregel die `3 u 12 min` meldde. Twee getallen voor één klok
/// laat een lezer zoeken naar een verschil dat er niet is.
///
/// Los bestand en zonder afhankelijkheden, zodat `verify.sh --paneel` het kan compileren en
/// natrekken. Dit is precies het soort ding dat fout kan zijn zonder dat je het ziet.
enum Aftelling {

    /// Hele minuten tot `deadline`, naar boven afgerond en nooit negatief.
    ///
    /// **Naar boven**, want `0:00` terwijl er nog veertig seconden staan leest als "voorbij" —
    /// en dit is een aftelling waar een vangnet aan hangt.
    ///
    /// **Nooit negatief**, want een deadline die net gepasseerd is hoort geen `-1` te tonen
    /// maar nul. Dat de sessie dan nog een tel doorloopt is een kwestie van de tik die hem
    /// opruimt, niet van de klok die hem toont.
    static func minutenTot(_ deadline: Date, vanaf nu: Date) -> Int {
        max(0, Int((deadline.timeIntervalSince(nu) / 60).rounded(.up)))
    }
}
