import Cocoa
import CoreGraphics

/// Keyboard backlight control, entirely independent of the keep-awake machinery.
///
/// Two mechanisms, in order of preference:
///
/// 1. `CoreBrightness.KeyboardBrightnessClient`, loaded dynamically. Absolute values,
///    no TCC approval of any kind, no root, and a real read-back so on/off can be a
///    genuine toggle.
/// 2. The synthetic illumination keys via `CGEvent`, as a fallback.
///
/// Neither writes to the SMC.
///
/// Measured on this Mac (Mac17,2 / M5 / macOS 26.5.2): the function row has no
/// illumination keys at all, `NX_KEYTYPE_ILLUMINATION_UP`/`DOWN` still move the
/// backlight in steps of exactly 1/16, and `NX_KEYTYPE_ILLUMINATION_TOGGLE` is a
/// measured no-op. That is why the toggle is built on read-then-set rather than on the
/// toggle keycode.
final class KeyboardBacklight {

    // MARK: - CoreBrightness (primary)

    private var client: NSObject?
    private var keyboardID: UInt64 = 1

    private typealias GetFloat = @convention(c) (NSObject, Selector, UInt64) -> Float
    private typealias SetFloat = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool
    private typealias SetFloatFade = @convention(c) (NSObject, Selector, Float, Int32, ObjCBool, UInt64) -> ObjCBool
    private typealias SetBool = @convention(c) (NSObject, Selector, ObjCBool, UInt64) -> ObjCBool
    private typealias CopyIDs = @convention(c) (NSObject, Selector) -> NSArray?

    init() {
        guard Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework")?.load() == true,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else {
            EventLog.shared.warn("CoreBrightness.KeyboardBrightnessClient niet beschikbaar; val terug op CGEvent.")
            return
        }
        let instance = cls.init()
        client = instance

        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        if let fn = Self.implementation(instance, sel, as: CopyIDs.self),
           let first = fn(instance, sel)?.firstObject as? NSNumber {
            keyboardID = first.uint64Value
        }
    }

    /// Whether the preferred, permission-free path is available.
    var hasDirectControl: Bool { client != nil }

    private static func implementation<T>(_ object: NSObject, _ selector: Selector, as signature: T.Type) -> T? {
        guard let method = class_getInstanceMethod(Swift.type(of: object), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: signature)
    }

    /// Current level in 0...1, or nil if it cannot be read.
    var level: Float? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString("brightnessForKeyboard:")
        guard let fn = Self.implementation(c, sel, as: GetFloat.self) else { return nil }
        let v = fn(c, sel, keyboardID)
        return v < 0 ? nil : v
    }

    var isOn: Bool? {
        level.map { $0 > 0.001 }
    }

    /// Whether the system is currently suppressing the backlight — which it does while
    /// the display is asleep. That is exactly the state this app puts the machine in, so
    /// a write can succeed, read back correctly, and still light nothing.
    var isSuppressed: Bool? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString("isBacklightSuppressedOnKeyboard:")
        typealias GetBool = @convention(c) (NSObject, Selector, UInt64) -> ObjCBool
        guard let fn = Self.implementation(c, sel, as: GetBool.self) else { return nil }
        return fn(c, sel, keyboardID).boolValue
    }

    @discardableResult
    func setLevel(_ value: Float, fadeMilliseconds: Int32 = 250) -> Bool {
        guard client != nil else { return false }

        // The ambient-light loop in corebrightnessd pulls a manually written value back
        // within about a minute. Every write therefore has to pin auto-brightness off
        // first, or the change looks successful and then quietly undoes itself.
        //
        // That is a change to a system setting the user did not ask about, so the original
        // value is remembered once and can be put back — from Settings, or on quit.
        if !Prefs.autoBrightnessWasSuppressed {
            Prefs.autoBrightnessOriginallyOn = isAutoBrightnessEnabled ?? true
            Prefs.autoBrightnessWasSuppressed = true
        }
        _ = setAutoBrightnessRaw(false)

        return setBrightnessRaw(value, fadeMilliseconds: fadeMilliseconds)
    }

    /// The ambient light sensor drifts a manually set level back over time. Switching
    /// auto-brightness off makes a chosen level stick.
    ///
    /// `setLevel` calls the raw form directly to avoid recursing back into itself.
    @discardableResult
    func setAutoBrightness(_ enabled: Bool) -> Bool {
        setAutoBrightnessRaw(enabled)
    }

    var isAutoBrightnessEnabled: Bool? {
        guard let c = client else { return nil }
        let sel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
        typealias GetBool = @convention(c) (NSObject, Selector, UInt64) -> ObjCBool
        guard let fn = Self.implementation(c, sel, as: GetBool.self) else { return nil }
        return fn(c, sel, keyboardID).boolValue
    }

    /// "Nothing to undo" and "the undo was rejected" are opposite outcomes and used to
    /// collapse into the same `false` — so a refused restore was reported to the user as
    /// reassurance, and auto-brightness stayed off with nothing left to say so.
    enum RestoreResult {
        case restored
        case nothingToRestore
        case refused
    }

    /// Puts automatic keyboard brightness back the way it was before this app first
    /// switched it off. Called on quit, and available from Settings.
    @discardableResult
    func restoreAutoBrightness() -> RestoreResult {
        guard Prefs.autoBrightnessWasSuppressed else { return .nothingToRestore }
        guard setAutoBrightnessRaw(Prefs.autoBrightnessOriginallyOn) else {
            EventLog.shared.error("CoreBrightness weigerde automatische toetsenbordhelderheid terug te zetten.")
            return .refused
        }
        Prefs.autoBrightnessWasSuppressed = false
        EventLog.shared.info("Automatische toetsenbordhelderheid teruggezet naar \(Prefs.autoBrightnessOriginallyOn ? "aan" : "uit").")
        return .restored
    }

    /// Writes the level and nothing else — no auto-brightness bookkeeping, no `Prefs`.
    ///
    /// `blink()` needs this: it runs off the main thread, and `setLevel`'s
    /// read-modify-write of the two auto-brightness preferences would race the main-actor
    /// callers of `setLevel`/`restoreAutoBrightness`. It also should not permanently switch
    /// a system setting off on behalf of a 560-millisecond flash.
    @discardableResult
    private func setBrightnessRaw(_ value: Float, fadeMilliseconds: Int32) -> Bool {
        guard let c = client else { return false }
        let clamped = min(max(value, 0), 1)
        let fadeSel = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
        if let fn = Self.implementation(c, fadeSel, as: SetFloatFade.self) {
            return fn(c, fadeSel, clamped, fadeMilliseconds, true, keyboardID).boolValue
        }
        let plainSel = NSSelectorFromString("setBrightness:forKeyboard:")
        if let fn = Self.implementation(c, plainSel, as: SetFloat.self) {
            return fn(c, plainSel, clamped, keyboardID).boolValue
        }
        return false
    }

    @discardableResult
    private func setAutoBrightnessRaw(_ enabled: Bool) -> Bool {
        guard let c = client else { return false }
        let sel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
        guard let fn = Self.implementation(c, sel, as: SetBool.self) else { return false }
        return fn(c, sel, ObjCBool(enabled), keyboardID).boolValue
    }

    // MARK: - Public toggle

    enum ToggleResult {
        case turnedOn(Float)
        case turnedOff
        case needsAccessibility
        case unavailable
    }

    /// Turns the backlight fully off, or back to the remembered level.
    @discardableResult
    func toggle() -> ToggleResult {
        if hasDirectControl {
            guard let current = level else { return .unavailable }
            if current > 0.001 {
                Prefs.backlightRestoreLevel = current
                // `setLevel` disables auto-brightness itself, and does it *after* recording
                // what the setting was. Switching it off here first meant the recorded
                // "original" value was the one we had just written, so restoring it later
                // restored it to off — the restore looked like it worked and changed nothing.
                return setLevel(0) ? .turnedOff : .unavailable
            } else {
                let restore = Prefs.backlightRestoreLevel
                return setLevel(restore) ? .turnedOn(restore) : .unavailable
            }
        }
        return toggleViaKeys()
    }

    @discardableResult
    func setOn(_ on: Bool) -> ToggleResult {
        if hasDirectControl {
            guard let current = level else { return .unavailable }
            if on {
                if current <= 0.001 {
                    let restore = Prefs.backlightRestoreLevel
                    return setLevel(restore) ? .turnedOn(restore) : .unavailable
                }
                return .turnedOn(current)
            } else {
                if current > 0.001 {
                    // setLevel handles auto-brightness, after capturing its original value.
                    Prefs.backlightRestoreLevel = current
                }
                return setLevel(0) ? .turnedOff : .unavailable
            }
        }
        return on ? stepUpToRestore() : stepAllTheWayDown()
    }

    // MARK: - CGEvent fallback

    private enum AuxKey: Int {
        case illuminationUp = 21    // NX_KEYTYPE_ILLUMINATION_UP
        case illuminationDown = 22  // NX_KEYTYPE_ILLUMINATION_DOWN
    }

    /// Posting events requires Accessibility approval. `CGPreflightPostEventAccess` is the
    /// API Apple names for exactly this case; Input Monitoring is a different permission
    /// (`CGPreflightListenEventAccess`) and is not needed.
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    static func requestEventAccess() -> Bool {
        CGRequestPostEventAccess()
    }

    private func postAuxKey(_ key: AuxKey) {
        let keyDown = 0x0a  // NX_KEYDOWN
        let keyUp = 0x0b    // NX_KEYUP
        for (state, flags) in [(keyDown, 0xa00), (keyUp, 0xb00)] {
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,                                       // NX_SUBTYPE_AUX_CONTROL_BUTTONS
                data1: (key.rawValue << 16) | (state << 8),
                data2: -1
            ), let cg = event.cgEvent else { return }
            cg.post(tap: .cghidEventTap)
        }
    }

    /// The backlight moves in sixteenths, so sixteen presses reach either end from anywhere.
    private func stepAllTheWayDown() -> ToggleResult {
        guard Self.canPostEvents else { return .needsAccessibility }
        for _ in 0..<16 { postAuxKey(.illuminationDown); usleep(12_000) }
        return .turnedOff
    }

    private func stepUpToRestore() -> ToggleResult {
        guard Self.canPostEvents else { return .needsAccessibility }
        let steps = Int((Prefs.backlightRestoreLevel * 16).rounded())
        for _ in 0..<max(steps, 1) { postAuxKey(.illuminationUp); usleep(12_000) }
        return .turnedOn(Prefs.backlightRestoreLevel)
    }

    private var keyFallbackAssumesOn = true

    /// What the fallback believes the current state to be. Without CoreBrightness there is
    /// no read-back at all, and the UI has to show *something* — showing "off" forever,
    /// including right after the user switched it on, is worse than showing intent.
    var assumedOn: Bool { keyFallbackAssumesOn }

    private func toggleViaKeys() -> ToggleResult {
        // Without CoreBrightness there is no read-back, so track intent locally.
        let result = keyFallbackAssumesOn ? stepAllTheWayDown() : stepUpToRestore()
        if case .needsAccessibility = result { return result }
        keyFallbackAssumesOn.toggle()
        return result
    }

    /// A short blink, used as tactile confirmation when the menu bar is not visible.
    ///
    /// Deliberately built on `setBrightnessRaw`. The earlier version drove `setLevel` from
    /// a global queue, which meant half a second of read-modify-write on two `UserDefaults`
    /// keys racing whatever the main actor was doing with the slider or the restore button
    /// — and it left auto-brightness permanently switched off as a side effect of a flash
    /// the user asked for as *feedback*. A blink should change nothing.
    func blink(times: Int = 2) {
        guard hasDirectControl, let original = level else { return }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for _ in 0..<times {
                setBrightnessRaw(original > 0.5 ? 0 : 1, fadeMilliseconds: 0)
                usleep(140_000)
                setBrightnessRaw(original, fadeMilliseconds: 0)
                usleep(140_000)
            }
        }
    }

    /// Opens the exact settings pane the user needs when Accessibility is missing.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
