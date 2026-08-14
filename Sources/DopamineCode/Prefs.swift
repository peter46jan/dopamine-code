import Foundation

/// All persisted settings. Everything here survives a restart, per requirement 9.
enum Prefs {
    private static let d = UserDefaults.standard

    enum Key {
        static let autoOffHours = "autoOffHours"       // legacy, migrated to autoOffMinutes
        static let autoOffMinutes = "autoOffMinutes"
        static let batteryFloor = "batteryFloorPercent"
        static let displayOffOnActivate = "displayOffOnActivate"   // legacy Bool
        static let lockOnActivate = "lockOnActivate"               // legacy Bool
        static let lockMoment = "lockMoment"
        static let displayOffMoment = "displayOffMoment"
        static let soundFeedback = "soundFeedback"
        static let soundOnNetworkLoss = "soundOnNetworkLoss"
        static let notifications = "notifications"
        static let launchAtLogin = "launchAtLogin"
        static let backlightRestoreLevel = "backlightRestoreLevel"
        static let warnAboutAmphetamine = "warnAboutAmphetamine"
        static let blinkBacklightOnToggle = "blinkBacklightOnToggle"
        static let autoBrightnessWasSuppressed = "autoBrightnessWasSuppressed"
        static let autoBrightnessOriginallyOn = "autoBrightnessOriginallyOn"
    }

    /// The app used to be called Wakker, under a different bundle identifier. UserDefaults
    /// is keyed by that identifier, so without this every setting would silently reset to
    /// its default on the first launch after the rename.
    private static func migrateFromLegacyBundle() {
        let legacyDomain = "com.peter46jan.wakker"
        guard d.object(forKey: Key.autoOffMinutes) == nil,
              d.object(forKey: Key.autoOffHours) == nil,
              let legacy = d.persistentDomain(forName: legacyDomain), !legacy.isEmpty
        else { return }

        // Only our own keys. The legacy domain also holds AppKit-owned entries — window
        // frames, panel state, NSQuitAlwaysKeepsWindows — and carrying those into a new
        // bundle identifier imports another app's furniture along with the settings.
        let ours: Set<String> = [
            Key.autoOffMinutes, Key.autoOffHours, Key.batteryFloor,
            Key.lockMoment, Key.displayOffMoment,
            Key.displayOffOnActivate, Key.lockOnActivate,
            Key.soundFeedback, Key.soundOnNetworkLoss, Key.launchAtLogin,
            Key.backlightRestoreLevel, Key.warnAboutAmphetamine,
            Key.blinkBacklightOnToggle,
            Key.autoBrightnessWasSuppressed, Key.autoBrightnessOriginallyOn,
        ]
        for (key, value) in legacy where ours.contains(key) && d.object(forKey: key) == nil {
            d.set(value, forKey: key)
        }
        d.removePersistentDomain(forName: legacyDomain)
        NSLog("Instellingen overgenomen van %@ (%d sleutels).", legacyDomain, legacy.count)
    }

    static func registerDefaults() {
        migrateFromLegacyBundle()

        // Before register(defaults:), deliberately. `object(forKey:)` also returns values
        // from the registration domain, so once the new key has a registered default the
        // "has this ever been set?" test is always false and the migration never runs —
        // silently resetting a customised timer back to seven hours.
        migrateIfNeeded()
        migrateMomentsIfNeeded()

        d.register(defaults: [
            Key.autoOffMinutes: 7 * 60,     // requirement 5: default in the 6-8 hour band
            Key.batteryFloor: 15,
            Key.lockMoment: ActionMoment.lidClose.rawValue,
            Key.displayOffMoment: ActionMoment.lidClose.rawValue,
            Key.soundFeedback: true,
            Key.soundOnNetworkLoss: true,
            Key.notifications: true,
            Key.launchAtLogin: false,
            Key.backlightRestoreLevel: 0.5,
            Key.warnAboutAmphetamine: true,
            Key.blinkBacklightOnToggle: false,
            Key.autoBrightnessWasSuppressed: false,
            Key.autoBrightnessOriginallyOn: true,
        ])
    }

    /// The spec offered a sound *or* a blink of the keyboard backlight as confirmation.
    /// Sound is the default because a blink is invisible under a closed lid, which is the
    /// case this feature exists for — but both are available.
    static var blinkBacklightOnToggle: Bool {
        get { d.bool(forKey: Key.blinkBacklightOnToggle) }
        set { d.set(newValue, forKey: Key.blinkBacklightOnToggle) }
    }

    /// Setting a keyboard brightness only sticks with automatic brightness switched off,
    /// so the app switches it off — a change to a system setting the user never asked
    /// about. These two remember that it happened and what the value was, so it can be
    /// put back rather than silently left off forever.
    static var autoBrightnessWasSuppressed: Bool {
        get { d.bool(forKey: Key.autoBrightnessWasSuppressed) }
        set { d.set(newValue, forKey: Key.autoBrightnessWasSuppressed) }
    }

    static var autoBrightnessOriginallyOn: Bool {
        get { d.bool(forKey: Key.autoBrightnessOriginallyOn) }
        set { d.set(newValue, forKey: Key.autoBrightnessOriginallyOn) }
    }

    /// Minutes before the safety net releases the flag.
    ///
    /// Stored in whole minutes rather than fractional hours: a Double of hours cannot
    /// represent "6 h 20 m" exactly, and rounding drift in a value that decides when the
    /// Mac is allowed to sleep again is not worth the convenience.
    ///
    /// Clamped so a corrupted or hand-edited default can never produce a timer that
    /// effectively never fires.
    static var autoOffMinutes: Int {
        get { min(max(d.integer(forKey: Key.autoOffMinutes), 5), 24 * 60) }
        set { d.set(min(max(newValue, 5), 24 * 60), forKey: Key.autoOffMinutes) }
    }

    static var autoOffHoursPart: Int { autoOffMinutes / 60 }
    static var autoOffMinutesPart: Int { autoOffMinutes % 60 }

    /// Alleen nog voor teksten die in uren rekenen.
    ///
    /// Uitdrukkelijk NIET meer voor het plannen van een eindtijd: dat gaat sinds fase 1 via
    /// `AppModel.computeDeadline`, want een sessie kan een eigen duur en een eigen bovengrens
    /// hebben. Wie hier weer een eindtijd uit gaat rekenen, bouwt een tweede planner.
    static var autoOffHours: Double { Double(autoOffMinutes) / 60 }

    /// Carries an older install's fractional-hours setting over to whole minutes, once.
    /// Without this, upgrading would silently reset a customised timer back to the default.
    static func migrateIfNeeded() {
        guard d.object(forKey: Key.autoOffMinutes) == nil,
              let legacyHours = d.object(forKey: Key.autoOffHours) as? Double
        else { return }
        // Clamp in Double space before converting. `Int(_:)` traps on a value outside
        // Int's range, and this runs at launch before any UI exists — a corrupted or
        // hand-edited defaults entry would crash the app on every start with no way in.
        let clampedHours = min(max(legacyHours.isFinite ? legacyHours : 7, 0), 24)
        autoOffMinutes = Int((clampedHours * 60).rounded())
        d.removeObject(forKey: Key.autoOffHours)
    }

    /// Carries the old on/off booleans over to the moment-based settings. "It was on"
    /// becomes "do it when the lid closes", because that is what the switch was always
    /// meant to achieve; "it was off" stays off.
    static func migrateMomentsIfNeeded() {
        for (legacyKey, newKey) in [(Key.lockOnActivate, Key.lockMoment),
                                    (Key.displayOffOnActivate, Key.displayOffMoment)] {
            guard d.object(forKey: newKey) == nil,
                  let wasOn = d.object(forKey: legacyKey) as? Bool else { continue }
            d.set((wasOn ? ActionMoment.lidClose : .never).rawValue, forKey: newKey)
            d.removeObject(forKey: legacyKey)
        }
    }

    static var batteryFloor: Int {
        get { min(max(d.integer(forKey: Key.batteryFloor), 5), 90) }
        set { d.set(min(max(newValue, 5), 90), forKey: Key.batteryFloor) }
    }

    /// When locking and blanking should happen.
    ///
    /// The original build did both at the moment you switched keep-awake on, which makes
    /// the feature unusable for its most ordinary case: switch it on, carry on working,
    /// and have the machine secure itself when you shut the lid. The lid sensor was
    /// already being watched; it just was not driving these two actions.
    enum ActionMoment: String, CaseIterable, Identifiable {
        case lidClose
        case activate
        case never

        var id: String { rawValue }

        var label: String {
            switch self {
            case .lidClose: return "Zodra ik de klep dichtdoe"
            case .activate: return "Meteen bij aanzetten"
            case .never: return "Nooit"
            }
        }
    }

    static var lockMoment: ActionMoment {
        get { ActionMoment(rawValue: d.string(forKey: Key.lockMoment) ?? "") ?? .lidClose }
        set { d.set(newValue.rawValue, forKey: Key.lockMoment) }
    }

    static var displayOffMoment: ActionMoment {
        get { ActionMoment(rawValue: d.string(forKey: Key.displayOffMoment) ?? "") ?? .lidClose }
        set { d.set(newValue.rawValue, forKey: Key.displayOffMoment) }
    }

    static var soundFeedback: Bool {
        get { d.bool(forKey: Key.soundFeedback) }
        set { d.set(newValue, forKey: Key.soundFeedback) }
    }

    static var soundOnNetworkLoss: Bool {
        get { d.bool(forKey: Key.soundOnNetworkLoss) }
        set { d.set(newValue, forKey: Key.soundOnNetworkLoss) }
    }

    /// On by default. A sound plays into an empty room; a notification waits for the screen
    /// to be unlocked and is still there hours later, which is the only channel that matches
    /// how this app is actually used.
    static var notifications: Bool {
        get { d.bool(forKey: Key.notifications) }
        set { d.set(newValue, forKey: Key.notifications) }
    }

    static var launchAtLogin: Bool {
        get { d.bool(forKey: Key.launchAtLogin) }
        set { d.set(newValue, forKey: Key.launchAtLogin) }
    }

    /// Level the keyboard backlight returns to when switched back on.
    static var backlightRestoreLevel: Float {
        get {
            let v = d.float(forKey: Key.backlightRestoreLevel)
            return v > 0.01 ? min(v, 1) : 0.5
        }
        set { d.set(min(max(newValue, 0), 1), forKey: Key.backlightRestoreLevel) }
    }

    static var warnAboutAmphetamine: Bool {
        get { d.bool(forKey: Key.warnAboutAmphetamine) }
        set { d.set(newValue, forKey: Key.warnAboutAmphetamine) }
    }
}
