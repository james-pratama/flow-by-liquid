import AppKit

/// Hand-written actions for the apps Flow is used with most. Each is ranked above discovered actions
/// and can chain steps (search → play) that a single AppleScript command or menu item can't.
struct CuratedApp {
    let target: TargetApp
    let aliases: [String]
    let actions: [AppAction]
    var name: String { target.name }
}

enum CuratedApps {
    static let apps: [CuratedApp] = [spotify, notion, claude, mail, chrome, notes]
    static let all: [AppAction] = apps.flatMap(\.actions) + media

    private static func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    // MARK: Spotify

    static let spotify: CuratedApp = {
        let app = TargetApp(name: "Spotify", bundleId: "com.spotify.client")
        return CuratedApp(target: app, aliases: ["spotify"], actions: [
            app.action("play_search", "Play a song, album, artist, playlist or genre by name",
                       hint: "play <song> by <artist>, start playing <song>, put on <playlist>, listen to <album>, play some jazz",
                       args: [("query", "the song, artist, album, playlist or genre"), ("kind", "song, album, artist, playlist or \"\"")]) { a, ctx in
                try await SpotifyPlayer.play(a.string("query"), kind: a.string("kind"), said: ctx.transcript)
            },
            app.action("play_library", "Play one of your own playlists or your Liked Songs",
                       hint: "play my <name> playlist, play my liked songs, play Discover Weekly, put on my Work playlist",
                       args: [("name", "the playlist's name")]) { a, ctx in
                try await SpotifyPlayer.play(a.string("name"), kind: "playlist", said: "my " + ctx.transcript)
            },
            app.action("resume", "Resume the paused music", hint: "resume, unpause, continue, keep playing, play again") { _, _ in
                try await Script.tell(app, "play"); return AppResult(message: "Playing")
            },
            app.action("pause", "Pause the music", hint: "pause, stop the music, stop playing") { _, _ in
                try await Script.tell(app, "pause"); return AppResult(message: "Paused")
            },
            app.action("next", "Skip to the next song", hint: "skip, next track, next song, skip this") { _, _ in
                try await Script.tell(app, "next track"); return AppResult(message: "Skipped")
            },
            app.action("previous", "Go back to the previous song", hint: "previous track, last song, go back, play that again") { _, _ in
                try await Script.tell(app, "previous track"); return AppResult(message: "Previous song")
            },
            app.action("volume", "Change Spotify's volume", hint: "turn it up, turn it down, louder, quieter, volume to 50, mute",
                       args: [("level", "a number from 0 to 100, or up, down or mute")]) { a, _ in
                let current = Int(try await Script.tell(app, "get sound volume")) ?? 50
                let level = Self.volume(a.string("level"), current: current)
                try await Script.tell(app, "set sound volume to (item 1 of argv) as integer", [String(level)])
                return AppResult(message: "Spotify volume \(level)%")
            },
            app.action("shuffle", "Turn shuffle on or off", hint: "shuffle, stop shuffling, random order",
                       args: [("state", "on, off or \"\" to toggle")]) { a, _ in
                let on = try await Script.tell(app, "set shuffling to \(Self.toggle(a.string("state"), "shuffling"))\nreturn shuffling")
                return AppResult(message: on == "true" ? "Shuffle on" : "Shuffle off")
            },
            app.action("repeat", "Turn repeat on or off", hint: "repeat, loop this, stop repeating",
                       args: [("state", "on, off or \"\" to toggle")]) { a, _ in
                let on = try await Script.tell(app, "set repeating to \(Self.toggle(a.string("state"), "repeating"))\nreturn repeating")
                return AppResult(message: on == "true" ? "Repeat on" : "Repeat off")
            },
            app.action("now_playing", "Say which song is playing", hint: "what's playing, what song is this, who sings this") { _, _ in
                let out = try await Script.tell(app, """
                    if player state is stopped then return ""
                    return (name of current track) & " — " & (artist of current track)
                    """)
                return out.isEmpty ? AppResult(message: "Nothing is playing", style: .info)
                    : AppResult(message: out, detail: "Playing on Spotify", style: .answer)
            },
        ])
    }()

    static func volume(_ spoken: String, current: Int) -> Int {
        let s = spoken.lowercased()
        if let n = Int(s.filter(\.isNumber)) { return max(0, min(100, n)) }
        if s.contains("mute") { return 0 }
        if s.contains("max") || s.contains("full") { return 100 }
        if s.matches(#"\b(down|lower|quieter|softer|decrease)\b"#) { return max(0, current - 15) }
        return min(100, current + 15)
    }

    /// AppleScript for "on", "off" or (anything else) flipping the current value.
    static func toggle(_ state: String, _ property: String) -> String {
        let s = state.lowercased()
        if s.matches(#"\b(on|true|yes|enable)\b"#) { return "true" }
        if s.matches(#"\b(off|false|no|disable|stop)\b"#) { return "false" }
        return "not \(property)"
    }

    // MARK: Notion (not scriptable: driven with its keyboard shortcuts)

    static let notion: CuratedApp = {
        let app = TargetApp(name: "Notion", bundleId: "notion.id")
        func keys(_ key: String, _ title: String, hint: String, done: String) -> AppAction {
            app.action(key.replacingOccurrences(of: " ", with: "_"), title, hint: hint) { _, _ in
                try await app.activate()
                await Keys.press(Self.notionKeys[key]!)
                return AppResult(message: done)
            }
        }
        return CuratedApp(target: app, aliases: ["notion"], actions: [
            app.action("open_page", "Open a Notion page by name", hint: "open my <page> page, go to <page>, pull up <doc> in Notion",
                       args: [("page", "the page's name")]) { a, _ in
                let page = a.string("page")
                guard !page.isEmpty else { throw ToolError("Which page?") }
                try await app.activate()
                await Keys.press("cmd+p")
                await pause(0.5)
                await Keys.type(page)
                await pause(1.3)
                await Keys.press("return")
                return AppResult(message: "Opened “\(page)” in Notion")
            },
            app.action("search", "Search Notion", hint: "search Notion for, find pages about",
                       args: [("query", "what to search for")]) { a, _ in
                try await app.activate()
                await Keys.press("cmd+p")
                await pause(0.5)
                await Keys.type(a.string("query"))
                return AppResult(message: "Searching Notion for “\(a.string("query"))”")
            },
            app.action("new_page", "Create a new Notion page", hint: "new page, make a page called, start a doc",
                       args: [("title", "the page title, or \"\""), ("content", "text to put on the page, or \"\"")]) { a, _ in
                try await app.activate()
                await Keys.press("cmd+n")
                await pause(1.0)
                let title = a.string("title"), content = a.string("content")
                if !title.isEmpty { await Keys.type(title) }
                if !content.isEmpty {
                    await Keys.press("return")
                    await pause(0.3)
                    await Keys.type(content)
                }
                return AppResult(message: title.isEmpty ? "New Notion page" : "Created “\(title)” in Notion")
            },
            keys("back", "Go back to the previous page", hint: "go back, back, previous page", done: "Back"),
            keys("forward", "Go forward a page", hint: "go forward, next page", done: "Forward"),
            keys("sidebar", "Show or hide the sidebar", hint: "toggle sidebar, hide sidebar, show sidebar", done: "Toggled the sidebar"),
            keys("copy link", "Copy the link to this page", hint: "copy link, share link, get the URL", done: "Copied the page link"),
            keys("new tab", "Open a new tab", hint: "new tab", done: "New Notion tab"),
            keys("dark mode", "Switch between light and dark mode", hint: "dark mode, light mode, change the theme", done: "Switched theme"),
        ])
    }()

    private static let notionKeys = ["back": "cmd+[", "forward": "cmd+]", "sidebar": "cmd+\\", "copy link": "cmd+l",
                                     "new tab": "cmd+t", "dark mode": "cmd+shift+l"]

    // MARK: Claude

    static let claude: CuratedApp = {
        let app = TargetApp(name: "Claude", bundleId: "com.anthropic.claudefordesktop")
        func newChat() async throws {
            let running = try await app.activate()
            if let path = Menus.firstPath(in: running, titled: ["New Chat", "New Conversation", "New chat", "New conversation"]) {
                try Menus.press(path, in: running)
            } else {
                await Keys.press("cmd+n")
            }
            await pause(0.9)
        }
        return CuratedApp(target: app, aliases: ["claude", "claude app", "claude desktop"], actions: [
            app.action("ask", "Start a new chat with Claude and send it a message",
                       hint: "ask Claude, tell Claude, have Claude write/explain/summarize, ask Claude about this",
                       args: [("message", "what to send Claude, in the user's words")]) { a, ctx in
                var message = a.string("message").isEmpty ? ctx.transcript : a.string("message")
                // "Ask Claude to explain this" with text selected: send the selection too.
                if ctx.transcript.matches(#"\b(this|selected|selection|highlighted)\b"#),
                   let sel = ctx.focus?.selectedText, !sel.isEmpty {
                    message += "\n\n\(sel.prefix(6000))"
                }
                try await newChat()
                await Keys.type(message)
                await pause(0.3)
                await Keys.press("return")
                return AppResult(message: "Asked Claude", detail: String(message.prefix(140)))
            },
            app.action("new_chat", "Open a new chat in Claude", hint: "new chat, new conversation, start fresh") { _, _ in
                try await newChat()
                return AppResult(message: "New Claude chat")
            },
        ])
    }()

    // MARK: Mail

    static let mail: CuratedApp = {
        let app = TargetApp(name: "Mail", bundleId: "com.apple.mail")
        return CuratedApp(target: app, aliases: ["mail", "apple mail", "email", "inbox", "my email", "my inbox"], actions: [
            app.action("check", "Download new email from the server", hint: "check my mail, refresh the inbox, fetch mail") { _, _ in
                try await Script.tell(app, "check for new mail")
                return AppResult(message: "Checking for new mail")
            },
            app.action("unread", "Say how many unread emails there are and who they're from",
                       hint: "do I have any unread or new emails, how many emails, what's in my inbox, who emailed me") { _, _ in
                let out = try await Script.tell(app, """
                    set msgs to (messages of inbox whose read status is false)
                    set out to (count of msgs) as text
                    repeat with i from 1 to (count of msgs)
                        if i > 4 then exit repeat
                        set m to item i of msgs
                        set out to out & linefeed & (extract name from sender of m) & ": " & (subject of m)
                    end repeat
                    return out
                    """)
                let lines = out.split(separator: "\n").map(String.init)
                let n = Int(lines.first ?? "0") ?? 0
                return AppResult(message: n == 0 ? "No unread email" : "\(n) unread email\(n == 1 ? "" : "s")",
                                 detail: lines.dropFirst().joined(separator: "\n"), style: .answer)
            },
            app.action("reply", "Write a reply to the email selected in Mail (never sent)",
                       hint: "reply to this email saying, respond to this, answer this email",
                       args: [("instructions", "what the reply should say")]) { a, ctx in
                let original = try await Script.tell(app, """
                    set sel to selection
                    if sel is {} then error "Select an email in Mail first"
                    set m to item 1 of sel
                    set c to content of m
                    if (length of c) > 1500 then set c to text 1 thru 1500 of c
                    return (extract name from sender of m) & linefeed & (subject of m) & linefeed & c
                    """)
                let parts = original.split(separator: "\n", maxSplits: 2).map(String.init)
                let sender = parts.first ?? "", subject = parts.count > 1 ? parts[1] : ""
                let instructions = a.string("instructions").isEmpty ? ctx.transcript : a.string("instructions")
                let body = try await ReplyWriter.write(to: sender, subject: subject, original: parts.count > 2 ? parts[2] : "",
                                                       instructions: instructions)
                try await Script.tell(app, "activate\nreply (item 1 of (get selection)) with opening window")
                await pause(0.9)
                await Keys.type(body)
                return AppResult(message: "Reply drafted in Mail", detail: "Not sent. " + String(body.prefix(140)))
            },
            app.action("search", "Search your email", hint: "find emails from, search mail for",
                       args: [("query", "what to search for")]) { a, _ in
                try await app.activate()
                await Keys.press("cmd+opt+f")
                await pause(0.3)
                await Keys.type(a.string("query"))
                await Keys.press("return")
                return AppResult(message: "Searching Mail for “\(a.string("query"))”")
            },
        ])
    }()

    // MARK: Google Chrome

    static let chrome: CuratedApp = {
        let app = TargetApp(name: "Google Chrome", bundleId: "com.google.Chrome")
        let openTab = """
            activate
            if (count of windows) = 0 then
                make new window
                set URL of active tab of front window to (item 1 of argv)
            else
                tell front window to make new tab with properties {URL:(item 1 of argv)}
            end if
            """
        func simple(_ key: String, _ title: String, hint: String, _ script: String, done: String) -> AppAction {
            app.action(key, title, hint: hint) { _, _ in
                try await Script.tell(app, "if (count of windows) = 0 then error \"No Chrome window is open\"\n" + script)
                return AppResult(message: done)
            }
        }
        return CuratedApp(target: app, aliases: ["chrome", "google chrome", "browser", "my browser", "the browser"], actions: [
            app.action("open", "Open a website in a new tab", hint: "go to <site>, open <url> in Chrome, pull up youtube",
                       args: [("site", "the website or address")]) { a, _ in
                let url = Self.websiteURL(a.string("site"))
                try await Script.tell(app, openTab, [url.absoluteString])
                return AppResult(message: "Opened \(url.host ?? url.absoluteString)")
            },
            app.action("search", "Search Google", hint: "google <something>, search the web for, look up in Chrome",
                       args: [("query", "what to search for")]) { a, _ in
                var c = URLComponents(string: "https://www.google.com/search")!
                c.queryItems = [URLQueryItem(name: "q", value: a.string("query"))]
                try await Script.tell(app, openTab, [c.url!.absoluteString])
                return AppResult(message: "Searched “\(a.string("query"))”")
            },
            app.action("switch_tab", "Switch to an open tab", hint: "go to my <site> tab, switch to the tab with, find the tab",
                       args: [("which", "words from the tab's title or site")]) { a, _ in
                let listing = try await Script.tell(app, """
                    set out to ""
                    repeat with w from 1 to (count of windows)
                        repeat with t from 1 to (count of tabs of window w)
                            set tb to tab t of window w
                            set out to out & w & (character id 9) & t & (character id 9) & (title of tb) & " " & (URL of tb) & linefeed
                        end repeat
                    end repeat
                    return out
                    """)
                let want = AppCatalog.words(a.string("which"))
                let best = listing.split(separator: "\n").map { $0.split(separator: "\t", maxSplits: 2).map(String.init) }
                    .filter { $0.count == 3 }
                    .max { AppCatalog.words($0[2]).intersection(want).count < AppCatalog.words($1[2]).intersection(want).count }
                guard let best, !AppCatalog.words(best[2]).intersection(want).isEmpty else {
                    throw ToolError("No open tab matches “\(a.string("which"))”")
                }
                try await Script.tell(app, """
                    set w to (item 1 of argv) as integer
                    set active tab index of window w to (item 2 of argv) as integer
                    set index of window w to 1
                    activate
                    """, [best[0], best[1]])
                return AppResult(message: "Switched tabs", detail: String(best[2].prefix(100)))
            },
            app.action("new_tab", "Open a new tab", hint: "new tab, blank tab") { _, _ in
                try await Script.tell(app, "activate\nif (count of windows) = 0 then\nmake new window\nelse\ntell front window to make new tab\nend if")
                return AppResult(message: "New tab")
            },
            simple("close_tab", "Close this tab", hint: "close tab, close this page", "close active tab of front window", done: "Closed the tab"),
            simple("reload", "Reload this page", hint: "reload, refresh the page", "reload active tab of front window", done: "Reloaded"),
            simple("back", "Go back a page", hint: "go back, previous page, back", "go back active tab of front window", done: "Back"),
            simple("forward", "Go forward a page", hint: "go forward, next page", "go forward active tab of front window", done: "Forward"),
            app.action("incognito", "Open an incognito window", hint: "incognito, private window, private browsing") { _, _ in
                try await Script.tell(app, "make new window with properties {mode:\"incognito\"}\nactivate")
                return AppResult(message: "Incognito window")
            },
            app.action("copy_link", "Copy this page's link", hint: "copy the URL, copy link, share this page") { _, _ in
                let url = try await Script.tell(app, "if (count of windows) = 0 then error \"No Chrome window is open\"\nreturn URL of active tab of front window")
                if !DryRun.active {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                }
                return AppResult(message: "Copied the link", detail: url)
            },
        ])
    }()

    /// "nytimes" → https://nytimes.com, "github.com/foo" → https://github.com/foo
    static func websiteURL(_ spoken: String) -> URL {
        let s = spoken.trimmingCharacters(in: .whitespaces)
        if let u = URL(string: s), u.scheme != nil, u.host != nil { return u }
        let host = s.lowercased().replacingOccurrences(of: " ", with: "")
        return URL(string: host.contains(".") ? "https://\(host)" : "https://\(host).com")
            ?? URL(string: "https://www.google.com/search?q=\(s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!
    }

    // MARK: Notes

    static let notes: CuratedApp = {
        let app = TargetApp(name: "Notes", bundleId: "com.apple.Notes")
        let findNote = """
            set found to (notes whose name contains (item 1 of argv))
            if found is {} then error "No note matching “" & (item 1 of argv) & "”"
            set n to item 1 of found
            """
        return CuratedApp(target: app, aliases: ["notes", "apple notes", "my notes"], actions: [
            app.action("create", "Create a new note", hint: "new note, make a note called, write down in Notes, start a list",
                       args: [("title", "the note's title"), ("body", "the note's text, or \"\"")]) { a, _ in
                let title = a.string("title").isEmpty ? "New note" : a.string("title")
                try await Script.tell(app, "make new note at default folder of default account with properties {body:(item 1 of argv)}",
                                      [Self.noteHTML(title: title, body: a.string("body"))])
                return AppResult(message: "Created “\(title)” in Notes", detail: a.string("body"))
            },
            app.action("append", "Add text to an existing note", hint: "add <item> to my <list> note, append to the note",
                       args: [("note", "words from the note's title"), ("text", "what to add")]) { a, _ in
                let lines = Self.htmlLines(a.string("text"))
                try await Script.tell(app, findNote + "\nset body of n to (body of n) & (item 2 of argv)", [a.string("note"), lines])
                return AppResult(message: "Added to “\(a.string("note"))”", detail: a.string("text"))
            },
            app.action("open", "Open a note", hint: "show my <name> note, open the note about",
                       args: [("note", "words from the note's title")]) { a, _ in
                try await Script.tell(app, findNote + "\nshow n\nactivate", [a.string("note")])
                return AppResult(message: "Opened “\(a.string("note"))”")
            },
        ])
    }()

    static func noteHTML(title: String, body: String) -> String {
        "<div><h1>\(escape(title))</h1></div>" + htmlLines(body)
    }

    static func htmlLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "<div>\(escape(String($0)))</div>" }.joined()
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Whatever is playing

    static let media: [AppAction] = [
        AppAction(id: "media.play_pause", app: "Now Playing", bundleId: nil, title: "Play or pause whatever is playing",
                  hint: "pause, resume, play, stop the music, pause the video", source: .curated) { _, _ in
            MediaKeys.press(MediaKeys.playPause); return AppResult(message: "Play/pause")
        },
        AppAction(id: "media.next", app: "Now Playing", bundleId: nil, title: "Skip to the next track",
                  hint: "skip, next, next song", source: .curated) { _, _ in
            MediaKeys.press(MediaKeys.next); return AppResult(message: "Next")
        },
        AppAction(id: "media.previous", app: "Now Playing", bundleId: nil, title: "Go back to the previous track",
                  hint: "previous, go back, last song", source: .curated) { _, _ in
            MediaKeys.press(MediaKeys.previous); return AppResult(message: "Previous")
        },
    ]
}

extension TargetApp {
    func action(_ key: String, _ title: String, hint: String = "", args: [(name: String, about: String)] = [],
                risk: ToolRisk = .reversible, _ perform: @escaping (Args, ToolContext) async throws -> AppResult) -> AppAction {
        AppAction(id: "\(name.lowercased().replacingOccurrences(of: " ", with: "_")).\(key)", app: name, bundleId: bundleId,
                  title: title, hint: hint, args: args, risk: risk, source: .curated, perform: perform)
    }
}

/// Writes the body of an email reply from the original message and what the user wants to say.
enum ReplyWriter {
    static func write(to sender: String, subject: String, original: String, instructions: String) async throws -> String {
        let system = Prompts.system(.email) + """

        Now write the body of a reply to the email below, ready to paste above the quoted original.
        Output only the reply text: a greeting, what \(Prompts.name) asked to say, and a sign-off. No subject line.
        Say only what they asked for; don't add details they didn't give.
        """
        let user = "Email from \(sender), subject “\(subject)”:\n\(original)\n\n\(Prompts.name) wants to reply: \(instructions)"
        guard let (out, _) = try? await LLMClient.router.complete(prompt: ChatML.prompt(system: system, user: user),
                                                                   schema: .props([("text", .str)]), maxTokens: 400, temperature: 0.2),
              let text = (JSON.parse(out)?["text"] as? String).map(GeneratedText.clean), !text.isEmpty else {
            throw ToolError("Couldn't write the reply")
        }
        return text
    }
}

/// Finds something to play from a spoken description and starts it in Spotify.
enum SpotifyPlayer {
    static let app = TargetApp(name: "Spotify", bundleId: "com.spotify.client")

    struct Found { let uri: String; let label: String }

    static func play(_ query: String, kind: String, said: String) async throws -> AppResult {
        guard !query.isEmpty else {
            try await Script.tell(app, "play")
            return AppResult(message: "Playing")
        }
        // One of the user's own playlists ("play my Work playlist", "play Discover Weekly").
        if !DryRun.active, said.matches(#"\bmy\b"#) || kind.lowercased().contains("playlist") || isLibraryName(query) {
            try await app.activate()
            if let name = await SpotifyUI.playFromLibrary(query) { return AppResult(message: "Playing \(name)") }
        }
        if let found = await find(query, kind: kind, said: said) {
            try await Script.tell(app, "play track (item 1 of argv)", [found.uri])
            return AppResult(message: "Playing \(found.label)")
        }
        // No API key: open Spotify's own search and press play on the top result.
        // "Only Time by Enya" searches "Only Time Enya" (Spotify's search doesn't understand "by").
        let parts = query.components(separatedBy: " by ")
        let artist = parts.count > 1 ? parts.last! : ""
        let terms = parts.joined(separator: " ")
        let q = terms.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? terms
        if DryRun.active { return AppResult(message: "[dry run] would search Spotify for “\(query)” and press play") }
        guard let url = URL(string: "spotify:search:\(q)") else { throw ToolError("Couldn't search for “\(query)”") }
        try await app.activate()
        NSWorkspace.shared.open(url)
        if let label = await SpotifyUI.pressTopPlay(matching: parts[0], artist: artist, searched: terms) {
            return AppResult(message: label.replacingOccurrences(of: #"^Play\b"#, with: "Playing", options: .regularExpression))
        }
        return AppResult(message: "Showing Spotify results for “\(query)”",
                         detail: "Couldn't press play on the results. Add a Spotify client ID in Settings → Spotify so Flow can start songs directly.",
                         style: .info)
    }

    /// Names that are always the user's own library, never a catalogue search.
    static func isLibraryName(_ q: String) -> Bool {
        q.matches(#"\b(liked songs|discover weekly|release radar|daily mix|on repeat|repeat rewind|your episodes)\b"#)
    }

    /// Spotify's Web API when a client ID is set, otherwise a web search for an open.spotify.com link.
    static func find(_ query: String, kind: String, said: String) async -> Found? {
        let want = preferredKind(kind: kind, said: said)
        if let found = try? await SpotifyAPI.search(query, prefer: want) { return found }
        // DuckDuckGo blocks automated searches too often to wait on; only Brave is reliable enough here.
        guard !Settings.shared.braveAPIKey.isEmpty else { return nil }
        let hint = want == "track" ? "song" : want
        guard let results = try? await WebSearch.search("site:open.spotify.com \(query) \(hint)", limit: 6) else { return nil }
        for r in results {
            let parts = r.url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
            guard r.url.host?.hasSuffix("open.spotify.com") == true, parts.count >= 2,
                  ["track", "album", "artist", "playlist"].contains(parts[0]),
                  parts[1].range(of: #"^[A-Za-z0-9]{10,}$"#, options: .regularExpression) != nil else { continue }
            let label = r.title.replacingOccurrences(of: #"\s*[|-]\s*Spotify.*$"#, with: "", options: .regularExpression)
            return Found(uri: "spotify:\(parts[0]):\(parts[1])", label: label.isEmpty ? query : label)
        }
        return nil
    }

    /// "play some jazz" → a playlist; "play Daft Punk" → decided by the search; "the album…" → album.
    static func preferredKind(kind: String, said: String) -> String {
        let k = (kind + " " + said).lowercased()
        if k.contains("playlist") || k.matches(#"\b(some|music for|songs for|vibes|mix)\b"#) { return "playlist" }
        if k.contains("album") || k.contains("record") { return "album" }
        if kind.lowercased().contains("artist") { return "artist" }
        return kind.lowercased().contains("song") || kind.lowercased().contains("track") ? "track" : ""
    }
}

/// Spotify Web API search with the client-credentials flow (no user login; only needs a free developer app).
enum SpotifyAPI {
    private static var token: (value: String, expires: Date)?

    static func search(_ query: String, prefer: String) async throws -> SpotifyPlayer.Found? {
        let id = Settings.shared.spotifyClientId, secret = Settings.shared.spotifyClientSecret
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        let bearer = try await accessToken(id: id, secret: secret)
        let cleaned = query.replacingOccurrences(of: #"(?i)\b(by|the song|the album|the playlist|playlist|album|song)\b"#,
                                                 with: " ", options: .regularExpression)
        var c = URLComponents(string: "https://api.spotify.com/v1/search")!
        c.queryItems = [URLQueryItem(name: "q", value: cleaned), URLQueryItem(name: "type", value: "track,artist,album,playlist"),
                        URLQueryItem(name: "limit", value: "3")]
        var req = URLRequest(url: c.url!)
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func items(_ type: String) -> [[String: Any]] { ((obj[type + "s"] as? [String: Any])?["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        func found(_ item: [String: Any]?) -> SpotifyPlayer.Found? {
            guard let item, let uri = item["uri"] as? String, let name = item["name"] as? String else { return nil }
            let by = ((item["artists"] as? [[String: Any]])?.first?["name"] as? String).map { " by \($0)" } ?? ""
            return SpotifyPlayer.Found(uri: uri, label: name + by)
        }
        // A query that is exactly an artist's name plays the artist.
        let artist = items("artist").first
        if prefer.isEmpty || prefer == "artist",
           let name = artist?["name"] as? String, name.caseInsensitiveCompare(cleaned.trimmingCharacters(in: .whitespaces)) == .orderedSame {
            return found(artist)
        }
        let order = prefer.isEmpty ? ["track", "album", "playlist"] : [prefer, "track", "playlist", "album"]
        for type in order { if let f = found(items(type).first) { return f } }
        return found(artist)
    }

    private static func accessToken(id: String, secret: String) async throws -> String {
        if let t = token, t.expires > Date() { return t.value }
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("Basic " + Data("\(id):\(secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("grant_type=client_credentials".utf8)
        req.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let value = obj["access_token"] as? String else {
            throw ToolError("Spotify rejected the client ID and secret")
        }
        token = (value, Date().addingTimeInterval(Double(obj["expires_in"] as? Int ?? 3600) - 60))
        return value
    }
}

/// Spotify's desktop app is a web page inside Chromium. Asked to, it exposes that page to the Accessibility API,
/// where every play button is labelled "Play <name>" (search results, and each playlist in the library sidebar).
enum SpotifyUI {
    typealias Found = (label: String, element: AXUIElement)

    /// Runs `body` against Spotify's page tree, switching Chromium's accessibility on for the duration.
    static func withPage<T>(_ body: (AXUIElement) async -> T?) async -> T? {
        guard AXIsProcessTrusted(), let app = SpotifyPlayer.app.running else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Either flag makes Chromium build its tree; Spotify only responds to the second.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        defer { AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        return await body(root)
    }

    /// What the last `pressTopPlay` saw: every result button, in order, when it pressed (for debugging).
    static var lastResults: [String] = []

    /// Waits for search results and presses play on the best result. Returns the button's label.
    static func pressTopPlay(matching query: String, artist: String = "", searched: String, timeout: TimeInterval = 8) async -> String? {
        await withPage { root in
            let words = AppCatalog.words(query)
            let start = Date()
            var previous: [String] = []
            while Date().timeIntervalSince(start) < timeout {
                try? await Task.sleep(nanoseconds: 500_000_000)
                // The page's main area (not the library sidebar), once it shows search results.
                guard let main = first(in: root, { AX.string($0, kAXSubroleAttribute) == "AXLandmarkMain" }),
                      AX.string(main, kAXDescriptionAttribute)?.contains("Search") == true else { continue }
                // Until the search box shows this query, the page may still hold the previous search's results.
                if let box = first(in: root, { AX.string($0, kAXRoleAttribute) == "AXComboBox" && AX.string($0, kAXDescriptionAttribute) == "What do you want to play?" }),
                   AppCatalog.words((AX.string(box, kAXValueAttribute) ?? "").replacingOccurrences(of: "+", with: " ")) != AppCatalog.words(searched) {
                    continue
                }
                let results = playButtons(in: main)
                // Chromium fills the tree in over a second or so; press only once two looks agree.
                let labels = results.map(\.label)
                defer { previous = labels }
                guard !labels.isEmpty, labels == previous else { continue }
                // The top result comes first. Until the new results have surely loaded, only accept one that matches the query.
                let titled = results.filter { !AppCatalog.words($0.label).intersection(words).isEmpty }
                // An artist was named: only results whose surrounding text (their row or card) mentions them.
                let artistWords = AppCatalog.words(artist)
                let byArtist = artistWords.isEmpty ? titled : titled.filter { b in
                    !AppCatalog.words(nearbyText(b.element).joined(separator: " ")).intersection(artistWords).isEmpty
                }
                // The exact title beats remixes and versions ("Only Time" over "Only Time - Remix").
                let exact: (Found) -> Bool = { $0.label.caseInsensitiveCompare("Play " + query.trimmingCharacters(in: .whitespaces)) == .orderedSame }
                let matching = byArtist.first(where: exact) ?? byArtist.first ?? titled.first(where: exact) ?? titled.first
                guard let best = matching ?? (Date().timeIntervalSince(start) > 3 ? results.first : nil) else { continue }
                lastResults = results.map { ($0.element == best.element ? "→ " : "  ") + $0.label }
                if AXUIElementPerformAction(best.element, kAXPressAction as CFString) == .success { return best.label }
            }
            return nil
        }
    }

    /// "Work", "my liked songs" → presses play on that playlist in the library sidebar. Returns its name.
    static func playFromLibrary(_ name: String) async -> String? {
        await withPage { root in
            let want = normalize(name)
            guard !want.isEmpty else { return nil }
            // Chromium builds the tree a moment after accessibility is switched on.
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let library = first(in: root, { AX.string($0, kAXDescriptionAttribute) == "Your Library" }) else { continue }
                let rows = libraryRows(in: library)
                let row = rows.first { normalize($0.label) == want }
                    ?? rows.first { normalize($0.label).contains(want) || (want.contains(normalize($0.label)) && normalize($0.label).count > 3) }
                if let row, let button = playButtons(in: row.element).first(where: { $0.label == "Play " + row.label }) ?? playButtons(in: row.element).first,
                   AXUIElementPerformAction(button.element, kAXPressAction as CFString) == .success {
                    return row.label
                }
            }
            return nil
        }
    }

    /// Text around a result's play button: its row or card, found by walking up until there's some text.
    static func nearbyText(_ el: AXUIElement) -> [String] {
        var node = AX.element(el, kAXParentAttribute), hops = 0
        while let n = node, hops < 5 {
            var texts: [String] = [], queue = [n], seen = 0
            while !queue.isEmpty && seen < 120 {
                let c = queue.removeFirst(); seen += 1
                if AX.string(c, kAXRoleAttribute) == "AXStaticText", let v = AX.string(c, kAXValueAttribute),
                   !v.trimmingCharacters(in: .whitespaces).isEmpty { texts.append(v) }
                queue += AX.children(c)
            }
            if texts.count >= 2 { return texts }
            node = AX.element(n, kAXParentAttribute); hops += 1
        }
        return []
    }

    /// The first element (breadth-first) that satisfies `match`.
    static func first(in root: AXUIElement, limit: Int = 12000, _ match: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = AX.children(root), visited = 0
        while !queue.isEmpty && visited < limit {
            let el = queue.removeFirst()
            visited += 1
            if match(el) { return el }
            queue += AX.children(el)
        }
        return nil
    }

    /// Titles of the rows in a table: the library sidebar (only rows scrolled into view exist in the tree).
    static func libraryRows(in root: AXUIElement, limit: Int = 12000) -> [Found] {
        var out: [Found] = []
        var queue = AX.children(root), visited = 0
        while !queue.isEmpty && visited < limit {
            let el = queue.removeFirst()
            visited += 1
            if AX.string(el, kAXRoleAttribute) == "AXRow" {
                if let title = AX.string(el, kAXTitleAttribute), !title.isEmpty { out.append((title, el)) }
                continue
            }
            queue += AX.children(el)
        }
        return out
    }

    /// Buttons labelled "Play <something>", in page order. The bare "Play" button is the player bar, not a result.
    static func playButtons(in root: AXUIElement, limit: Int = 12000) -> [Found] {
        var out: [Found] = []
        var queue = AX.children(root), visited = 0
        while !queue.isEmpty && visited < limit {
            let el = queue.removeFirst()
            visited += 1
            if AX.string(el, kAXRoleAttribute) == kAXButtonRole {
                let label = [kAXDescriptionAttribute, kAXTitleAttribute].compactMap { AX.string(el, $0) }.first { !$0.isEmpty } ?? ""
                if label.hasPrefix("Play ") { out.append((label, el)) }
            }
            queue += AX.children(el)
        }
        return out
    }

    /// "My Work playlist" → "work"
    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: #"\b(my|the|playlist|album|please)\b"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}
