// GroundingFixture
//
// A deterministic AppKit + WebKit window used to test screen-grounding.
// It lays out native controls, a scrolling table, a web view and a canvas
// with no accessibility children. After the window is ready it writes
// ~/.clicky/fixture/groundtruth.json with the global CoreGraphics frame of
// every item, so a grounding model's answers can be scored against it.
//
// Flags:
//   --display <i>          0-based index into NSScreen.screens (default 0)
//   --scroll-after <N>     N seconds after ready, scroll the table down 120 pt
//   --cover <KEY>          2 s after ready, spawn a helper that covers KEY
//   --cover-rect x,y,w,h   helper mode: show only an opaque grey cover window
//   --park-cursor          move the cursor to an empty spot before ready

import AppKit
import WebKit

// MARK: - Constants

let fixtureWindowSize = NSSize(width: 1200, height: 800)
let fixtureCoverPadding: CGFloat = 20

/// Height of the primary screen. CoreGraphics global coordinates are measured
/// from its top-left corner, AppKit global coordinates from its bottom-left.
var primaryScreenHeight: CGFloat {
    NSScreen.screens[0].frame.height
}

/// Prints an error to stderr and exits with status 1.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("GroundingFixture: \(message)\n".utf8))
    exit(1)
}

// MARK: - Command line

struct LaunchOptions {
    var displayIndex = 0
    var scrollAfterSeconds: Double?
    var coverKey: String?
    var coverRect: CGRect?
    var parkCursor = false
}

func parseRect(_ text: String) -> CGRect {
    let values = text.split(separator: ",").compactMap { Double($0) }
    guard values.count == 4 else { fail("--cover-rect expects x,y,w,h but got \(text)") }
    return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

func parseLaunchOptions(_ arguments: [String]) -> LaunchOptions {
    var options = LaunchOptions()
    var position = 1
    while position < arguments.count {
        let flag = arguments[position]

        func nextValue() -> String {
            guard position + 1 < arguments.count else { fail("\(flag) needs a value") }
            position += 1
            return arguments[position]
        }

        switch flag {
        case "--display":
            guard let index = Int(nextValue()), index >= 0 else {
                fail("--display expects a non-negative integer")
            }
            options.displayIndex = index
        case "--scroll-after":
            guard let seconds = Double(nextValue()), seconds >= 0 else {
                fail("--scroll-after expects a number of seconds")
            }
            options.scrollAfterSeconds = seconds
        case "--cover":
            options.coverKey = nextValue()
        case "--cover-rect":
            options.coverRect = parseRect(nextValue())
        case "--park-cursor":
            options.parkCursor = true
        default:
            fail("unknown argument \(flag)")
        }
        position += 1
    }
    return options
}

// MARK: - Ground truth file

struct GroundTruthItem: Encodable {
    let key: String
    let kind: String
    let frameCG: [CGFloat]
    let visible: Bool
}

struct GroundTruthDocument: Encodable {
    let ready: Bool
    let pid: Int32
    let helperPid: Int32?
    let displayID: UInt32?
    let items: [GroundTruthItem]?
}

/// Writes the document to ~/.clicky/fixture/groundtruth.json via a temp file
/// followed by an atomic rename.
func writeGroundTruth(_ document: GroundTruthDocument) {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clicky/fixture", isDirectory: true)
    let finalURL = directoryURL.appendingPathComponent("groundtruth.json")
    let temporaryURL = directoryURL.appendingPathComponent("groundtruth.json.tmp")
    do {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: temporaryURL)
        if rename(temporaryURL.path, finalURL.path) != 0 {
            fail("rename to groundtruth.json failed, errno \(errno)")
        }
    } catch {
        fail("could not write groundtruth.json: \(error)")
    }
}

// MARK: - Cover helper (separate process)

/// Shows a single opaque grey window over a global CoreGraphics rect.
/// Writes nothing and runs until killed.
final class CoverHelperDelegate: NSObject, NSApplicationDelegate {
    private let coverRect: CGRect
    private var coverWindow: NSWindow?

    init(rect: CGRect) {
        coverRect = rect
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let appKitFrame = NSRect(
            x: coverRect.minX,
            y: primaryScreenHeight - coverRect.minY - coverRect.height,
            width: coverRect.width,
            height: coverRect.height
        )
        let window = NSWindow(
            contentRect: appKitFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .gray
        window.hasShadow = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        coverWindow = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Canvas with drawn text and dots (no accessibility children)

/// Draws text and dots directly. It has no accessibility children, so any
/// grounding has to come from pixels. Item rects are kept in the view's own
/// flipped coordinates.
final class DrawnCanvasView: NSView {
    struct DrawnItem {
        let key: String
        let kind: String
        let rect: NSRect
    }

    private static let dotDiameter: CGFloat = 14

    private let textLines: [(key: String, text: String, origin: NSPoint, fontSize: CGFloat)] = [
        ("canvas_rate_limit", "rate limit exceeded (429)", NSPoint(x: 20, y: 20), 16),
        ("canvas_total", "Total: 1,284", NSPoint(x: 20, y: 60), 16),
        ("canvas_x42", "x = 42", NSPoint(x: 20, y: 100), 16),
        ("canvas_deploy_failed", "Deploy failed", NSPoint(x: 20, y: 140), 16),
        ("canvas_size_10", "Build 10pt", NSPoint(x: 20, y: 240), 10),
        ("canvas_size_11", "Retry 11pt", NSPoint(x: 20, y: 265), 11),
        ("canvas_size_13", "Queued 13pt", NSPoint(x: 20, y: 290), 13),
    ]

    private let dots: [(key: String, color: NSColor, origin: NSPoint)] = [
        ("dot_red", .systemRed, NSPoint(x: 20, y: 200)),
        ("dot_blue", .systemBlue, NSPoint(x: 50, y: 200)),
        ("dot_green", .systemGreen, NSPoint(x: 80, y: 200)),
        ("dot_yellow", .systemYellow, NSPoint(x: 110, y: 200)),
    ]

    private(set) var items: [DrawnItem] = []

    private func textAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.labelColor]
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        items = computeItems()
    }

    required init?(coder: NSCoder) {
        fatalError("DrawnCanvasView is not built from a nib")
    }

    private func computeItems() -> [DrawnItem] {
        var result: [DrawnItem] = []
        for line in textLines {
            let size = (line.text as NSString).size(withAttributes: textAttributes(fontSize: line.fontSize))
            result.append(DrawnItem(key: line.key, kind: "canvas", rect: NSRect(origin: line.origin, size: size)))
        }
        for dot in dots {
            let size = NSSize(width: Self.dotDiameter, height: Self.dotDiameter)
            result.append(DrawnItem(key: dot.key, kind: "dot", rect: NSRect(origin: dot.origin, size: size)))
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        for line in textLines {
            (line.text as NSString).draw(at: line.origin, withAttributes: textAttributes(fontSize: line.fontSize))
        }
        for dot in dots {
            dot.color.setFill()
            let size = NSSize(width: Self.dotDiameter, height: Self.dotDiameter)
            NSBezierPath(ovalIn: NSRect(origin: dot.origin, size: size)).fill()
        }
    }

    override func isAccessibilityElement() -> Bool {
        false
    }

    override func accessibilityChildren() -> [Any]? {
        []
    }
}

// MARK: - Plain flipped container

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Global frame conversion

/// Converts a rect in a view's coordinates to a global CoreGraphics frame.
func cgFrame(of rect: NSRect, in view: NSView) -> CGRect {
    guard let window = view.window else { fail("view is not in a window") }
    let inWindow = view.convert(rect, to: nil)
    let onScreen = window.convertToScreen(inWindow)
    return CGRect(
        x: onScreen.minX,
        y: primaryScreenHeight - onScreen.maxY,
        width: onScreen.width,
        height: onScreen.height
    )
}

/// The control's own accessibility frame (AppKit screen coordinates, y up)
/// converted to a global CoreGraphics frame.
func cgFrameFromAccessibility(of view: NSView) -> CGRect {
    let accessibilityFrame = view.accessibilityFrame()
    guard accessibilityFrame.width > 0, accessibilityFrame.height > 0 else {
        return cgFrame(of: view.bounds, in: view)
    }
    return CGRect(
        x: accessibilityFrame.minX,
        y: primaryScreenHeight - accessibilityFrame.maxY,
        width: accessibilityFrame.width,
        height: accessibilityFrame.height
    )
}

// MARK: - Main window controller

final class FixtureController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate {
    static let rowCount = 40
    static let rowHeight: CGFloat = 24
    static let webKeys = ["web_subscribe", "web_read_more", "web_sign_in", "web_pricing", "web_docs"]
    static let statusText = "Status: rate limit reached for this hour"

    private static let webRectsScript = """
    (function () {
      var ids = ["web_subscribe", "web_read_more", "web_sign_in", "web_pricing", "web_docs"];
      var out = {};
      ids.forEach(function (id) {
        var el = document.getElementById(id);
        if (!el) { return; }
        var r = el.getBoundingClientRect();
        out[id] = { x: r.x, y: r.y, width: r.width, height: r.height };
      });
      return JSON.stringify(out);
    })();
    """

    private static let webPageHTML = """
    <!doctype html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
      html, body { margin: 0; padding: 0; background: #ffffff; font: 14px -apple-system, system-ui, sans-serif; }
      .row { display: flex; gap: 12px; padding: 16px; align-items: flex-start; }
      a { color: #0a64d8; }
    </style>
    </head>
    <body>
      <div class="row">
        <button id="web_subscribe">Subscribe</button>
        <a id="web_read_more" href="#">Read more</a>
        <button id="web_sign_in">Sign in</button>
      </div>
      <div class="row">
        <a id="web_pricing" href="#">Pricing</a>
        <a id="web_docs" href="#">Docs</a>
      </div>
    </body>
    </html>
    """

    private struct NamedView {
        let key: String
        let kind: String
        let view: NSView
    }

    private struct WebRect: Decodable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    private struct MeasuredElement {
        let key: String
        let kind: String
        let frame: CGRect
        let inScrollView: Bool

        func groundTruthItem(coveredKey: String?) -> GroundTruthItem {
            GroundTruthItem(
                key: key,
                kind: kind,
                frameCG: [frame.minX, frame.minY, frame.width, frame.height],
                visible: inScrollView && key != coveredKey
            )
        }
    }

    private let options: LaunchOptions
    private var window: NSWindow!
    private var contentView: NSView!
    private var displayID: UInt32 = 0

    private var namedViews: [NamedView] = []
    private var tableScrollView: NSScrollView!
    private var tableView: NSTableView!
    private var webView: WKWebView!
    private var webFrames: [String: CGRect] = [:]
    private var canvasView: DrawnCanvasView!
    private var statusTextView: NSTextView!

    private var isReady = false
    private var coveredKey: String?
    private var helperProcess: Process?
    private var helperPid: Int32?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = NSScreen.screens
        guard screens.indices.contains(options.displayIndex) else {
            fail("--display \(options.displayIndex) is out of range, \(screens.count) screen(s) attached")
        }
        let screen = screens[options.displayIndex]
        displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0

        publish()

        let visible = screen.visibleFrame
        let contentRect = NSRect(
            x: visible.minX + 100,
            y: visible.maxY - 100 - fixtureWindowSize.height,
            width: fixtureWindowSize.width,
            height: fixtureWindowSize.height
        )
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Grounding Fixture"
        window.isReleasedWhenClosed = false
        // Show on whatever Space is active on that display (including a
        // full-screen one); a window on a hidden Space isn't in the
        // accessibility tree, so fixtureAX couldn't see it.
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Floating lets it sit over another app's full-screen Space too.
        window.level = .floating

        let content = FlippedView(frame: NSRect(origin: .zero, size: fixtureWindowSize))
        window.contentView = content
        contentView = content

        buildControls()

        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Become the frontmost app (what Clicky treats as "the app you're
        // looking at"); plain activate() is refused for background launches.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: Layout

    private func addNamed(_ view: NSView, key: String, kind: String = "ax") {
        contentView.addSubview(view)
        namedViews.append(NamedView(key: key, kind: kind, view: view))
    }

    private func buildControls() {
        // Row 1: text buttons, left to right.
        let buttonSpecs: [(key: String, title: String)] = [
            ("back", "Back"),
            ("share", "Share"),
            ("export_pdf", "Export as PDF…"),
            ("build_settings", "Build Settings"),
            ("cancel_1", "Cancel"),
            ("cancel_2", "Cancel"),
            ("run", "Run"),
            ("archive", "Archive"),
        ]
        var buttonX: CGFloat = 20
        for spec in buttonSpecs {
            let button = NSButton(title: spec.title, target: nil, action: nil)
            button.bezelStyle = .rounded
            button.sizeToFit()
            button.setFrameOrigin(NSPoint(x: buttonX, y: 20))
            addNamed(button, key: spec.key)
            buttonX = button.frame.maxX + 10
        }

        // Row 2: six 16 pt icon buttons.
        let iconSpecs: [(key: String, symbol: String, label: String)] = [
            ("icon_gear", "gearshape", "Gear"),
            ("icon_trash", "trash", "Trash"),
            ("icon_star", "star", "Star"),
            ("icon_bell", "bell", "Bell"),
            ("icon_lock", "lock", "Lock"),
            ("icon_info", "info.circle", "Info"),
        ]
        var iconX: CGFloat = 20
        for spec in iconSpecs {
            let icon = NSButton(frame: NSRect(x: iconX, y: 60, width: 16, height: 16))
            icon.isBordered = false
            icon.bezelStyle = .regularSquare
            icon.imagePosition = .imageOnly
            icon.imageScaling = .scaleProportionallyDown
            icon.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            icon.setAccessibilityLabel(spec.label)
            addNamed(icon, key: spec.key)
            iconX += 28
        }

        // Row 3: search and address fields.
        let searchField = NSTextField(frame: NSRect(x: 20, y: 100, width: 300, height: 22))
        searchField.placeholderString = "Search"
        searchField.stringValue = ""
        addNamed(searchField, key: "field_search")

        let addressField = NSTextField(frame: NSRect(x: 340, y: 100, width: 500, height: 22))
        addressField.stringValue = "github.com/addy/clicky/pull/12"
        addNamed(addressField, key: "field_address")

        // Left half: scrolling table of 40 rows.
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 540
        tableView = NSTableView(frame: NSRect(x: 0, y: 0, width: 540, height: CGFloat(Self.rowCount) * Self.rowHeight))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self

        tableScrollView = NSScrollView(frame: NSRect(x: 20, y: 150, width: 560, height: 360))
        tableScrollView.documentView = tableView
        tableScrollView.hasVerticalScroller = true
        tableScrollView.borderType = .bezelBorder
        contentView.addSubview(tableScrollView)

        // Right half top: web view.
        webView = WKWebView(frame: NSRect(x: 620, y: 150, width: 400, height: 220), configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        contentView.addSubview(webView)
        webView.loadHTMLString(Self.webPageHTML, baseURL: nil)

        // Right half bottom: drawn canvas with no accessibility children.
        canvasView = DrawnCanvasView(frame: NSRect(x: 620, y: 400, width: 560, height: 360))
        contentView.addSubview(canvasView)

        // Left column below the table: selectable, read-only status text.
        statusTextView = NSTextView(frame: NSRect(x: 20, y: 530, width: 560, height: 60))
        statusTextView.string = Self.statusText
        statusTextView.font = NSFont.systemFont(ofSize: 13)
        statusTextView.isEditable = false
        statusTextView.isSelectable = true
        statusTextView.drawsBackground = true
        contentView.addSubview(statusTextView)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        Self.rowCount
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: "Row \(row + 1)")
    }

    private func scrollTableDown(by delta: CGFloat) {
        let clipView = tableScrollView.contentView
        let target = NSPoint(x: clipView.bounds.origin.x, y: clipView.bounds.origin.y + delta)
        clipView.scroll(to: target)
        tableScrollView.reflectScrolledClipView(clipView)
    }

    // MARK: Web view

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(Self.webRectsScript) { result, error in
            if let error {
                fail("web rect script failed: \(error.localizedDescription)")
            }
            guard let json = result as? String,
                  let rects = try? JSONDecoder().decode([String: WebRect].self, from: Data(json.utf8)),
                  Self.webKeys.allSatisfy({ rects[$0] != nil })
            else {
                fail("web rect script returned unexpected data")
            }
            let webOrigin = cgFrame(of: webView.bounds, in: webView)
            for key in Self.webKeys {
                guard let rect = rects[key] else { continue }
                self.webFrames[key] = CGRect(
                    x: webOrigin.minX + rect.x,
                    y: webOrigin.minY + rect.y,
                    width: rect.width,
                    height: rect.height
                )
            }
            self.markReady()
        }
    }

    // MARK: Ready and follow-up actions

    private func markReady() {
        if options.parkCursor {
            parkCursorInWindowCorner()
        }
        isReady = true
        publish()

        if let delay = options.scrollAfterSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.scrollTableDown(by: 120)
                self.publish()
            }
        }
        if let key = options.coverKey {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.coverElement(key: key)
            }
        }
    }

    private func parkCursorInWindowCorner() {
        let frame = window.frame
        let appKitPoint = NSPoint(x: frame.maxX - 20, y: frame.minY + 20)
        CGWarpMouseCursorPosition(CGPoint(x: appKitPoint.x, y: primaryScreenHeight - appKitPoint.y))
    }

    /// Starts a helper process that covers the element's padded frame, then marks the key hidden.
    private func coverElement(key: String) {
        guard let target = measuredElements().first(where: { $0.key == key }) else {
            fail("--cover: no groundtruth item named \(key)")
        }
        let coverRect = target.frame.insetBy(dx: -fixtureCoverPadding, dy: -fixtureCoverPadding)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        helper.arguments = [
            "--cover-rect",
            "\(coverRect.minX),\(coverRect.minY),\(coverRect.width),\(coverRect.height)",
        ]
        do {
            try helper.run()
        } catch {
            fail("could not start cover helper: \(error)")
        }
        helperProcess = helper
        helperPid = helper.processIdentifier
        coveredKey = key
        publish()
    }

    // MARK: Measurement and publishing

    /// Global frames for every groundtruth item, measured from the live layout.
    private func measuredElements() -> [MeasuredElement] {
        var elements: [MeasuredElement] = []

        // Native controls use their own accessibility frame (AppKit screen
        // coordinates, flipped to CG): a push button's view frame includes
        // bezel padding the visible button doesn't, so the frame a user (and
        // the AX API) sees is 1 pt larger on every side than the view frame.
        for named in namedViews {
            elements.append(MeasuredElement(
                key: named.key,
                kind: named.kind,
                frame: cgFrameFromAccessibility(of: named.view),
                inScrollView: true
            ))
        }

        let visibleRect = tableScrollView.documentVisibleRect
        for row in 0..<Self.rowCount {
            let rowRect = tableView.rect(ofRow: row)
            elements.append(MeasuredElement(
                key: "row_\(row + 1)",
                kind: "ax",
                frame: cgFrame(of: rowRect, in: tableView),
                inScrollView: rowRect.intersects(visibleRect)
            ))
        }

        for key in Self.webKeys {
            guard let frame = webFrames[key] else { continue }
            elements.append(MeasuredElement(key: key, kind: "web", frame: frame, inScrollView: true))
        }

        for drawn in canvasView.items {
            elements.append(MeasuredElement(
                key: drawn.key,
                kind: drawn.kind,
                frame: cgFrame(of: drawn.rect, in: canvasView),
                inScrollView: true
            ))
        }

        elements.append(MeasuredElement(
            key: "textview_rate_limit",
            kind: "axtext",
            frame: statusTextRateLimitFrame(),
            inScrollView: true
        ))

        return elements
    }

    /// Global CoreGraphics frame of the "rate limit" substring in the status text view.
    /// firstRect(forCharacterRange:) returns AppKit screen coordinates (y up), so flip them.
    private func statusTextRateLimitFrame() -> CGRect {
        let substringRange = (Self.statusText as NSString).range(of: "rate limit")
        guard substringRange.location != NSNotFound else { fail("status text has no \"rate limit\" substring") }
        guard let textContainer = statusTextView.textContainer else { fail("status text view has no text container") }
        statusTextView.layoutManager?.ensureLayout(for: textContainer)
        let screenRect = statusTextView.firstRect(
            forCharacterRange: NSRange(location: substringRange.location, length: 10),
            actualRange: nil
        )
        return CGRect(
            x: screenRect.minX,
            y: primaryScreenHeight - screenRect.maxY,
            width: screenRect.width,
            height: screenRect.height
        )
    }

    /// Writes the current state. Before ready this is only {ready: false, pid}.
    private func publish() {
        let document: GroundTruthDocument
        if isReady {
            document = GroundTruthDocument(
                ready: true,
                pid: getpid(),
                helperPid: helperPid,
                displayID: displayID,
                items: measuredElements().map { $0.groundTruthItem(coveredKey: coveredKey) }
            )
        } else {
            document = GroundTruthDocument(ready: false, pid: getpid(), helperPid: nil, displayID: nil, items: nil)
        }
        writeGroundTruth(document)
    }
}

// MARK: - Entry point

@main
struct GroundingFixtureMain {
    static func main() {
        let options = parseLaunchOptions(CommandLine.arguments)
        let application = NSApplication.shared

        if let coverRect = options.coverRect {
            application.setActivationPolicy(.accessory)
            let helper = CoverHelperDelegate(rect: coverRect)
            application.delegate = helper
            withExtendedLifetime(helper) {
                application.run()
            }
        } else {
            application.setActivationPolicy(.accessory)
            let controller = FixtureController(options: options)
            application.delegate = controller
            withExtendedLifetime(controller) {
                application.run()
            }
        }
    }
}
