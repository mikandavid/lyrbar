import AppKit

// Entry point. The binary doubles as a tiny CLI for a few headless commands
// (used by the `lyrbar` shell script) and, when run with no command, launches
// the menu bar app.
let argv = Array(CommandLine.arguments.dropFirst())

func runCLI(_ args: [String]) -> Bool {
    guard let cmd = args.first else { return false }
    switch cmd {
    case "setup":
        guard args.count >= 2, !args[1].isEmpty else {
            FileHandle.standardError.write(Data("usage: lyrbar setup <spotify_client_id>\n".utf8))
            exit(2)
        }
        Settings.shared.clientId = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
        print("Saved Spotify client id. Now run `lyrbar on` and click the menu bar item to log in.")
        exit(0)
    case "logout":
        TokenStore.shared.clear()
        print("Logged out (cleared stored Spotify tokens).")
        exit(0)
    case "warmup":
        runWarmup()   // exits inside
    case "status-config":
        let hasClient = (Settings.shared.clientId?.isEmpty == false)
        let hasToken = TokenStore.shared.load() != nil
        print("clientId: \(hasClient ? "set" : "MISSING")")
        print("loggedIn: \(hasToken ? "yes" : "no")")
        print("redirectURI: \(Settings.shared.redirectURI)")
        exit(0)
    default:
        return false
    }
}

/// Headless library build, runnable from the terminal (`lyrbar warmup`).
func runWarmup() -> Never {
    guard Settings.shared.clientId?.isEmpty == false else {
        FileHandle.standardError.write(Data("No client id. Run `lyrbar setup <id>` first.\n".utf8)); exit(1)
    }
    guard TokenStore.shared.load() != nil else {
        FileHandle.standardError.write(Data("Not logged in. Run `lyrbar login` first.\n".utf8)); exit(1)
    }
    let client = SpotifyClient(auth: SpotifyAuth())
    let sem = DispatchSemaphore(value: 0)
    print("Building lyrics library… (this can take a while for large libraries)")
    Task {
        let r = await LibraryBuilder.shared.run(
            client: client, store: .shared, kind: Settings.shared.provider
        ) { p in
            if p.total > 0, p.done % 20 == 0 || p.done == p.total {
                print("  \(p.done)/\(p.total) lyrics fetched")
            } else if p.total == 0 {
                print(p.phase)
            }
        }
        print("Done. Added \(r.added) (scanned \(r.scanned)). Library now holds \(r.totalTracks) songs.")
        if !r.sources.isEmpty { print("Sources: \(r.sources)") }
        if let note = r.note { print("Note: \(note)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

if runCLI(argv) { /* exits inside */ }

// `lyrbar login` (or default) launches the GUI; `login` forces the auth flow.
let autoLogin = (argv.first == "login")

let app = NSApplication.shared
let delegate = AppDelegate(autoLogin: autoLogin)
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
