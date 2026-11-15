import AppKit
import Foundation
import Observation

/// Installs the bundled `notiflab` tool by symlinking Contents/Helpers/notiflab onto the PATH.
@MainActor
@Observable
final class CLIInstaller {
    static let shared = CLIInstaller()

    enum State: Equatable {
        case notInstalled
        case installed(path: String)
        /// A `notiflab` exists but points somewhere else (another copy of the app, or an older build).
        case other(path: String, target: String)
    }

    private(set) var state: State = .notInstalled
    private(set) var isWorking = false
    private(set) var message: String?
    private(set) var error: String?
    /// Set after a successful install from the banner, so it can show a confirmation.
    var justInstalled = false

    /// Directories checked for an existing install, in preference order.
    private static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
    private static let adminDir = "/usr/local/bin"

    var helperPath: String { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/notiflab").path }
    var helperExists: Bool { FileManager.default.isExecutableFile(atPath: helperPath) }
    var isInstalled: Bool { if case .installed = state { return true } else { return false } }

    var manualCommand: String {
        let path = ScreenshotMode.isActive ? "/Applications/Notification Lab.app/Contents/Helpers/notiflab" : helperPath
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(path)' /usr/local/bin/notiflab"
    }

    private init() { refresh() }

    func refresh() {
        let fm = FileManager.default
        let helper = URL(fileURLWithPath: helperPath).resolvingSymlinksInPath().path
        var found: State = .notInstalled
        for dir in Self.searchDirs {
            let link = dir + "/notiflab"
            guard fm.fileExists(atPath: link) || (try? fm.destinationOfSymbolicLink(atPath: link)) != nil else { continue }
            let target = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
            if target == helper { found = .installed(path: link); break }
            if case .notInstalled = found { found = .other(path: link, target: target) }
        }
        state = found
    }

    func install() async {
        error = nil; message = nil
        guard helperExists else {
            error = "This build doesn't contain the command-line tool. Rebuild with ./build.sh."
            return
        }
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            error = "macOS is running Notification Lab from a temporary location. Move it to /Applications, reopen it, then install."
            return
        }
        isWorking = true
        defer { isWorking = false }

        let fm = FileManager.default
        // Prefer a directory on PATH that we can write without a password (Homebrew's, usually).
        let writable = Self.searchDirs.prefix(2).first { fm.isWritableFile(atPath: $0) }
        if let dir = writable {
            let link = dir + "/notiflab"
            do {
                if (try? fm.destinationOfSymbolicLink(atPath: link)) != nil || fm.fileExists(atPath: link) {
                    try fm.removeItem(atPath: link)
                }
                try fm.createSymbolicLink(atPath: link, withDestinationPath: helperPath)
                finish(link)
                return
            } catch {
                // Fall through to the admin path.
            }
        }

        let shell = "mkdir -p \(Self.adminDir) && ln -sf '\(helperPath)' \(Self.adminDir)/notiflab"
        if await runAsAdmin(shell) {
            finish(Self.adminDir + "/notiflab")
        } else if error == nil {
            error = "Installation was cancelled."
        }
    }

    func uninstall() async {
        error = nil; message = nil
        guard case .installed(let path) = state else { return }
        isWorking = true
        defer { isWorking = false }
        if (try? FileManager.default.removeItem(atPath: path)) == nil {
            guard await runAsAdmin("rm -f '\(path)'") else { return }
        }
        refresh()
        message = "Removed \(path)."
        NotificationService.shared.log(.info, "Uninstalled command-line tool", path)
    }

    func revealHelper() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: helperPath)])
    }

    private func finish(_ link: String) {
        refresh()
        justInstalled = true
        message = "Installed at \(link)."
        NotificationService.shared.log(.info, "Installed command-line tool", link)
    }

    /// Runs a shell command with the standard macOS administrator prompt.
    private func runAsAdmin(_ shell: String) async -> Bool {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let result: (status: Int32, stderr: String) = await Task.detached {
            let p = Process()
            let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return (-1, "Couldn't run osascript") }
            p.waitUntilExit()
            let e = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            return (p.terminationStatus, e)
        }.value
        if result.status == 0 { return true }
        if !result.stderr.contains("-128") { // -128 = user cancelled
            error = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return false
    }
}
