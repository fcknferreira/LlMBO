import Foundation
import IOKit
import IOKit.ps
import CoreGraphics

/// Tudo que mexe com energia: repouso com tampa fechada, estado da tampa e bateria.
enum Power {
    static let sudoersPath = "/etc/sudoers.d/llmbo"

    /// A "permissão" do LlMBO é uma regra do sudo que libera só estes dois comandos sem senha.
    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    @discardableResult
    static func installHelper() -> Bool {
        let user = NSUserName()
        // schedule wake: acordar o Mac antes do reset do limite de uso (aba Uso).
        let rule = "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, "
            + "/usr/bin/pmset schedule wake *, /usr/bin/pmset schedule cancel wake *"
        let cmd = "t=$(/usr/bin/mktemp /tmp/llmbo.XXXXXX) && /bin/echo '\(rule)' > $t && /usr/sbin/visudo -cf $t && /usr/sbin/chown root:wheel $t && /bin/chmod 440 $t && /bin/mv $t \(sudoersPath)"
        return runAsAdmin(cmd)
    }

    @discardableResult
    static func uninstallHelper() -> Bool {
        setSleepDisabled(false)
        return runAsAdmin("/bin/rm -f \(sudoersPath)")
    }

    private static func runAsAdmin(_ cmd: String) -> Bool {
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    /// Enquanto o LlMBO segura, outro app pode religar o repouso por baixo dele (o AlDente tem uma função própria
    /// que mexe no mesmo `disablesleep`, com timer). Religar de novo, mas sem brigar: 3 vezes em 10 min e desiste.
    struct SleepGuard {
        enum Action: Equatable { case ok, restore, giveUp }
        static let maxRestores = 3
        static let window: TimeInterval = 600
        private(set) var restores: [Date] = []
        private(set) var gaveUp = false

        mutating func check(sleepDisabled: Bool, now: Date) -> Action {
            guard !sleepDisabled, !gaveUp else { return .ok }
            restores.removeAll { now.timeIntervalSince($0) > Self.window }
            if restores.count >= Self.maxRestores { gaveUp = true; return .giveUp }
            restores.append(now)
            return .restore
        }

        /// LLMBO_TEST_SLEEPGUARD=1. Grava sleepguard-test.log.
        static func selfTest() {
            var out: [String] = []
            func check(_ name: String, _ ok: Bool) { out.append("\(ok ? "ok " : "ERRO") \(name)") }
            let t0 = Date()
            var g = SleepGuard()
            check("repouso desligado: nada a fazer", g.check(sleepDisabled: true, now: t0) == .ok)
            check("religado por fora: desliga de novo", g.check(sleepDisabled: false, now: t0) == .restore)
            check("2ª vez: desliga de novo", g.check(sleepDisabled: false, now: t0 + 60) == .restore)
            check("3ª vez: desliga de novo", g.check(sleepDisabled: false, now: t0 + 120) == .restore)
            check("4ª vez em 10 min: desiste", g.check(sleepDisabled: false, now: t0 + 180) == .giveUp)
            check("depois de desistir: não mexe mais", g.check(sleepDisabled: false, now: t0 + 240) == .ok)
            var h = SleepGuard()
            for i in 0..<3 { _ = h.check(sleepDisabled: false, now: t0 + Double(i) * 60) }
            check("passados 10 min, a conta zera", h.check(sleepDisabled: false, now: t0 + 900) == .restore)
            try? out.joined(separator: "\n").write(to: Paths.support.appendingPathComponent("sleepguard-test.log"),
                                                   atomically: true, encoding: .utf8)
        }
    }

    /// Liga/desliga o repouso do sistema (inclusive ao fechar a tampa).
    @discardableResult
    static func setSleepDisabled(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]).status == 0
    }

    static var sleepDisabled: Bool {
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.first == "SleepDisabled" { return parts.last == "1" }
        }
        return false
    }

    /// A regra do sudo instalada já libera `pmset schedule` (versões antigas só liberavam o disablesleep).
    /// Testa de verdade, cancelando um despertar que não existe: `sudo -l` diria "permitido" para quem é
    /// administrador mesmo quando o comando pede senha.
    static var canScheduleWake: Bool {
        !run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", "01/01/30 00:00:00"]).output
            .contains("sudo:")
    }

    private static func pmsetDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yy HH:mm:ss"
        return f.string(from: d)
    }

    /// Agenda o Mac para acordar (mesmo dormindo de tampa fechada) na hora dada.
    @discardableResult
    static func scheduleWake(_ d: Date) -> Bool {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "wake", pmsetDate(d)]).status == 0
    }

    static func cancelWake(_ d: Date) {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "schedule", "cancel", "wake", pmsetDate(d)])
    }

    static func sleepNow() {
        run("/usr/bin/pmset", ["sleepnow"])
    }

    /// Apaga as telas sem pôr o Mac para dormir (não precisa de root).
    static func displaySleepNow() {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    private static var onlineDisplays: [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Algum monitor externo ligado (tampa fechada com monitor = modo clamshell de verdade: não apagar).
    static var externalDisplayOnline: Bool {
        onlineDisplays.contains { CGDisplayIsBuiltin($0) == 0 }
    }

    /// A tela interna está ligada (acesa).
    static var builtinDisplayAwake: Bool {
        onlineDisplays.contains { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    /// true quando a tampa está fechada.
    static var lidClosed: Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let value = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    static var battery: (percent: Int, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            return (cap * 100 / max, state == kIOPSACPowerValue)
        }
        return nil
    }
}
