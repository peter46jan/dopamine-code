import Foundation

/// Het venster waarin het schema zichzelf aan mag zetten — puur datumrekenwerk.
///
/// Er zit hier bewust geen `Timer` in en geen enkele verwijzing naar de rest van de app.
/// Een `ScheduleWatch` die om 09:00:00 zelf zou aanzetten is een tweede bron van waarheid
/// naast de guardian, én hij zou niet afgaan als de Mac om 09:00 sliep. Dit ding levert
/// alleen feiten: valt dit moment in een venster, en zo ja, wanneer begon dat venster en
/// wanneer eindigt het. Wie daar iets mee doet staat in `AppModel.evaluateTriggers()`.
///
/// De weekdagnummers zijn die van `Calendar.component(.weekday:)`: 1 = zondag … 7 = zaterdag.
struct ScheduleWindow: Equatable {

    /// Op welke dagen het venster begint. Bij een venster over middernacht heen hoort de dag
    /// bij het *begin*: "elke werkdag 22:00–06:00" loopt vrijdagnacht dus door tot zaterdag
    /// 06:00, en begint zaterdagavond niet opnieuw.
    let dagen: Set<Int>
    /// Minuten na middernacht, 0…1439.
    let startMinuut: Int
    let eindMinuut: Int

    /// Hoe lang het venster duurt. Een eind vóór het begin betekent: over middernacht heen.
    var duurMinuten: Int {
        eindMinuut > startMinuut ? eindMinuut - startMinuut : eindMinuut + 24 * 60 - startMinuut
    }

    var loopOverMiddernacht: Bool { eindMinuut <= startMinuut }

    /// Waarom dit venster nooit open kan gaan, in gewone taal — of `nil` als het klopt.
    ///
    /// Bestaat omdat een schema dat aanstaat maar nooit iets doet erger is dan geen schema:
    /// je vertrouwt erop en het gebeurt niet. De aanroeper zet dit in het logboek.
    var probleem: String? {
        if dagen.isEmpty { return "er is geen enkele dag aangevinkt" }
        if startMinuut == eindMinuut { return "de begintijd en de eindtijd zijn hetzelfde" }
        return nil
    }

    /// Het beginmoment van het venster waarin `nu` valt, of `nil` als `nu` in geen venster
    /// valt. Dít is de sleutel voor de flankbewaking: twee momenten binnen hetzelfde venster
    /// geven dezelfde `Date` terug, en dat is hoe "dit venster heb ik al gehad" opgeschreven
    /// kan worden zonder mee te tellen hoe vaak er gekeken is.
    ///
    /// De kalender komt per aanroep binnen in plaats van opgeslagen te worden, zodat een
    /// tijdzonewissel of een nieuwe dag meteen meetelt in plaats van pas na een herstart.
    func begin(op nu: Date, kalender: Calendar = .current) -> Date? {
        guard probleem == nil else { return nil }

        // Ook gisteren nakijken: bij een venster over middernacht heen valt 02:00 vannacht in
        // het venster dat gisteravond om 22:00 begon.
        for dagOffset in [0, -1] {
            guard let dag = kalender.date(byAdding: .day, value: dagOffset, to: nu),
                  let start = moment(startMinuut, op: dag, kalender: kalender)
            else { continue }
            guard dagen.contains(kalender.component(.weekday, from: start)) else { continue }
            guard let eind = einde(vanBegin: start, kalender: kalender) else { continue }
            if nu >= start && nu < eind { return start }
        }
        return nil
    }

    /// Wanneer het venster dat op `begin` startte weer dichtgaat.
    ///
    /// Op de kalender uitgerekend en niet als "begin + duur in seconden": op de nacht dat de
    /// klok verzet wordt zou 09:00–18:00 anders om 17:00 of 19:00 eindigen. Wat er in de
    /// instellingen staat is een kloktijd, dus die moet het ook blijven.
    func einde(vanBegin begin: Date, kalender: Calendar = .current) -> Date? {
        let dag = loopOverMiddernacht
            ? kalender.date(byAdding: .day, value: 1, to: begin)
            : begin
        guard let dag, let eind = moment(eindMinuut, op: dag, kalender: kalender) else { return nil }
        // Achtervang voor de zeldzame kalender waarin het bovenstaande een moment vóór het
        // begin oplevert (een dag die op zomertijd een uur verspringt): dan liever de duur in
        // seconden dan een eindtijd die al voorbij is en de sessie meteen weer stopt.
        return eind > begin ? eind : begin.addingTimeInterval(Double(duurMinuten) * 60)
    }

    /// De kloktijd `minuutVanDeDag` op de kalenderdag waar `dag` in valt.
    ///
    /// Met losse `DateComponents` en niet met `date(bySettingHour:of:)`: die laatste zoekt het
    /// *eerstvolgende* moment ná de meegegeven datum, dus een venster dat om 00:00 begint
    /// kwam er een etmaal te laat uit. Precies het soort fout dat pas opvalt als iemand een
    /// nachtvenster instelt.
    private func moment(_ minuutVanDeDag: Int, op dag: Date, kalender: Calendar) -> Date? {
        var onderdelen = kalender.dateComponents([.year, .month, .day], from: dag)
        onderdelen.hour = minuutVanDeDag / 60
        onderdelen.minute = minuutVanDeDag % 60
        onderdelen.second = 0
        return kalender.date(from: onderdelen)
    }

    // MARK: - Tekst

    static func klok(_ minuutVanDeDag: Int) -> String {
        String(format: "%02d:%02d", minuutVanDeDag / 60, minuutVanDeDag % 60)
    }

    /// De zin die in het paneel, in het logboek en in `verify.sh --report` terechtkomt.
    var omschrijving: String {
        "\(dagenTekst) van \(Self.klok(startMinuut)) tot \(Self.klok(eindMinuut))"
    }

    private var dagenTekst: String {
        if dagen == Set(1...7) { return "elke dag" }
        if dagen == [2, 3, 4, 5, 6] { return "elke werkdag" }
        if dagen == [1, 7] { return "elk weekend" }
        // Op maandag beginnen, niet op zondag: zo lezen we hier een week.
        let volgorde = [2, 3, 4, 5, 6, 7, 1]
        let namen = volgorde.filter { dagen.contains($0) }.map { Self.korteDagnaam($0) }
        return namen.isEmpty ? "nooit" : namen.joined(separator: ", ")
    }

    static func korteDagnaam(_ weekdag: Int) -> String {
        ["", "zo", "ma", "di", "wo", "do", "vr", "za"][max(1, min(7, weekdag))]
    }
}
