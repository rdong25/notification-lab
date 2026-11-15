// notiflab — command-line client for Notification Lab.
//
// macOS only lets app bundles post notifications and routes clicks back to the app, so this tool
// talks to Notification Lab over distributed notifications (launching it hidden when needed).
// Data goes to stdout; progress and warnings go to stderr, so output is easy to script.

import AppKit
import Foundation

let cliVersion = "1.1.0"
let bundleID = "com.notificationlab.app"
let requestName = Notification.Name("com.notificationlab.cli.request")
let responseName = Notification.Name("com.notificationlab.cli.response")

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Output

struct Style {
    static let enabled = isatty(STDERR_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    static func wrap(_ s: String, _ code: String) -> String { enabled ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { wrap(s, "2") }
    static func bold(_ s: String) -> String { wrap(s, "1") }
    static func red(_ s: String) -> String { wrap(s, "31") }
    static func green(_ s: String) -> String { wrap(s, "32") }
    static func yellow(_ s: String) -> String { wrap(s, "33") }
    static func cyan(_ s: String) -> String { wrap(s, "36") }
}

func out(_ s: String) { print(s) }
func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

struct Failure: Error {
    let message: String
    var code: Int32 = 1
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    err(Style.red("error: ") + message)
    exit(code)
}

func printJSON(_ obj: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else { return }
    out(s)
}

func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s : s + String(repeating: " ", count: n - s.count) }

// MARK: - Arguments

struct Args {
    private(set) var tokens: [String]
    var json = false

    init(_ raw: [String]) {
        tokens = raw.filter { $0 != "--json" }
        json = raw.contains("--json")
    }

    var isEmpty: Bool { tokens.isEmpty }

    mutating func next() -> String? { tokens.isEmpty ? nil : tokens.removeFirst() }
    mutating func pushBack(_ t: String) { tokens.insert(t, at: 0) }

    /// Splits `--key=value` into two tokens.
    static func normalize(_ raw: [String]) -> [String] {
        raw.flatMap { t -> [String] in
            if t.hasPrefix("--"), let eq = t.firstIndex(of: "=") {
                return [String(t[..<eq]), String(t[t.index(after: eq)...])]
            }
            return [t]
        }
    }
}

func parseDuration(_ s: String) -> Double? {
    let lower = s.lowercased()
    let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
    for (u, mult) in units where lower.hasSuffix(u) {
        if let v = Double(lower.dropLast(u.count)) { return v * mult }
    }
    return Double(lower)
}

// MARK: - Transport

final class Client {
    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// The app bundle this CLI belongs to (when installed as a symlink into the bundle), else LaunchServices' pick.
    private var appURL: URL? {
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           exe.path.contains(".app/Contents/Helpers/") {
            return exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    func ensureRunning() {
        if app != nil, ping(timeout: 1.5) { return }
        guard let url = appURL else {
            fail("Notification Lab isn't installed. Download it from https://github.com/rdong25/notification-lab/releases", code: 2)
        }
        if app == nil {
            err(Style.dim("Starting Notification Lab in the background…"))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", url.path]   // background, hidden
            try? p.run()
            p.waitUntilExit()
        }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if ping(timeout: 0.8) { return }
        }
        fail("Notification Lab didn't respond. Open it once manually, then try again.", code: 2)
    }

    private func ping(timeout: TimeInterval) -> Bool {
        (try? request("ping", [:], timeout: timeout)) != nil
    }

    /// Sends a request and returns the final response. `onPartial` receives streamed (non-final) payloads.
    @discardableResult
    func request(_ command: String, _ options: [String: Any], timeout: TimeInterval? = 10,
                 onPartial: (([String: Any]) -> Void)? = nil) throws -> [String: Any] {
        let id = UUID().uuidString
        var final: [String: Any]?
        let token = DistributedNotificationCenter.default().addObserver(forName: responseName, object: nil, queue: nil) { n in
            guard n.userInfo?["id"] as? String == id,
                  let json = n.userInfo?["json"] as? String,
                  let payload = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return }
            if n.userInfo?["final"] as? String == "1" { final = payload } else { onPartial?(payload) }
        }
        defer { DistributedNotificationCenter.default().removeObserver(token) }

        let body: [String: Any] = ["command": command, "options": options]
        let data = try JSONSerialization.data(withJSONObject: body)
        DistributedNotificationCenter.default().postNotificationName(
            requestName, object: nil, userInfo: ["id": id, "json": String(decoding: data, as: UTF8.self)],
            deliverImmediately: true)

        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while final == nil {
            if let deadline, Date() > deadline { throw Failure(message: "timed out", code: 4) }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if let e = final?["error"] as? String { throw Failure(message: e) }
        return final!
    }

    func call(_ command: String, _ options: [String: Any] = [:], timeout: TimeInterval? = 15) -> [String: Any] {
        do { return try request(command, options, timeout: timeout) }
        catch let f as Failure { fail(f.message, code: f.code) }
        catch { fail(error.localizedDescription) }
    }
}

// MARK: - Send options

/// Parses notification options shared by `send` and `snippet`.
func parseSendOptions(_ args: inout Args) -> (options: [String: Any], timeout: Double?) {
    var o: [String: Any] = [:]
    var actions: [[String: Any]] = []
    var words: [String] = []
    var timeout: Double?

    func value(_ flag: String) -> String {
        guard let v = args.next() else { fail("\(flag) needs a value. See `notiflab help send`.") }
        return v
    }

    while let t = args.next() {
        switch t {
        case "-t", "--title": o["title"] = value(t)
        case "-s", "--subtitle": o["subtitle"] = value(t)
        case "-m", "--message", "--body":
            let v = value(t)
            o["message"] = v == "-" ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) : v
        case "-T", "--template": o["template"] = value(t)
        case "--sound": o["sound"] = value(t)
        case "--silent", "--no-sound": o["sound"] = "none"
        case "--level": o["level"] = value(t)
        case "--passive": o["level"] = "passive"
        case "-g", "--group", "--id": o["group"] = value(t)
        case "--thread": o["thread"] = value(t)
        case "-d", "--delay":
            let v = value(t)
            guard let d = parseDuration(v) else { fail("Invalid delay “\(v)”. Use 5, 5s, 1.5m or 1h.") }
            o["delay"] = d
        case "-n", "--repeat":
            guard let n = Int(value(t)), n > 0 else { fail("--repeat needs a positive number.") }
            o["repeat"] = n
        case "--badge":
            guard let n = Int(value(t)), n >= 0 else { fail("--badge needs a number ≥ 0.") }
            o["badge"] = n
        case "-o", "--open": o["open"] = value(t)
        case "--activate": o["activate"] = value(t)
        case "-x", "--exec": o["exec"] = value(t)
        case "-a", "--action":
            // "Title", "Title@symbol", append "!" for destructive: "Delete@trash!"
            var spec = value(t)
            var destructive = false
            if spec.hasSuffix("!") { destructive = true; spec.removeLast() }
            let parts = spec.split(separator: "@", maxSplits: 1).map(String.init)
            actions.append(["title": parts.first ?? spec, "symbol": parts.count > 1 ? parts[1] : "", "destructive": destructive])
        case "-r", "--reply":
            // Optional placeholder: `--reply` or `--reply "Type…"`
            if let peek = args.next() {
                if peek.hasPrefix("-") { o["reply"] = ""; args.pushBack(peek) }
                else { o["reply"] = peek }
            } else { o["reply"] = "" }
        case "--reply-button": o["replyButton"] = value(t)
        case "-i", "--image": o["image"] = (value(t) as NSString).expandingTildeInPath
        case "--report-dismiss": o["dismissReport"] = true
        case "--no-report-dismiss": o["dismissReport"] = false
        case "-w", "--wait": o["wait"] = true
        case "--timeout":
            let v = value(t)
            guard let d = parseDuration(v) else { fail("Invalid timeout “\(v)”.") }
            timeout = d
            o["wait"] = true
        case "-h", "--help": usage("send"); exit(0)
        default:
            if t.hasPrefix("-") && t.count > 1 { fail("Unknown option \(t). See `notiflab help send`.") }
            words.append(t)
        }
    }
    if !actions.isEmpty { o["actions"] = actions }
    if o["message"] == nil, !words.isEmpty { o["message"] = words.joined(separator: " ") }
    else if !words.isEmpty { fail("Unexpected argument “\(words[0])”. Quote multi-word values.") }
    return (o, timeout)
}

// MARK: - Commands

let client = Client()

func cmdSend(_ args: inout Args) {
    let (options, timeout) = parseSendOptions(&args)
    client.ensureRunning()
    let wait = options["wait"] as? Bool ?? false
    let json = args.json
    var result: [String: Any] = [:]
    var interaction: [String: Any]?

    do {
        result = try client.request("send", options, timeout: wait ? timeout : 15) { partial in
            result = partial
            if !json { reportSent(partial, waiting: true) }
        }
        if wait { interaction = result }
    } catch let f as Failure where f.code == 4 && wait {
        if args.json { printJSON(["ids": result["ids"] ?? [], "event": "timeout"]) } else { out("timeout") }
        exit(4)
    } catch let f as Failure {
        fail(f.message, code: f.code)
    } catch {
        fail(error.localizedDescription)
    }

    if args.json { printJSON(result); return }
    if let i = interaction {
        switch i["event"] as? String ?? "" {
        case "action": out("action:\(i["action"] as? String ?? "")")
        case "reply": out("reply:\(i["reply"] as? String ?? "")")
        default: out(i["event"] as? String ?? "")
        }
    } else {
        reportSent(result, waiting: false)
    }
}

func reportSent(_ p: [String: Any], waiting: Bool) {
    let ids = p["ids"] as? [String] ?? []
    let verb = (p["scheduled"] as? Bool ?? false) ? "Scheduled" : "Sent"
    for id in ids { err(Style.green("✓ ") + "\(verb) " + Style.dim(id)) }
    for w in p["warnings"] as? [String] ?? [] { err(Style.yellow("! ") + "Banner may be hidden: " + w + Style.dim("  (run `notiflab diagnose`)")) }
    if waiting { err(Style.dim("Waiting for a click, action or reply… (Ctrl-C to stop)")) }
    if !waiting && !ids.isEmpty && isatty(STDOUT_FILENO) == 0 { ids.forEach { out($0) } }
}

func cmdSnippet(_ args: inout Args) {
    let (options, _) = parseSendOptions(&args)
    client.ensureRunning()
    let r = client.call("snippet", options)
    if args.json { printJSON(r) } else { out(r["snippet"] as? String ?? "") }
}

func cmdTemplates(_ args: inout Args) {
    client.ensureRunning()
    if let name = args.next() {
        let r = client.call("template", ["name": name])
        printJSON(r["template"] ?? [:])
        return
    }
    let r = client.call("templates")
    let list = r["templates"] as? [[String: Any]] ?? []
    if args.json { printJSON(list); return }
    let w = max(8, list.map { ($0["name"] as? String ?? "").count }.max() ?? 0) + 2
    for t in list {
        let name = t["name"] as? String ?? ""
        let traits = t["traits"] as? String ?? ""
        out(pad(name, w) + Style.dim(pad(traits, 14)) + (t["title"] as? String ?? ""))
    }
    err(Style.dim("\nSend one with: notiflab send --template \"\(list.first?["name"] as? String ?? "Basic")\""))
}

func cmdDelivered(_ args: inout Args) {
    client.ensureRunning()
    let list = client.call("delivered")["delivered"] as? [[String: Any]] ?? []
    if args.json { printJSON(list); return }
    if list.isEmpty { err(Style.dim("Notification Center has no notifications from Notification Lab.")); return }
    for d in list {
        let time = String((d["date"] as? String ?? "").dropFirst(11).prefix(8))
        out("\(Style.dim(time))  \(pad(d["title"] as? String ?? "", 28))  \(Style.dim(d["id"] as? String ?? ""))")
    }
}

func cmdPending(_ args: inout Args) {
    client.ensureRunning()
    let list = client.call("pending")["pending"] as? [[String: Any]] ?? []
    if args.json { printJSON(list); return }
    if list.isEmpty { err(Style.dim("Nothing scheduled.")); return }
    for p in list {
        let rem = String(format: "%6.1fs", p["remaining"] as? Double ?? 0)
        out("\(Style.cyan(rem))  \(pad(p["title"] as? String ?? "", 28))  \(Style.dim(p["id"] as? String ?? ""))")
    }
}

func cmdRemoveOrCancel(_ args: inout Args, command: String) {
    var ids: [String] = []
    var all = false
    while let t = args.next() {
        if t == "--all" || t == "-a" { all = true } else { ids.append(t) }
    }
    if !all && ids.isEmpty { fail("Give notification IDs or --all. See `notiflab \(command == "remove" ? "list" : "pending")` for IDs.") }
    client.ensureRunning()
    _ = client.call(command, all ? ["all": true] : ["ids": ids])
    err(Style.green("✓ ") + (command == "remove" ? "Removed" : "Cancelled") + (all ? " all" : " \(ids.count)"))
}

func cmdBadge(_ args: inout Args) {
    guard let v = args.next() else { fail("Usage: notiflab badge <number|clear>") }
    let n = v == "clear" ? 0 : Int(v)
    guard let n, n >= 0 else { fail("Badge must be a number ≥ 0 or “clear”.") }
    client.ensureRunning()
    _ = client.call("badge", ["count": n])
    err(Style.green("✓ ") + (n == 0 ? "Cleared Dock badge" : "Dock badge set to \(n)"))
}

func symbol(_ status: String) -> String {
    switch status {
    case "problem": Style.red("✗")
    case "warning": Style.yellow("!")
    case "ok": Style.green("✓")
    case "can't check": Style.dim("?")
    default: Style.dim("i")
    }
}

func printCheck(_ c: [String: Any], detailed: Bool, width: Int = 30) {
    let ack = c["acknowledged"] as? Bool ?? false
    let title = c["title"] as? String ?? ""
    out("\(symbol(ack ? "note" : c["status"] as? String ?? ""))  \(Style.bold(pad(title, width)))\(c["summary"] as? String ?? "")\(ack ? Style.dim("  (ignored)") : "")")
    guard detailed else { return }
    if let why = c["why"] as? String, !why.isEmpty { out(Style.dim("     " + why)) }
    for e in c["evidence"] as? [String] ?? [] { out(Style.dim("     $ ") + e) }
    for (i, s) in (c["steps"] as? [String] ?? []).enumerated() { out("     \(i + 1). \(s)") }
    for a in c["actions"] as? [String] ?? [] { out(Style.cyan("     → ") + a) }
}

func cmdDiagnose(_ args: inout Args) {
    let verbose = args.tokens.contains("-v") || args.tokens.contains("--verbose")
    client.ensureRunning()
    let r = client.call("diagnose", [:], timeout: 30)
    if args.json { printJSON(r); return }
    let checks = r["checks"] as? [[String: Any]] ?? []
    let blockers = r["blockers"] as? [String] ?? []
    let width = (checks.map { ($0["title"] as? String ?? "").count }.max() ?? 26) + 2
    for c in checks {
        let status = c["status"] as? String ?? ""
        let important = (status == "problem" || status == "warning") && !(c["acknowledged"] as? Bool ?? false)
        printCheck(c, detailed: verbose || important, width: width)
    }
    out("")
    if blockers.isEmpty {
        out(Style.green("Nothing detected that would hide banners.") + Style.dim(" Still not seeing them? Run `notiflab test`."))
    } else {
        out(Style.yellow("\(blockers.count) thing\(blockers.count == 1 ? "" : "s") likely hiding banners.") + Style.dim(" Follow the steps above, then run `notiflab test`."))
        exit(3)
    }
}

func ask(_ prompt: String) -> String {
    FileHandle.standardError.write(Data(prompt.utf8))
    return (readLine() ?? "").trimmingCharacters(in: .whitespaces).lowercased()
}

func cmdTest(_ args: inout Args) {
    client.ensureRunning()
    let r = client.call("test")
    let display = r["display"] as? String ?? "your main display"
    err(Style.green("✓ ") + "Sent a test banner.")
    guard isatty(STDIN_FILENO) == 1 else { return }

    while true {
        let a = ask("Did a banner slide in at the top right of “\(display)”? [y/n/again] ")
        if a.hasPrefix("y") { out(Style.green("Banners are working.")); return }
        if a.hasPrefix("a") { _ = client.call("test"); continue }
        break
    }
    let steps = client.call("diagnose", [:], timeout: 30)["guide"] as? [[String: Any]] ?? []
    for (i, step) in steps.enumerated() {
        out("\n" + Style.dim("Step \(i + 1) of \(steps.count)"))
        printCheck(step, detailed: true)
        while true {
            let a = ask("\n[s] fixed it, send again   [n] next cause   [q] quit  ")
            if a.hasPrefix("q") { return }
            if a.hasPrefix("n") || a.isEmpty { break }
            if a.hasPrefix("s") {
                _ = client.call("test")
                if ask("Did it appear this time? [y/n] ").hasPrefix("y") { out(Style.green("Fixed. Banners are working.")); return }
            }
        }
    }
    out("\nOut of known causes. Try logging out and back in, or restarting the Mac.")
}

func eventLine(_ e: [String: Any]) -> String {
    let time = String((e["time"] as? String ?? "").dropFirst(11).prefix(12))
    let kind = e["kind"] as? String ?? ""
    let colored: String = switch kind {
    case "error": Style.red(pad(kind, 10))
    case "warning", "scheduled": Style.yellow(pad(kind, 10))
    case "clicked", "action", "reply": Style.green(pad(kind, 10))
    default: Style.dim(pad(kind, 10))
    }
    var line = "\(Style.dim(time))  \(colored) \(e["title"] as? String ?? "")"
    if let d = e["detail"] as? String, !d.isEmpty { line += Style.dim("  " + d.replacingOccurrences(of: "\n", with: " ⏎ ")) }
    return line
}

func cmdLog(_ args: inout Args) {
    var follow = false
    var limit = 30
    while let t = args.next() {
        switch t {
        case "-f", "--follow": follow = true
        case "-n", "--limit": limit = Int(args.next() ?? "") ?? limit
        default: fail("Unknown option \(t). Usage: notiflab log [-f] [-n N]")
        }
    }
    client.ensureRunning()
    let json = args.json
    func emit(_ p: [String: Any]) {
        for e in p["events"] as? [[String: Any]] ?? [] { json ? printJSON(e) : out(eventLine(e)) }
    }
    if !follow { emit(client.call("log", ["limit": limit])); return }

    // Follow until Ctrl-C.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { exit(0) }
    sigint.resume()
    if !json { err(Style.dim("Following Notification Lab activity… (Ctrl-C to stop)")) }
    _ = try? client.request("log", ["limit": limit, "follow": true], timeout: nil) { emit($0) }
}

func cmdStatus(_ args: inout Args) {
    client.ensureRunning()
    let r = client.call("status")
    if args.json { printJSON(r); return }
    let order = ["version", "app", "bundle", "authorization", "alertStyle", "alerts", "notificationCenter", "lockScreen",
                 "sound", "badge", "timeSensitive", "delivered", "pending"]
    for k in order {
        guard let v = r[k] else { continue }
        let isBool = (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        let text = isBool ? ((v as? Bool ?? false) ? "yes" : "no") : "\(v)"
        out(Style.dim(pad(k, 20)) + text)
    }
    let blockers = r["blockers"] as? [String] ?? []
    out(Style.dim(pad("cli", 20)) + cliVersion)
    out(Style.dim(pad("banner blockers", 20)) + (blockers.isEmpty ? Style.green("none") : Style.yellow(blockers.joined(separator: ", "))))
}

func cmdOpen(_ args: inout Args) {
    var o: [String: Any] = [:]
    while let t = args.next() {
        switch t {
        case "activity", "delivered", "scheduled", "diagnostics": o["view"] = t
        case "-T", "--template": o["template"] = args.next() ?? ""
        default: o["template"] = t
        }
    }
    client.ensureRunning()
    _ = client.call("open", o)
}

// MARK: - Help

func usage(_ topic: String? = nil) {
    switch topic {
    case "send", "snippet":
        out("""
        \(Style.bold("notiflab send")) [options] [message…]
        \(Style.bold("notiflab snippet")) [options]   print the UserNotifications Swift code instead of sending

        Content
          -t, --title TEXT          title
          -s, --subtitle TEXT       subtitle
          -m, --message TEXT        body (use - to read stdin); bare words also become the body
          -T, --template NAME       start from a saved template, then apply other options
          -i, --image PATH          attach an image

        Presentation
              --sound NAME          default, none, or a system sound (Glass, Ping, Submarine…)
              --silent              same as --sound none
              --level LEVEL         passive | active | time-sensitive | critical
              --passive             same as --level passive
              --badge N             set the Dock badge

        Delivery
          -g, --group ID            notification identifier; sending again replaces the previous one
              --thread ID           group related notifications into a stack
          -d, --delay DURATION      schedule: 5, 5s, 1.5m, 1h
          -n, --repeat N            send N times (a burst)

        On click
          -o, --open URL            open a URL
              --activate BUNDLE_ID  bring an app to the front
          -x, --exec COMMAND        run a shell command (zsh)

        Buttons (macOS shows up to 4)
          -a, --action TITLE        add an action; TITLE@symbol adds an SF Symbol, append ! for destructive
          -r, --reply [PLACEHOLDER] add an inline text reply
              --reply-button TITLE  reply button title
              --[no-]report-dismiss report when the notification is dismissed

        Waiting
          -w, --wait                wait for the person to respond, then print:
                                      clicked | action:<title> | reply:<text> | dismissed
              --timeout DURATION    stop waiting after DURATION (prints “timeout”, exit 4)

        Examples
          notiflab send -t "Build finished" -m "All tests passed" --sound Glass
          make test 2>&1 | tail -1 | notiflab send -t "make test" -m -
          notiflab send -t "Deploy to prod?" -a Deploy@paperplane -a "Cancel@xmark!" --wait
          notiflab send -t "Alex" -m "Lunch?" --reply "Type a reply…" --wait --timeout 2m
          notiflab send -T "Burst of 5" --title "Overridden title"
          notiflab send -t Upload -m "45%" -g upload --silent     # update in place
        """)
    default:
        out("""
        \(Style.bold("notiflab")) \(cliVersion): send and debug macOS notifications from the terminal via Notification Lab

        Usage: notiflab <command> [options]   (add --json to any command for machine-readable output)

        Sending
          send [options]           post a notification (see `notiflab help send`)
          snippet [options]        print the Swift code for a notification
          test                     send a test banner and walk through fixes if it doesn't appear

        Inspecting
          templates [NAME]         list saved templates, or print one as JSON
          list                     notifications currently in Notification Center
          pending                  scheduled notifications and their countdowns
          log [-f] [-n N]          activity log; -f follows live
          status                   permission and notification settings
          diagnose [-v]            find what's hiding banners (exit 3 if something is)

        Managing
          remove ID… | --all       remove delivered notifications
          cancel ID… | --all       cancel scheduled notifications
          badge N | clear          set or clear the Dock badge
          restart-nc               restart Notification Center (fixes a stuck banner queue)
          open [VIEW | TEMPLATE]   open the app (activity, delivered, scheduled, diagnostics, or a template)

          help [send]              this help
          version                  print versions

        Exit codes: 0 ok · 1 error · 2 app unavailable · 3 banner blockers found · 4 timed out
        """)
    }
}

// MARK: - Entry

var args = Args(Args.normalize(Array(CommandLine.arguments.dropFirst())))
let command = args.next() ?? "help"

switch command {
case "send": cmdSend(&args)
case "snippet": cmdSnippet(&args)
case "test": cmdTest(&args)
case "templates", "template": cmdTemplates(&args)
case "list", "ls", "delivered": cmdDelivered(&args)
case "pending", "scheduled": cmdPending(&args)
case "log", "logs": cmdLog(&args)
case "status": cmdStatus(&args)
case "diagnose", "doctor": cmdDiagnose(&args)
case "remove", "rm": cmdRemoveOrCancel(&args, command: "remove")
case "cancel": cmdRemoveOrCancel(&args, command: "cancel")
case "badge": cmdBadge(&args)
case "restart-nc":
    client.ensureRunning()
    _ = client.call("restart-nc")
    err(Style.green("✓ ") + "Restarted Notification Center")
case "open": cmdOpen(&args)
case "version", "--version", "-v":
    out("notiflab \(cliVersion)")
    if let v = try? client.request("ping", [:], timeout: 1.5)["version"] as? String { out("Notification Lab \(v)") }
case "help", "--help", "-h": usage(args.next())
default:
    err("Unknown command “\(command)”.\n")
    usage()
    exit(1)
}
exit(0)
