import Foundation

/// Installs, checks and removes the narrow sudoers rule that lets Dopamine Code flip
/// `disablesleep` without a password.
enum SudoersGrant {

    static let path = "/etc/sudoers.d/dopamine-code-disablesleep"

    enum Status: Equatable {
        /// Both commands are permitted without a password.
        case granted
        /// The file is absent, or present but no longer effective.
        case missing
        /// The file exists but sudo will not confirm the commands — usually a rule for a
        /// different user, or a broken sudoers parse.
        case present(butNotEffective: String)
    }

    /// Asks sudo whether the two exact command lines are permitted **without a password**,
    /// without running them.
    ///
    /// A single `-l` cannot answer that question. `man sudo`: if a command "is permitted by
    /// the security policy … the fully-qualified path to the command is displayed" — exit 0
    /// means permitted, nothing more. And `man sudoers`: *"if the NOPASSWD tag is applied to
    /// any of a user's entries for the current host, the user will be able to run 'sudo -l'
    /// without a password."* Together those two make a plain `sudo -n -l` a false positive
    /// generator: one unrelated NOPASSWD drop-in makes the listing itself passwordless, and
    /// stock macOS ships `%admin ALL=(ALL) ALL`, so every pmset line then exits 0 whether or
    /// not our rule matches.
    ///
    /// `-l -l` displays "the matching rule … in a verbose format", tags included. That is
    /// the only form that distinguishes "you may run this" from "you may run this without
    /// typing a password" — which is the whole question, because every unattended release
    /// path runs with the lid shut where no password can be typed.
    static func check() -> Status {
        let fileExists = FileManager.default.fileExists(atPath: path)

        var lastError = ""
        for value in ["1", "0"] {
            let r = Shell.run(
                "/usr/bin/sudo",
                ["-n", "-l", "-l", "/usr/bin/pmset", "-a", "disablesleep", value],
                timeout: 10
            )
            guard r.ok else {
                lastError = r.combined
                break
            }
            // sudoers renders the tag as `Options: !authenticate` in the verbose format and
            // as `NOPASSWD:` in the short rule format. Accept either.
            let text = r.combined
            guard text.contains("!authenticate") || text.contains("NOPASSWD") else {
                lastError = "sudo staat 'pmset -a disablesleep \(value)' wel toe, maar niet zonder "
                    + "wachtwoord — waarschijnlijk via de standaardregel voor beheerders, niet via de Dopamine Code-regel."
                break
            }
            if value == "0" { return .granted }
        }

        // Failing safe: an unrecognised output format reports "not effective", which shows
        // the warning and the install button. Being wrong in that direction costs a needless
        // warning; being wrong the other way lets the user walk away from a Mac that will
        // never sleep again.
        if fileExists { return .present(butNotEffective: lastError.isEmpty ? "sudo weigert de regel" : lastError) }
        return .missing
    }

    /// The copy in `Contents/Resources`, kept so you can read and run it by hand. It is
    /// deliberately **not** what gets executed as root — see `runScriptAsRoot`.
    static var readableScriptURL: URL? {
        Bundle.main.url(forResource: "grant", withExtension: "sh")
    }

    /// Installs the rule through a single authorisation prompt.
    enum InstallOutcome {
        case installed
        case cancelled
        case failed(String)
    }

    /// Runs the grant script as root **from the signed binary, never from a file path.**
    ///
    /// Handing `do shell script … with administrator privileges` a path under
    /// `Contents/Resources` means root executes whatever that file contains at that moment
    /// — and the bundle sits in `/Applications` owned by the logged-in user, so any process
    /// running as that user can rewrite it. The user then types an admin password for a
    /// prompt that says "a sudoers rule for exactly two pmset commands", and something else
    /// entirely runs as root. Verifying the signature first would not fix it either: root
    /// re-opens the path afterwards, so the file can be swapped in between.
    ///
    /// So the script text is compiled into the binary by `build.sh` and piped to the root
    /// shell. There is no path for an attacker to substitute. The base64 wrapper is not
    /// obfuscation — it guarantees the payload contains no quote or backslash that would
    /// need escaping inside the AppleScript string.
    private static func runScriptAsRoot(arguments: String, prompt: String) -> InstallOutcome {
        let payload = GrantScript.base64
        guard !payload.isEmpty else {
            return .failed("Het grant-script is niet in de app ingebouwd. Bouw opnieuw met ./build.sh")
        }
        guard payload.range(of: "^[A-Za-z0-9+/=]+$", options: .regularExpression) != nil else {
            return .failed("Ingebouwd grant-script is beschadigd.")
        }

        let user = NSUserName()
        guard user.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return .failed("Ongeldige gebruikersnaam '\(user)'.")
        }

        let command = "/bin/echo \(payload) | /usr/bin/base64 -d | "
            + "DOPAMINE_USER='\(user)' /bin/bash -s -- \(arguments)"

        let result = Shell.runAsAdmin(command, prompt: prompt)

        if Shell.wasCancelled(result) {
            EventLog.shared.warn("Beheerdersprompt geannuleerd.")
            return .cancelled
        }
        guard result.ok else {
            EventLog.shared.error("Sudoers-script mislukte: \(result.combined)")
            return .failed(result.combined)
        }
        return .installed
    }

    static func install() -> InstallOutcome {
        let outcome = runScriptAsRoot(
            arguments: "",
            prompt: "Dopamine Code installeert een sudoers-regel voor precies twee pmset-commando's."
        )
        if case .installed = outcome {
            EventLog.shared.info("Sudoers-regel geïnstalleerd.")
        }
        return outcome
    }

    static func remove() -> InstallOutcome {
        let outcome = runScriptAsRoot(
            arguments: "--remove",
            prompt: "Dopamine Code verwijdert zijn sudoers-regel."
        )
        if case .installed = outcome {
            EventLog.shared.info("Sudoers-regel verwijderd.")
        }
        return outcome
    }

    /// The literal rule that gets installed, for display in the UI so it can be read
    /// before it is authorised.
    static var ruleText: String {
        "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    /// A one-liner the user can paste into Terminal instead of using the prompt, shown when
    /// the authorisation sheet misbehaves and is the only route left.
    ///
    /// This used to run the on-disk copy: `sudo … /bin/bash '<bundle>/Resources/grant.sh'`.
    /// A security audit showed why that was wrong. That file is `-rwxr-xr-x` and owned by the
    /// user, so any process running as the user can rewrite its contents beforehand — and the
    /// app was telling the user to run exactly that file as root. The reader-friendly copy in
    /// the bundle stays (`readableScriptURL`, so the script can be read before it is trusted),
    /// but it is no longer in any execution path.
    ///
    /// Instead this pipes the SAME base64 payload that is compiled into the binary
    /// (`GrantScript.base64`) into root's shell, exactly like the GUI route in
    /// `runScriptAsRoot`. The bytes come from the signed binary, not from a file an
    /// unprivileged process can swap. `env` runs after sudo has decided, so the assignment is
    /// not a sudo-level environment variable (which `env_reset` would refuse anyway).
    static var manualCommand: String {
        let payload = GrantScript.base64
        guard !payload.isEmpty,
              NSUserName().range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        else { return "" }
        return "/bin/echo \(payload) | /usr/bin/base64 -d | "
            + "sudo /usr/bin/env DOPAMINE_USER=\(NSUserName()) /bin/bash -s"
    }
}
