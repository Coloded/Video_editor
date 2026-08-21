import AppKit
import AVFoundation
import AVKit
import Foundation
import Sparkle
import UniformTypeIdentifiers

private struct CompressionProfile {
    let id: String
    let title: String
    let suffix: String
    let targetShortSide: Int
    let standardBitrate: Double
    let highFPSBitrate: Double
    let videoCodec: String
}

private struct SourceInfo {
    let width: Int
    let height: Int
    let fps: Double
    let videoBitrate: Double
    let codec: String
    let pixelFormat: String
    let colorTransfer: String
    let duration: Double

    var shortSide: Int { min(width, height) }
    var isHDR: Bool { colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67" }
    var isHighBitDepth: Bool { pixelFormat.contains("10") || pixelFormat.contains("12") }
}

private struct JoinClip {
    let id: UUID
    let url: URL
    let info: SourceInfo
    var lowerValue: Double
    var upperValue: Double
    var thumbnails: [NSImage]
}

private enum EditorMode: Int {
    case compress = 0
    case cut = 1
    case join = 2
}

private enum CompressionChoice {
    case original
    case profile(CompressionProfile)
    case cancelled
}

private enum AppLanguage: String {
    case ru
    case en

    static let defaultsKey = "AppLanguage"

    static func initial() -> AppLanguage {
        if let override = ProcessInfo.processInfo.environment["VIDEO_EDITOR_LANGUAGE"],
           let language = AppLanguage(rawValue: override.lowercased()) {
            return language
        }
        if let saved = UserDefaults.standard.string(forKey: defaultsKey),
           let language = AppLanguage(rawValue: saved) {
            return language
        }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ru") ? .ru : .en
    }
}

private final class WindowBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

private final class ScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum TimelineDragMode {
    case lower
    case upper
    case range
}

private final class RangeTimelineView: NSControl {
    var duration: Double = 1 {
        didSet {
            duration = max(duration, 0.001)
            lowerValue = min(max(0, lowerValue), duration)
            upperValue = min(max(lowerValue, upperValue), duration)
            needsDisplay = true
        }
    }
    var lowerValue: Double = 0 { didSet { needsDisplay = true } }
    var upperValue: Double = 1 { didSet { needsDisplay = true } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var onChange: ((Double, Double, Double) -> Void)?

    private var dragMode: TimelineDragMode?
    private var dragStartX: CGFloat = 0
    private var dragStartLower: Double = 0
    private var dragStartUpper: Double = 1

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 72) }

    private var trackRect: NSRect {
        bounds.insetBy(dx: 8, dy: 7)
    }

    private func xPosition(for value: Double) -> CGFloat {
        trackRect.minX + CGFloat(value / duration) * trackRect.width
    }

    private func value(at x: CGFloat) -> Double {
        let ratio = min(1, max(0, (x - trackRect.minX) / trackRect.width))
        return Double(ratio) * duration
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = trackRect
        let clip = NSBezierPath(roundedRect: track, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        NSColor.controlBackgroundColor.setFill()
        track.fill()

        if !thumbnails.isEmpty {
            let width = track.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let destination = NSRect(
                    x: track.minX + CGFloat(index) * width,
                    y: track.minY,
                    width: width + 1,
                    height: track.height
                )
                drawAspectFill(image, in: destination)
            }
        }

        let lowerX = xPosition(for: lowerValue)
        let upperX = xPosition(for: upperValue)
        NSColor.black.withAlphaComponent(0.56).setFill()
        NSRect(x: track.minX, y: track.minY, width: max(0, lowerX - track.minX), height: track.height).fill()
        NSRect(x: upperX, y: track.minY, width: max(0, track.maxX - upperX), height: track.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        NSColor.controlAccentColor.setStroke()
        let selection = NSBezierPath(
            roundedRect: NSRect(x: lowerX, y: track.minY, width: max(2, upperX - lowerX), height: track.height),
            xRadius: 5,
            yRadius: 5
        )
        selection.lineWidth = 3
        selection.stroke()

        drawHandle(at: lowerX)
        drawHandle(at: upperX)
    }

    private func drawAspectFill(_ image: NSImage, in destination: NSRect) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let sourceAspect = size.width / size.height
        let destinationAspect = destination.width / destination.height
        var source = NSRect(origin: .zero, size: size)
        if sourceAspect > destinationAspect {
            let width = size.height * destinationAspect
            source.origin.x = (size.width - width) / 2
            source.size.width = width
        } else {
            let height = size.width / destinationAspect
            source.origin.y = (size.height - height) / 2
            source.size.height = height
        }
        image.draw(in: destination, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawHandle(at x: CGFloat) {
        let rect = NSRect(x: x - 6, y: trackRect.minY - 3, width: 12, height: trackRect.height + 6)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        outline.lineWidth = 2
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let lowerX = xPosition(for: lowerValue)
        let upperX = xPosition(for: upperValue)
        if abs(point.x - lowerX) <= 14 {
            dragMode = .lower
        } else if abs(point.x - upperX) <= 14 {
            dragMode = .upper
        } else if point.x > lowerX && point.x < upperX {
            dragMode = .range
        } else {
            dragMode = abs(point.x - lowerX) < abs(point.x - upperX) ? .lower : .upper
        }
        dragStartX = point.x
        dragStartLower = lowerValue
        dragStartUpper = upperValue
        updateDrag(at: point.x)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil).x)
        dragMode = nil
    }

    private func updateDrag(at x: CGFloat) {
        guard let dragMode else { return }
        let minimumGap = min(0.1, duration)
        var previewTime = lowerValue
        switch dragMode {
        case .lower:
            lowerValue = min(max(0, value(at: x)), upperValue - minimumGap)
            previewTime = lowerValue
        case .upper:
            upperValue = max(min(duration, value(at: x)), lowerValue + minimumGap)
            previewTime = upperValue
        case .range:
            let delta = Double((x - dragStartX) / trackRect.width) * duration
            let length = dragStartUpper - dragStartLower
            let newLower = min(max(0, dragStartLower + delta), duration - length)
            lowerValue = newLower
            upperValue = newLower + length
            previewTime = lowerValue
        }
        onChange?(lowerValue, upperValue, previewTime)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let lowerX = xPosition(for: lowerValue)
        let upperX = xPosition(for: upperValue)
        addCursorRect(NSRect(x: lowerX - 12, y: 0, width: 24, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: upperX - 12, y: 0, width: 24, height: bounds.height), cursor: .resizeLeftRight)
        if upperX - lowerX > 30 {
            addCursorRect(NSRect(x: lowerX + 12, y: 0, width: upperX - lowerX - 24, height: bounds.height), cursor: .openHand)
        }
    }
}

@available(macOS 13.0, *)
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate,
                         NSTableViewDataSource, NSTableViewDelegate {
    private var appLanguage = AppLanguage.initial()
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private let videoInputExtensions = [
        "mov", "mp4", "m4v", "mkv", "avi", "webm", "mpg", "mpeg",
        "ts", "mts", "m2ts", "vob", "3gp", "flv", "wmv", "ogv"
    ]
    private let audioInputExtensions = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
    private let compressedOutputExtensions = ["mp4", "mov", "mkv"]
    private let profiles = [
        CompressionProfile(id: "240", title: "240p  -  H.264, 0.6 Мбит/с", suffix: "240p", targetShortSide: 240, standardBitrate: 0.6, highFPSBitrate: 0.9, videoCodec: "h264"),
        CompressionProfile(id: "360", title: "360p  -  H.264, 1 Мбит/с", suffix: "360p", targetShortSide: 360, standardBitrate: 1, highFPSBitrate: 1.5, videoCodec: "h264"),
        CompressionProfile(id: "480", title: "480p  -  H.264, 2.5 Мбит/с", suffix: "480p", targetShortSide: 480, standardBitrate: 2.5, highFPSBitrate: 4, videoCodec: "h264"),
        CompressionProfile(id: "720", title: "720p HD  -  H.264, 5 Мбит/с", suffix: "720p", targetShortSide: 720, standardBitrate: 5, highFPSBitrate: 7.5, videoCodec: "h264"),
        CompressionProfile(id: "1080", title: "1080p Full HD  -  H.264, 8 Мбит/с", suffix: "1080p", targetShortSide: 1080, standardBitrate: 8, highFPSBitrate: 12, videoCodec: "h264"),
        CompressionProfile(id: "1440", title: "1440p QHD  -  H.264, 16 Мбит/с", suffix: "1440p", targetShortSide: 1440, standardBitrate: 16, highFPSBitrate: 24, videoCodec: "h264"),
        CompressionProfile(id: "2160", title: "2160p 4K  -  H.264, 40 Мбит/с", suffix: "2160p", targetShortSide: 2160, standardBitrate: 40, highFPSBitrate: 60, videoCodec: "h264"),
        CompressionProfile(id: "youtube", title: "YouTube 4K SDR", suffix: "youtube", targetShortSide: 2160, standardBitrate: 40, highFPSBitrate: 60, videoCodec: "h264"),
        CompressionProfile(id: "youtube-compact", title: "YouTube 4K Compact  -  HEVC", suffix: "youtube-compact", targetShortSide: 2160, standardBitrate: 24, highFPSBitrate: 36, videoCodec: "hevc")
    ]
    private var availableProfiles: [CompressionProfile] = []
    private var preferredProfileID = "1080"
    private var sourceInfo: SourceInfo?
    private var analysisToken = UUID()
    private var previewToken = UUID()

    private var window: NSWindow!
    private let modeControl = NSSegmentedControl(
        labels: ["", "", ""],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let fileField = NSTextField()
    private let browseButton = NSButton()
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let hdrRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let sdrRadio = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let cpuCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let playerView = AVPlayerView()
    private let timelineView = RangeTimelineView()
    private let selectionLabel = NSTextField(labelWithString: "")
    private let joinTable = NSTableView()
    private var playerHeightConstraint: NSLayoutConstraint!
    private var joinListHeightConstraint: NSLayoutConstraint!
    private var joinStack: NSStackView!
    private var joinClips: [JoinClip] = []
    private var joinEditButtons: [NSButton] = []
    private var profileRow: NSStackView!
    private var cutRow: NSStackView!
    private var previewStack: NSStackView!
    private var playerTimeObserver: Any?

    private let statusLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let resourceLabel = NSTextField(wrappingLabelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let technicalLabel = NSTextField(wrappingLabelWithString: "")
    private var technicalValues: [String: String] = [:]

    private let startButton = NSButton()
    private let revealButton = NSButton()

    private var selectedInputURL: URL?
    private var selectedOutputURL: URL?
    private var processManifestURL: URL?
    private var pendingCompressionProfile: CompressionProfile?
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var diagnosticOutput = ""
    private var wasCancelled = false

    private var mode: EditorMode {
        EditorMode(rawValue: modeControl.selectedSegment) ?? .compress
    }

    private func text(_ russian: String, _ english: String) -> String {
        appLanguage == .ru ? russian : english
    }

    private func contentTypes(for extensions: [String]) -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }

    private func profileTitle(_ profile: CompressionProfile) -> String {
        if let sourceInfo,
           (sourceInfo.isHDR || sourceInfo.isHighBitDepth),
           hdrRadio.state == .on {
            let baseTitle = profile.title.components(separatedBy: "  -  ").first ?? profile.title
            let baseBitrate = sourceInfo.fps > 30.5 ? profile.highFPSBitrate : profile.standardBitrate
            let bitrate = profile.videoCodec == "hevc" ? baseBitrate : baseBitrate * 0.60
            let bitrateText = bitrate.rounded() == bitrate
                ? String(format: "%.0f", bitrate)
                : String(format: "%.1f", bitrate)
            return "\(baseTitle)  -  HEVC HDR 10-bit, \(bitrateText) \(text("Мбит/с", "Mbps"))"
        }
        guard appLanguage == .en else { return profile.title }
        return profile.title
            .replacingOccurrences(of: "Мбит/с", with: "Mbps")
            .replacingOccurrences(of: "компактный", with: "Compact")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        configureWindow()
        _ = updaterController
        guard verifyRuntimeRequirements() else { return }
        createDiagnosticSnapshotIfRequested()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard window != nil else { return }
        resizeWindow(for: mode, animated: false)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let visibleFrame = sender.screen?.visibleFrame else { return frameSize }
        return NSSize(
            width: min(frameSize.width, visibleFrame.width),
            height: min(frameSize.height, visibleFrame.height)
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePlayerTimeObserver()
        if process?.isRunning == true {
            process?.interrupt()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        if mode == .join {
            addJoinURLs(urls)
        } else if let url = urls.first {
            selectInput(url)
        }
    }

    private func configureMenu() {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Video Editor")
        applicationMenu.addItem(
            withTitle: text("О Video Editor", "About Video Editor"),
            action: #selector(showAbout(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let updateItem = applicationMenu.addItem(
            withTitle: text("Проверить обновления…", "Check for Updates…"),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let fileItem = NSMenuItem(title: text("Файл", "File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: text("Файл", "File"))
        let openItem = fileMenu.addItem(
            withTitle: text("Открыть файл…", "Open File…"),
            action: #selector(openFile(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(.separator())
        let quitItem = fileMenu.addItem(
            withTitle: text("Выход", "Quit"),
            action: #selector(quitApplication(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let languageItem = NSMenuItem(title: text("Язык", "Language"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu(title: text("Язык", "Language"))
        for (title, language) in [("Русский", AppLanguage.ru), ("English", AppLanguage.en)] {
            let item = languageMenu.addItem(
                withTitle: title,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = language.rawValue
            item.state = language == appLanguage ? .on : .off
        }
        languageItem.submenu = languageMenu
        mainMenu.addItem(languageItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue),
              language != appLanguage else { return }
        appLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: AppLanguage.defaultsKey)
        applyLanguage()
    }

    private var localizationPairs: [(String, String)] {
        [
            ("Файл", "File"), ("Профиль", "Profile"), ("Кодировщик", "Encoder"),
            ("Время", "Time"), ("Старт", "Start"), ("Конец", "End"),
            ("Только CPU", "CPU only"), ("Обзор…", "Browse…"), ("Добавить…", "Add…"),
            ("Порядок сверху вниз", "Order top to bottom"), ("Показать", "Show"),
            ("Выберите файл", "Select a file"), ("Файл не выбран", "No file selected"),
            ("Ролики не выбраны", "No clips selected"),
            ("Добавьте минимум два ролика", "Add at least two clips"),
            ("Добавьте ещё один ролик", "Add one more clip"),
            ("Анализирую ролики", "Analyzing clips"), ("Анализ качества", "Analyzing quality"),
            ("Загрузка видео", "Loading video"), ("Анализирую файл…", "Analyzing file…"),
            ("Видео не найдено", "No video found"), ("Нет видеодорожки", "No video track"),
            ("Нет подходящих профилей", "No suitable profiles"),
            ("Нет подходящего профиля", "No suitable profile"),
            ("Готов к запуску", "Ready"), ("Готов к вырезанию", "Ready to cut"),
            ("Готов к склейке", "Ready to join"), ("Сжимаю видео", "Compressing video"),
            ("Вырезаю фрагмент", "Cutting clip"), ("Вырезаю и сжимаю", "Cutting and compressing"),
            ("Склеиваю ролики", "Joining clips"), ("Склеиваю и сжимаю", "Joining and compressing"),
            ("Готовлю сжатие", "Preparing compression"), ("Готовлю вырезание", "Preparing cut"),
            ("Готовлю вырезание и сжатие", "Preparing cut and compression"),
            ("Готовлю склейку", "Preparing join"), ("Анализирую размер", "Estimating size"),
            ("Ошибка", "Error"), ("Готово", "Done"), ("Остановлено", "Stopped"),
            ("Останавливаю", "Stopping"), ("Остановить", "Stop"),
            ("Добавить ролики", "Add clips"), ("Удалить выбранный ролик", "Remove selected clip"),
            ("Переместить ролик выше", "Move clip up"), ("Переместить ролик ниже", "Move clip down")
        ]
    }

    private func localizedCurrentText(_ value: String) -> String {
        for (russian, english) in localizationPairs where value == russian || value == english {
            return text(russian, english)
        }
        let countedPrefixes = [
            ("Выбрано роликов: ", "Selected clips: "),
            ("Добавляется: ", "Adding: ")
        ]
        for (russian, english) in countedPrefixes {
            if value.hasPrefix(russian) {
                return text(russian, english) + value.dropFirst(russian.count)
            }
            if value.hasPrefix(english) {
                return text(russian, english) + value.dropFirst(english.count)
            }
        }
        return value
    }

    private func applyLanguage() {
        configureMenu()
        modeControl.setLabel(text("Сжатие", "Compress"), forSegment: EditorMode.compress.rawValue)
        modeControl.setLabel(text("Вырезать", "Cut"), forSegment: EditorMode.cut.rawValue)
        modeControl.setLabel(text("Склейка", "Join"), forSegment: EditorMode.join.rawValue)

        if let contentView = window?.contentView {
            for view in descendants(of: contentView) {
                if let field = view as? NSTextField {
                    field.stringValue = localizedCurrentText(field.stringValue)
                    if let placeholder = field.placeholderString {
                        field.placeholderString = localizedCurrentText(placeholder)
                    }
                    field.toolTip = field.toolTip.map(localizedCurrentText)
                } else if let button = view as? NSButton {
                    button.title = localizedCurrentText(button.title)
                    button.toolTip = button.toolTip.map(localizedCurrentText)
                }
            }
        }

        browseButton.title = mode == .join ? text("Добавить…", "Add…") : text("Обзор…", "Browse…")
        cpuCheckbox.title = text("Только CPU", "CPU only")
        cpuCheckbox.toolTip = text("Отключить Apple VideoToolbox и кодировать процессором", "Disable Apple VideoToolbox and encode on the CPU")
        hdrRadio.title = text("HDR 10-бит", "HDR 10-bit")
        hdrRadio.toolTip = text("Сохранить HDR в HEVC 10-бит", "Preserve HDR as 10-bit HEVC")
        sdrRadio.title = text("SDR 8-бит", "SDR 8-bit")
        sdrRadio.toolTip = text("Преобразовать HDR в совместимый SDR с tone mapping", "Convert HDR to compatible SDR with tone mapping")
        timelineView.toolTip = text("Перетащите границы или весь выбранный фрагмент", "Drag either edge or the entire selected range")
        revealButton.title = text("Показать", "Show")
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: text("Показать в Finder", "Show in Finder"))
        startButton.title = process?.isRunning == true ? text("Остановить", "Stop") : text("Старт", "Start")
        startButton.image = NSImage(
            systemSymbolName: process?.isRunning == true ? "stop.fill" : "play.fill",
            accessibilityDescription: startButton.title
        )

        if profilePopup.numberOfItems == availableProfiles.count, !availableProfiles.isEmpty {
            let selectedIndex = profilePopup.indexOfSelectedItem
            profilePopup.removeAllItems()
            profilePopup.addItems(withTitles: availableProfiles.map(profileTitle))
            if availableProfiles.indices.contains(selectedIndex) {
                profilePopup.selectItem(at: selectedIndex)
            }
        }
        updateTechnicalDetails()
        joinTable.reloadData()
        if timelineView.isEnabled {
            updateSelectionLabel()
        }
        window?.contentView?.needsLayout = true
    }

    private func configureWindow() {
        let launchVisibleFrame = NSScreen.main?.visibleFrame
        let launchWidth = min(720, max(500, (launchVisibleFrame?.width ?? 736) - 16))
        let launchHeight = min(470, max(420, (launchVisibleFrame?.height ?? 486) - 16))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: launchWidth, height: launchHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Video Editor"
        window.minSize = NSSize(width: 640, height: 440)
        window.center()
        window.delegate = self

        let contentView = WindowBackgroundView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "Video Editor")
        titleLabel.font = .systemFont(ofSize: 27, weight: .semibold)

        modeControl.selectedSegment = EditorMode.compress.rawValue
        modeControl.setLabel(text("Сжатие", "Compress"), forSegment: EditorMode.compress.rawValue)
        modeControl.setLabel(text("Вырезать", "Cut"), forSegment: EditorMode.cut.rawValue)
        modeControl.setLabel(text("Склейка", "Join"), forSegment: EditorMode.join.rawValue)
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.controlSize = .large

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleLabel, headerSpacer, modeControl])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 16

        fileField.isEditable = false
        fileField.isSelectable = true
        fileField.placeholderString = text("Файл не выбран", "No file selected")
        fileField.lineBreakMode = .byTruncatingMiddle
        fileField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        browseButton.title = text("Обзор…", "Browse…")
        browseButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: text("Обзор", "Browse"))
        browseButton.imagePosition = .imageLeading
        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .large
        browseButton.target = self
        browseButton.action = #selector(openFile(_:))

        let fileControls = NSStackView(views: [fileField, browseButton])
        fileControls.orientation = .horizontal
        fileControls.alignment = .centerY
        fileControls.spacing = 10
        let fileRow = makeLabeledRow(title: text("Файл", "File"), control: fileControls)

        availableProfiles = profiles
        profilePopup.addItems(withTitles: availableProfiles.map(profileTitle))
        profilePopup.selectItem(at: 4)
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.controlSize = .large
        profilePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hdrRadio.title = text("HDR 10-бит", "HDR 10-bit")
        hdrRadio.toolTip = text("Сохранить HDR в HEVC 10-бит", "Preserve HDR as 10-bit HEVC")
        hdrRadio.target = self
        hdrRadio.action = #selector(hdrModeChanged(_:))
        hdrRadio.isEnabled = false
        sdrRadio.title = text("SDR 8-бит", "SDR 8-bit")
        sdrRadio.toolTip = text("Преобразовать HDR в совместимый SDR с tone mapping", "Convert HDR to compatible SDR with tone mapping")
        sdrRadio.target = self
        sdrRadio.action = #selector(hdrModeChanged(_:))
        sdrRadio.state = .on
        sdrRadio.isEnabled = false
        let profileControls = NSStackView(views: [profilePopup, hdrRadio, sdrRadio])
        profileControls.orientation = .horizontal
        profileControls.alignment = .centerY
        profileControls.spacing = 12
        profileRow = makeLabeledRow(title: text("Профиль", "Profile"), control: profileControls)

        cpuCheckbox.title = text("Только CPU", "CPU only")
        cpuCheckbox.toolTip = text("Отключить Apple VideoToolbox и кодировать процессором", "Disable Apple VideoToolbox and encode on the CPU")
        let cpuRow = makeLabeledRow(title: text("Кодировщик", "Encoder"), control: cpuCheckbox)
        cpuRow.identifier = NSUserInterfaceItemIdentifier("cpuRow")

        startField.placeholderString = "1:30"
        endField.placeholderString = "1:50"
        startField.controlSize = .large
        endField.controlSize = .large
        startField.delegate = self
        endField.delegate = self
        startField.target = self
        endField.target = self
        startField.action = #selector(timeFieldsChanged(_:))
        endField.action = #selector(timeFieldsChanged(_:))
        startField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        endField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true

        let startLabel = NSTextField(labelWithString: text("Старт", "Start"))
        let endLabel = NSTextField(labelWithString: text("Конец", "End"))
        let timeControls = NSStackView(views: [startLabel, startField, endLabel, endField])
        timeControls.orientation = .horizontal
        timeControls.alignment = .centerY
        timeControls.spacing = 10
        cutRow = makeLabeledRow(title: text("Время", "Time"), control: timeControls)
        cutRow.isHidden = true

        let clipColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("clip"))
        clipColumn.resizingMask = .autoresizingMask
        joinTable.addTableColumn(clipColumn)
        joinTable.headerView = nil
        joinTable.rowHeight = 30
        joinTable.usesAlternatingRowBackgroundColors = true
        joinTable.allowsMultipleSelection = false
        joinTable.dataSource = self
        joinTable.delegate = self
        joinTable.action = #selector(joinSelectionChanged(_:))

        let joinScroll = NSScrollView()
        joinScroll.hasVerticalScroller = true
        joinScroll.autohidesScrollers = true
        joinScroll.borderType = .bezelBorder
        joinScroll.documentView = joinTable
        joinListHeightConstraint = joinScroll.heightAnchor.constraint(equalToConstant: 84)
        joinListHeightConstraint.isActive = true

        let addClipButton = makeIconButton(
            symbol: "plus",
            toolTip: text("Добавить ролики", "Add clips"),
            action: #selector(addJoinClips(_:))
        )
        let removeClipButton = makeIconButton(
            symbol: "minus",
            toolTip: text("Удалить выбранный ролик", "Remove selected clip"),
            action: #selector(removeJoinClip(_:))
        )
        let moveUpButton = makeIconButton(
            symbol: "chevron.up",
            toolTip: text("Переместить ролик выше", "Move clip up"),
            action: #selector(moveJoinClipUp(_:))
        )
        let moveDownButton = makeIconButton(
            symbol: "chevron.down",
            toolTip: text("Переместить ролик ниже", "Move clip down"),
            action: #selector(moveJoinClipDown(_:))
        )
        joinEditButtons = [addClipButton, removeClipButton, moveUpButton, moveDownButton]
        let joinHint = NSTextField(labelWithString: text("Порядок сверху вниз", "Order top to bottom"))
        joinHint.textColor = .secondaryLabelColor
        let joinButtonSpacer = NSView()
        joinButtonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let joinButtons = NSStackView(views: [addClipButton, removeClipButton, moveUpButton, moveDownButton, joinButtonSpacer, joinHint])
        joinButtons.orientation = .horizontal
        joinButtons.alignment = .centerY
        joinButtons.spacing = 7

        joinStack = NSStackView(views: [joinScroll, joinButtons])
        joinStack.orientation = .vertical
        joinStack.alignment = .leading
        joinStack.spacing = 7
        joinStack.isHidden = true
        joinScroll.widthAnchor.constraint(equalTo: joinStack.widthAnchor).isActive = true
        joinButtons.widthAnchor.constraint(equalTo: joinStack.widthAnchor).isActive = true

        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.layer?.cornerRadius = 6
        playerHeightConstraint = playerView.heightAnchor.constraint(equalToConstant: 240)
        playerHeightConstraint.isActive = true

        timelineView.toolTip = text("Перетащите границы или весь выбранный фрагмент", "Drag either edge or the entire selected range")
        timelineView.heightAnchor.constraint(equalToConstant: 72).isActive = true
        timelineView.onChange = { [weak self] lower, upper, previewTime in
            self?.timelineChanged(lower: lower, upper: upper, previewTime: previewTime)
        }

        selectionLabel.textColor = .secondaryLabelColor
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        selectionLabel.alignment = .right
        previewStack = NSStackView(views: [playerView, timelineView, selectionLabel])
        previewStack.orientation = .vertical
        previewStack.alignment = .leading
        previewStack.spacing = 8
        previewStack.isHidden = true
        for view in [playerView, timelineView, selectionLabel] {
            view.widthAnchor.constraint(equalTo: previewStack.widthAnchor).isActive = true
        }

        let separator = NSBox()
        separator.boxType = .separator

        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        percentLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        percentLabel.alignment = .right

        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, statusSpacer, percentLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.doubleValue = 0
        progressBar.controlSize = .large

        for label in [detailLabel, resourceLabel, sizeLabel, technicalLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .systemFont(ofSize: 12.5)
            label.lineBreakMode = .byTruncatingTail
        }
        resourceLabel.isHidden = true
        resourceLabel.maximumNumberOfLines = 2
        sizeLabel.isHidden = true
        technicalLabel.maximumNumberOfLines = 3
        technicalLabel.isHidden = true

        revealButton.title = text("Показать", "Show")
        revealButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: text("Показать в Finder", "Show in Finder"))
        revealButton.imagePosition = .imageLeading
        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(revealOutput(_:))
        revealButton.isHidden = true

        startButton.title = text("Старт", "Start")
        startButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: text("Старт", "Start"))
        startButton.imagePosition = .imageLeading
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startWork(_:))
        startButton.isEnabled = false

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [revealButton, buttonSpacer, startButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let mainStack = NSStackView(views: [
            header,
            fileRow,
            profileRow,
            cpuRow,
            joinStack,
            cutRow,
            previewStack,
            separator,
            statusRow,
            progressBar,
            detailLabel,
            resourceLabel,
            sizeLabel,
            technicalLabel
        ])
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 13
        mainStack.setCustomSpacing(20, after: header)
        mainStack.setCustomSpacing(18, after: cutRow)
        mainStack.setCustomSpacing(18, after: sizeLabel)
        let scrollDocument = ScrollDocumentView()
        scrollDocument.translatesAutoresizingMaskIntoConstraints = false
        scrollDocument.addSubview(mainStack)

        let mainScrollView = NSScrollView()
        mainScrollView.translatesAutoresizingMaskIntoConstraints = false
        mainScrollView.drawsBackground = false
        mainScrollView.borderType = .noBorder
        mainScrollView.hasVerticalScroller = true
        mainScrollView.hasHorizontalScroller = false
        mainScrollView.autohidesScrollers = true
        mainScrollView.verticalScrollElasticity = .automatic
        mainScrollView.documentView = scrollDocument
        contentView.addSubview(mainScrollView)

        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(buttonRow)

        for view in [header, fileRow, profileRow!, cpuRow, joinStack!, cutRow!, previewStack!, separator, statusRow,
                     progressBar, detailLabel, resourceLabel, sizeLabel, technicalLabel] {
            view.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            mainScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mainScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mainScrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            mainScrollView.bottomAnchor.constraint(equalTo: buttonRow.topAnchor, constant: -12),

            scrollDocument.leadingAnchor.constraint(equalTo: mainScrollView.contentView.leadingAnchor),
            scrollDocument.trailingAnchor.constraint(equalTo: mainScrollView.contentView.trailingAnchor),
            scrollDocument.topAnchor.constraint(equalTo: mainScrollView.contentView.topAnchor),
            scrollDocument.widthAnchor.constraint(equalTo: mainScrollView.contentView.widthAnchor),

            mainStack.leadingAnchor.constraint(equalTo: scrollDocument.leadingAnchor, constant: 28),
            mainStack.trailingAnchor.constraint(equalTo: scrollDocument.trailingAnchor, constant: -28),
            mainStack.topAnchor.constraint(equalTo: scrollDocument.topAnchor, constant: 24),
            mainStack.bottomAnchor.constraint(equalTo: scrollDocument.bottomAnchor, constant: -20),

            buttonRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 28),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -28),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            modeControl.widthAnchor.constraint(equalToConstant: 330),
            browseButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110),
            startButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 125)
        ])

        window.makeKeyAndOrderFront(nil)
        modeControl.selectedSegment = EditorMode.compress.rawValue
        statusLabel.stringValue = text("Выберите файл", "Select a file")
        modeControl.needsDisplay = true
        resizeWindow(for: .compress, animated: false)
    }

    private func createDiagnosticSnapshotIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT"] else { return }
        let snapshotMode = ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT_MODE"]
        if snapshotMode == "cut" {
            modeControl.selectedSegment = EditorMode.cut.rawValue
            modeChanged(modeControl)
        } else if snapshotMode == "join" {
            modeControl.selectedSegment = EditorMode.join.rawValue
            modeChanged(modeControl)
        }
        if let input = ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT_INPUT"] {
            let url = URL(fileURLWithPath: input)
            if snapshotMode == "join" {
                addJoinURLs([url, url, url])
            } else {
                selectInput(url)
            }
        }
        let delay = ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT_INPUT"] == nil ? 0.3 : 3.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let view = self.window.contentView else { return }
            if let rawHeight = ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT_HEIGHT"],
               let height = Double(rawHeight) {
                self.window.minSize = NSSize(width: 500, height: 420)
                var frame = self.window.frame
                frame.size.height = max(420, height)
                self.window.setFrame(frame, display: true)
            }
            if ProcessInfo.processInfo.environment["VIDEO_EDITOR_SNAPSHOT_RUNNING"] == "1" {
                self.setRunning(true)
                switch self.mode {
                case .compress:
                    self.processLine("Профиль: 1080p Full HD SDR", isError: false)
                    self.statusLabel.stringValue = self.text("Сжимаю видео", "Compressing video")
                case .cut:
                    self.processLine("Профиль: Без повторного кодирования", isError: false)
                    self.statusLabel.stringValue = self.text("Вырезаю фрагмент", "Cutting clip")
                case .join:
                    self.processLine("Профиль: Без дополнительного сжатия", isError: false)
                    self.statusLabel.stringValue = self.text("Склеиваю ролики", "Joining clips")
                }
                self.processLine("Исходник: 3840x2160, 23.976 fps, h264", isError: false)
                self.processLine("Видео: H.264, VideoToolbox, 8.000 Мбит/с", isError: false)
                self.processLine("Аудио: AAC, 48 кГц, стерео", isError: false)
                self.processLine("Ускорение: Apple VideoToolbox (аппаратный медиадвижок)", isError: false)
                let cores = ProcessInfo.processInfo.activeProcessorCount
                let ram = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
                self.processLine("Ресурсы: CPU 62% (6.2/\(cores)) | RAM 420.0 МБ / \(String(format: "%.0f", ram)) ГБ | Media Engine VT | запись 7.1 МБ/с", isError: false)
                if self.mode == .join {
                    self.processLine("/ [##########--------------] 42% | Склейка 00:05:41.000/00:13:32.020 | прошло 00:00:36.000 | осталось 00:00:50.000 | 9.47x | Исходники 21 шт., 3.821 ГБ | создано 272.0 МБ | итог ~647.8 МБ", isError: false)
                } else {
                    self.processLine("/ [##########--------------] 42% | Видео 00:05:41.000/00:13:32.020 | прошло 00:00:36.000 | осталось 00:00:50.000 | 9.47x | файл 272.0 МБ -> итог ~647.8 МБ", isError: false)
                }
            }
            view.layoutSubtreeIfNeeded()
            let bounds = view.bounds
            guard let imageRep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
            view.cacheDisplay(in: bounds, to: imageRep)
            if let data = imageRep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    private func makeLabeledRow(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 82).isActive = true

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func verifyRuntimeRequirements() -> Bool {
        let requirements = text(
            "Минимальная версия: macOS 13 Ventura.\nПоддерживаются macOS 13, 14, 15 и 26.",
            "Minimum version: macOS 13 Ventura.\nmacOS 13, 14, 15, and 26 are supported."
        )
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 13, minorVersion: 0, patchVersion: 0)
        ) else {
            let alert = NSAlert()
            alert.messageText = text("Эта версия macOS не поддерживается", "This macOS version is not supported")
            alert.informativeText = requirements
            alert.addButton(withTitle: text("Выйти", "Quit"))
            alert.runModal()
            NSApp.terminate(nil)
            return false
        }

        if locateTool(named: "ffmpeg") != nil, locateTool(named: "ffprobe") != nil {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        if let brew = brewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            let command = "\(brew) install ffmpeg"
            let alert = NSAlert()
            alert.messageText = text("FFmpeg не установлен", "FFmpeg is not installed")
            alert.informativeText = text(
                "Установите обычный FFmpeg командой:\n\n\(command)\n\nПосле установки перезапустите Video Editor.\n\n\(requirements)",
                "Install FFmpeg with:\n\n\(command)\n\nRestart Video Editor after installation.\n\n\(requirements)"
            )
            alert.addButton(withTitle: text("Скопировать и открыть Terminal", "Copy and open Terminal"))
            alert.addButton(withTitle: text("Выйти", "Quit"))
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                openTerminal()
            }
        } else {
            let alert = NSAlert()
            alert.messageText = text("Homebrew и FFmpeg не установлены", "Homebrew and FFmpeg are not installed")
            alert.informativeText = text(
                "Сначала установите Homebrew с brew.sh, затем выполните:\n\nbrew install ffmpeg\n\nПосле установки перезапустите Video Editor.\n\n\(requirements)",
                "Install Homebrew from brew.sh, then run:\n\nbrew install ffmpeg\n\nRestart Video Editor after installation.\n\n\(requirements)"
            )
            alert.addButton(withTitle: text("Открыть brew.sh", "Open brew.sh"))
            alert.addButton(withTitle: text("Выйти", "Quit"))
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "https://brew.sh") {
                NSWorkspace.shared.open(url)
            }
        }
        NSApp.terminate(nil)
        return false
    }

    private func openTerminal() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", "Terminal"]
        try? task.run()
    }

    private func makeIconButton(symbol: String, toolTip: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
        button.bezelStyle = .rounded
        button.toolTip = toolTip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    @objc private func showAbout(_ sender: Any?) {
        let applicationVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let buildVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        let displayedVersion = buildVersion.map { "\(applicationVersion) (\($0))" } ?? applicationVersion

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Video Editor",
            .applicationVersion: displayedVersion,
            .credits: NSAttributedString(
                string: text(
                    "Внутренний движок FFmpeg\nБезопасные обновления через Sparkle 2\n\nВходные форматы:\n.mov, .mp4, .m4v, .mkv, .avi, .webm, .mpg, .mpeg, .ts, .mts, .m2ts, .vob, .3gp, .flv, .wmv, .ogv\n\nВыходные форматы:\n.mp4, .mov, .mkv\n\nМинимальная версия: macOS 13 Ventura.\nПоддерживаются macOS 13, 14, 15 и 26.",
                    "Internal FFmpeg engine\nSecure updates via Sparkle 2\n\nInput formats:\n.mov, .mp4, .m4v, .mkv, .avi, .webm, .mpg, .mpeg, .ts, .mts, .m2ts, .vob, .3gp, .flv, .wmv, .ogv\n\nOutput formats:\n.mp4, .mov, .mkv\n\nMinimum version: macOS 13 Ventura.\nmacOS 13, 14, 15, and 26 are supported."
                )
            )
        ])
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    @objc private func quitApplication(_ sender: Any?) {
        if process?.isRunning == true {
            let alert = NSAlert()
            alert.messageText = text("Остановить текущую операцию?", "Stop the current operation?")
            alert.informativeText = text("Незавершённый файл будет удалён.", "The incomplete output file will be deleted.")
            alert.addButton(withTitle: text("Остановить и выйти", "Stop and quit"))
            alert.addButton(withTitle: text("Продолжить работу", "Keep working"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            process?.interrupt()
        }
        NSApp.terminate(nil)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard process?.isRunning != true else { return }
        let editing = mode == .cut || mode == .join
        let joining = mode == .join
        profileRow.isHidden = editing
        row(withIdentifier: "cpuRow")?.isHidden = mode == .cut
        joinStack.isHidden = !joining
        cutRow.isHidden = !editing
        previewStack.isHidden = !editing
        browseButton.title = joining ? text("Добавить…", "Add…") : text("Обзор…", "Browse…")
        resourceLabel.isHidden = true
        sizeLabel.isHidden = true
        progressBar.doubleValue = 0
        percentLabel.stringValue = "0%"
        detailLabel.stringValue = ""
        resizeWindow(for: mode)

        if joining {
            analysisToken = UUID()
            if joinClips.isEmpty, let selectedInputURL {
                addJoinURLs([selectedInputURL])
            } else if !joinClips.isEmpty {
                let row = joinTable.selectedRow >= 0 ? joinTable.selectedRow : 0
                joinTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                prepareJoinPreview(at: row)
            } else {
                clearPreview()
                fileField.stringValue = text("Ролики не выбраны", "No clips selected")
                statusLabel.stringValue = text("Добавьте минимум два ролика", "Add at least two clips")
                startButton.isEnabled = false
            }
            return
        }

        guard let selectedInputURL else {
            statusLabel.stringValue = text("Выберите файл", "Select a file")
            startButton.isEnabled = false
            return
        }

        if mode == .cut {
            analysisToken = UUID()
            preparePreview(for: selectedInputURL)
        } else {
            previewToken = UUID()
            removePlayerTimeObserver()
            playerView.player?.pause()
            if let sourceInfo {
                applyAvailableProfiles(for: sourceInfo)
            } else {
                analyzeInput(selectedInputURL)
            }
        }
    }

    private func resizeWindow(for mode: EditorMode, animated: Bool = true) {
        let desiredHeight: CGFloat
        let targetMinSize: NSSize
        switch mode {
        case .compress:
            desiredHeight = 470
            targetMinSize = NSSize(width: 600, height: 420)
            playerHeightConstraint.constant = 240
        case .cut:
            desiredHeight = 760
            targetMinSize = NSSize(width: 620, height: 500)
            playerHeightConstraint.constant = 240
        case .join:
            desiredHeight = 790
            targetMinSize = NSSize(width: 620, height: 500)
            playerHeightConstraint.constant = 170
        }

        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame
        let availableHeight = visibleFrame.map { max(420, $0.height - 16) } ?? desiredHeight
        let availableWidth = visibleFrame.map { max(500, $0.width - 16) } ?? window.frame.width
        let targetHeight = min(desiredHeight, availableHeight)
        let targetWidth = min(max(window.frame.width, targetMinSize.width), availableWidth)
        window.minSize = NSSize(
            width: min(targetMinSize.width, targetWidth),
            height: min(targetMinSize.height, targetHeight)
        )

        var frame = window.frame
        let oldTop = min(frame.maxY, visibleFrame?.maxY ?? frame.maxY)
        frame.size.height = targetHeight
        frame.size.width = targetWidth
        frame.origin.y = oldTop - targetHeight
        if let visibleFrame {
            frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
            if frame.minY < visibleFrame.minY {
                frame.origin.y = visibleFrame.minY
            }
        }
        window.setFrame(frame, display: true, animate: animated)
    }

    private func row(withIdentifier identifier: String) -> NSView? {
        window.contentView?.subviews
            .flatMap { descendants(of: $0) }
            .first { $0.identifier?.rawValue == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    @objc private func openFile(_ sender: Any?) {
        guard process?.isRunning != true else {
            NSSound.beep()
            return
        }

        let panel = NSOpenPanel()
        panel.title = mode == .join ? text("Выберите ролики", "Select clips") : text("Выберите файл", "Select a file")
        panel.prompt = mode == .join ? text("Добавить", "Add") : text("Открыть", "Open")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = mode == .join
        let inputExtensions = mode == .cut
            ? videoInputExtensions + audioInputExtensions
            : videoInputExtensions
        panel.allowedContentTypes = contentTypes(for: inputExtensions)
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK else { return }
        if mode == .join {
            addJoinURLs(panel.urls)
        } else if let url = panel.url {
            selectInput(url)
        }
    }

    @objc private func addJoinClips(_ sender: Any?) {
        openFile(sender)
    }

    private func addJoinURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        statusLabel.stringValue = text("Анализирую ролики", "Analyzing clips")
        detailLabel.stringValue = text("Добавляется: \(urls.count)", "Adding: \(urls.count)")
        startButton.isEnabled = false
        let token = UUID()
        analysisToken = token

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let clips = urls.compactMap { url -> JoinClip? in
                guard let info = self.probeSource(url), info.duration > 0 else { return nil }
                return JoinClip(
                    id: UUID(),
                    url: url,
                    info: info,
                    lowerValue: 0,
                    upperValue: info.duration,
                    thumbnails: []
                )
            }
            DispatchQueue.main.async {
                guard self.analysisToken == token, self.mode == .join else { return }
                let firstNewRow = self.joinClips.count
                self.joinClips.append(contentsOf: clips)
                self.joinTable.reloadData()
                self.updateJoinFileSummary()
                guard !clips.isEmpty else {
                    self.statusLabel.stringValue = self.text("Видео не найдено", "No video found")
                    self.detailLabel.stringValue = self.text("Выбранные файлы не содержат видеодорожку", "The selected files do not contain a video track")
                    self.updateStartButtonAvailability()
                    return
                }
                self.joinTable.selectRowIndexes(IndexSet(integer: firstNewRow), byExtendingSelection: false)
                self.prepareJoinPreview(at: firstNewRow)
            }
        }
    }

    private func updateJoinFileSummary() {
        if joinClips.isEmpty {
            fileField.stringValue = text("Ролики не выбраны", "No clips selected")
            fileField.toolTip = nil
            selectedInputURL = nil
        } else {
            fileField.stringValue = text("Выбрано роликов: \(joinClips.count)", "Selected clips: \(joinClips.count)")
            fileField.toolTip = joinClips.map { $0.url.lastPathComponent }.joined(separator: "\n")
            selectedInputURL = joinClips.first?.url
            window.representedURL = joinClips.first?.url
        }
        updateStartButtonAvailability()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        joinClips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard joinClips.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("joinClipCell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = identifier
            field.lineBreakMode = .byTruncatingMiddle
            field.font = .systemFont(ofSize: 13)
        }
        let clip = joinClips[row]
        field.stringValue = "\(row + 1).  \(clip.url.lastPathComponent)    \(formatEditorTime(clip.lowerValue))–\(formatEditorTime(clip.upperValue))"
        field.toolTip = clip.url.path
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard mode == .join, joinClips.indices.contains(joinTable.selectedRow) else { return }
        prepareJoinPreview(at: joinTable.selectedRow)
    }

    @objc private func joinSelectionChanged(_ sender: NSTableView) {
        guard joinClips.indices.contains(sender.selectedRow) else { return }
        prepareJoinPreview(at: sender.selectedRow)
    }

    @objc private func removeJoinClip(_ sender: Any?) {
        guard process?.isRunning != true else { return }
        let row = joinTable.selectedRow
        guard joinClips.indices.contains(row) else { return }
        joinClips.remove(at: row)
        joinTable.reloadData()
        updateJoinFileSummary()
        guard !joinClips.isEmpty else {
            clearPreview()
            statusLabel.stringValue = text("Добавьте минимум два ролика", "Add at least two clips")
            return
        }
        let nextRow = min(row, joinClips.count - 1)
        joinTable.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        prepareJoinPreview(at: nextRow)
    }

    @objc private func moveJoinClipUp(_ sender: Any?) {
        moveJoinClip(by: -1)
    }

    @objc private func moveJoinClipDown(_ sender: Any?) {
        moveJoinClip(by: 1)
    }

    private func moveJoinClip(by offset: Int) {
        guard process?.isRunning != true else { return }
        let source = joinTable.selectedRow
        let destination = source + offset
        guard joinClips.indices.contains(source), joinClips.indices.contains(destination) else { return }
        joinClips.swapAt(source, destination)
        joinTable.reloadData()
        joinTable.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        updateJoinFileSummary()
    }

    private func clearPreview() {
        previewToken = UUID()
        removePlayerTimeObserver()
        playerView.player?.pause()
        playerView.player = nil
        timelineView.thumbnails = []
        timelineView.isEnabled = false
        startField.stringValue = ""
        endField.stringValue = ""
        selectionLabel.stringValue = ""
    }

    private func selectInput(_ url: URL) {
        analysisToken = UUID()
        sourceInfo = nil
        hdrRadio.state = .off
        sdrRadio.state = .on
        hdrRadio.isEnabled = false
        sdrRadio.isEnabled = false
        selectedInputURL = url
        fileField.stringValue = url.path
        fileField.toolTip = url.path
        statusLabel.stringValue = mode == .compress
            ? text("Анализ качества", "Analyzing quality")
            : text("Загрузка видео", "Loading video")
        detailLabel.stringValue = ""
        resourceLabel.isHidden = true
        sizeLabel.isHidden = true
        progressBar.doubleValue = 0
        percentLabel.stringValue = "0%"
        revealButton.isHidden = true
        startButton.isEnabled = false
        window.representedURL = url

        if mode == .compress {
            analyzeInput(url)
        } else {
            preparePreview(for: url)
        }
    }

    private func analyzeInput(_ url: URL) {
        let token = UUID()
        analysisToken = token
        if availableProfiles.indices.contains(profilePopup.indexOfSelectedItem) {
            preferredProfileID = availableProfiles[profilePopup.indexOfSelectedItem].id
        }
        statusLabel.stringValue = text("Анализ качества", "Analyzing quality")
        detailLabel.stringValue = ""
        startButton.isEnabled = false
        profilePopup.isEnabled = false
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: text("Анализирую файл…", "Analyzing file…"))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let info = self.probeSource(url)
            DispatchQueue.main.async {
                guard self.analysisToken == token, self.selectedInputURL == url else { return }
                self.sourceInfo = info
                if let info {
                    if self.mode == .compress {
                        self.applyAvailableProfiles(for: info)
                    }
                } else {
                    self.availableProfiles = []
                    self.profilePopup.removeAllItems()
                    self.profilePopup.addItem(withTitle: self.text("Нет видеодорожки", "No video track"))
                    self.profilePopup.isEnabled = false
                    self.startButton.isEnabled = false
                    self.statusLabel.stringValue = self.text("Видео не найдено", "No video found")
                    self.detailLabel.stringValue = self.text("Для сжатия нужен файл с видеодорожкой", "Compression requires a file with a video track")
                }
            }
        }
    }

    private func probeSource(_ url: URL) -> SourceInfo? {
        guard let ffprobe = locateTool(named: "ffprobe") else { return nil }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = ffprobe
        task.arguments = [
            "-v", "error",
            "-show_entries", "stream=codec_type,codec_name,width,height,pix_fmt,color_transfer,avg_frame_rate,bit_rate:stream_side_data=rotation:format=bit_rate,duration",
            "-of", "json",
            url.path
        ]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]],
              let video = streams.first(where: { stringValue($0["codec_type"]) == "video" }) else { return nil }

        let format = root["format"] as? [String: Any] ?? [:]
        let codedWidth = intValue(video["width"])
        let codedHeight = intValue(video["height"])
        guard codedWidth > 0, codedHeight > 0 else { return nil }
        let sideData = video["side_data_list"] as? [[String: Any]] ?? []
        let rotation = sideData.lazy.map { self.intValue($0["rotation"]) }.first { $0 != 0 } ?? 0
        let isQuarterTurn = abs(rotation) == 90 || abs(rotation) == 270
        let width = isQuarterTurn ? codedHeight : codedWidth
        let height = isQuarterTurn ? codedWidth : codedHeight

        let streamBitrate = doubleValue(video["bit_rate"])
        let formatBitrate = doubleValue(format["bit_rate"])
        return SourceInfo(
            width: width,
            height: height,
            fps: parseFrameRate(stringValue(video["avg_frame_rate"])),
            videoBitrate: (streamBitrate > 0 ? streamBitrate : formatBitrate) / 1_000_000,
            codec: stringValue(video["codec_name"]),
            pixelFormat: stringValue(video["pix_fmt"]),
            colorTransfer: stringValue(video["color_transfer"]),
            duration: doubleValue(format["duration"])
        )
    }

    private func applyAvailableProfiles(for info: SourceInfo) {
        let supportsHDRChoice = info.isHDR || info.isHighBitDepth
        if supportsHDRChoice && !hdrRadio.isEnabled {
            hdrRadio.state = .on
            sdrRadio.state = .off
        } else if !supportsHDRChoice {
            hdrRadio.state = .off
            sdrRadio.state = .on
        }
        hdrRadio.isEnabled = supportsHDRChoice && process?.isRunning != true
        sdrRadio.isEnabled = supportsHDRChoice && process?.isRunning != true
        availableProfiles = compressionProfiles(for: info)

        profilePopup.removeAllItems()
        guard !availableProfiles.isEmpty else {
            profilePopup.addItem(withTitle: text("Нет подходящих профилей", "No suitable profiles"))
            profilePopup.isEnabled = false
            startButton.isEnabled = false
            statusLabel.stringValue = text("Нет подходящего профиля", "No suitable profile")
            detailLabel.stringValue = text("Разрешение или битрейт исходника ниже минимальных требований", "The source resolution or bitrate is below the minimum requirements")
            return
        }

        profilePopup.addItems(withTitles: availableProfiles.map(profileTitle))
        let selectedIndex = availableProfiles.firstIndex(where: { $0.id == preferredProfileID }) ?? (availableProfiles.count - 1)
        profilePopup.selectItem(at: selectedIndex)
        preferredProfileID = availableProfiles[selectedIndex].id
        profilePopup.isEnabled = process?.isRunning != true
        startButton.isEnabled = true
        statusLabel.stringValue = text("Готов к запуску", "Ready")
        detailLabel.stringValue = String(
            format: text(
                "%dx%d   •   %.3f fps   •   %@   •   %.3f Мбит/с   •   профилей: %d",
                "%dx%d   •   %.3f fps   •   %@   •   %.3f Mbps   •   profiles: %d"
            ),
            info.width, info.height, info.fps, info.codec, info.videoBitrate, availableProfiles.count
        )
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        guard availableProfiles.indices.contains(sender.indexOfSelectedItem) else { return }
        preferredProfileID = availableProfiles[sender.indexOfSelectedItem].id
    }

    @objc private func hdrModeChanged(_ sender: NSButton) {
        let preserveHDR = sender === hdrRadio
        hdrRadio.state = preserveHDR ? .on : .off
        sdrRadio.state = preserveHDR ? .off : .on
        guard let sourceInfo else { return }
        applyAvailableProfiles(for: sourceInfo)
    }

    private func compressionProfiles(for info: SourceInfo) -> [CompressionProfile] {
        profiles.filter { isProfileAvailable($0, for: info) }
    }

    private func isProfileAvailable(_ profile: CompressionProfile, for info: SourceInfo) -> Bool {
        info.shortSide >= profile.targetShortSide
    }

    private func locateTool(named name: String) -> URL? {
        let paths = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map(URL.init(fileURLWithPath:))
    }

    private func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private func intValue(_ value: Any?) -> Int {
        Int(stringValue(value)) ?? 0
    }

    private func doubleValue(_ value: Any?) -> Double {
        Double(stringValue(value)) ?? 0
    }

    private func parseFrameRate(_ raw: String) -> Double {
        let parts = raw.split(separator: "/").compactMap { Double($0) }
        if parts.count == 2, parts[1] > 0 { return parts[0] / parts[1] }
        return parts.first ?? 30
    }

    private func preparePreview(for url: URL) {
        let token = UUID()
        previewToken = token
        removePlayerTimeObserver()

        let player = AVPlayer(url: url)
        playerView.player = player
        timelineView.thumbnails = []
        timelineView.isEnabled = false
        selectionLabel.stringValue = ""
        statusLabel.stringValue = text("Загрузка видео", "Loading video")
        detailLabel.stringValue = ""
        startButton.isEnabled = false

        let asset = AVURLAsset(url: url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let probedInfo = self.probeSource(url)
            let duration = probedInfo?.duration ?? asset.duration.seconds
            guard duration.isFinite, duration > 0 else {
                DispatchQueue.main.async {
                    guard self.previewToken == token else { return }
                    self.statusLabel.stringValue = self.text("Не удалось открыть видео", "Could not open video")
                    self.startButton.isEnabled = false
                }
                return
            }

            DispatchQueue.main.async {
                guard self.previewToken == token, self.selectedInputURL == url, self.mode == .cut else { return }
                self.sourceInfo = probedInfo
                self.timelineView.duration = duration
                self.timelineView.lowerValue = 0
                self.timelineView.upperValue = duration
                self.timelineView.isEnabled = true
                self.startField.stringValue = self.formatEditorTime(0)
                self.endField.stringValue = self.formatEditorTime(duration)
                self.updateSelectionLabel()
                self.statusLabel.stringValue = self.text("Готов к вырезанию", "Ready to cut")
                self.detailLabel.stringValue = self.text(
                    "Длительность \(self.formatEditorTime(duration))",
                    "Duration \(self.formatEditorTime(duration))"
                )
                self.startButton.isEnabled = true
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                self.playerTimeObserver = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                    queue: .main
                ) { [weak self, weak player] time in
                    guard let self, let player, player.rate > 0 else { return }
                    if time.seconds >= self.timelineView.upperValue {
                        player.pause()
                        player.seek(to: CMTime(seconds: self.timelineView.lowerValue, preferredTimescale: 600))
                    }
                }
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            var images: [NSImage] = []
            for index in 0..<10 {
                let seconds = duration * (Double(index) + 0.5) / 10
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                    images.append(NSImage(
                        cgImage: image,
                        size: NSSize(width: image.width, height: image.height)
                    ))
                }
            }
            DispatchQueue.main.async {
                guard self.previewToken == token, self.selectedInputURL == url else { return }
                self.timelineView.thumbnails = images
            }
        }
    }

    private func prepareJoinPreview(at index: Int) {
        guard joinClips.indices.contains(index) else { return }
        let clip = joinClips[index]
        let token = UUID()
        previewToken = token
        removePlayerTimeObserver()

        let player = AVPlayer(url: clip.url)
        playerView.player = player
        timelineView.duration = clip.info.duration
        timelineView.lowerValue = clip.lowerValue
        timelineView.upperValue = clip.upperValue
        timelineView.thumbnails = clip.thumbnails
        timelineView.isEnabled = process?.isRunning != true
        startField.stringValue = formatEditorTime(clip.lowerValue)
        endField.stringValue = formatEditorTime(clip.upperValue)
        updateSelectionLabel()
        statusLabel.stringValue = joinClips.count >= 2
            ? text("Готов к склейке", "Ready to join")
            : text("Добавьте ещё один ролик", "Add one more clip")
        detailLabel.stringValue = text(
            "Ролик \(index + 1) из \(joinClips.count)   •   \(clip.info.width)x\(clip.info.height)",
            "Clip \(index + 1) of \(joinClips.count)   •   \(clip.info.width)x\(clip.info.height)"
        )
        updateStartButtonAvailability()
        player.seek(
            to: CMTime(seconds: clip.lowerValue, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        playerTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, let player, player.rate > 0 else { return }
            if time.seconds >= self.timelineView.upperValue {
                player.pause()
                player.seek(to: CMTime(seconds: self.timelineView.lowerValue, preferredTimescale: 600))
            }
        }

        guard clip.thumbnails.isEmpty else { return }
        let asset = AVURLAsset(url: clip.url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = .positiveInfinity
            generator.requestedTimeToleranceAfter = .positiveInfinity
            var images: [NSImage] = []
            for thumbnailIndex in 0..<10 {
                let seconds = clip.info.duration * (Double(thumbnailIndex) + 0.5) / 10
                let time = CMTime(seconds: seconds, preferredTimescale: 600)
                if let image = try? generator.copyCGImage(at: time, actualTime: nil) {
                    images.append(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                }
            }
            DispatchQueue.main.async {
                guard self.previewToken == token,
                      let currentIndex = self.joinClips.firstIndex(where: { $0.id == clip.id }) else { return }
                self.joinClips[currentIndex].thumbnails = images
                if self.joinTable.selectedRow == currentIndex {
                    self.timelineView.thumbnails = images
                }
            }
        }
    }

    private func removePlayerTimeObserver() {
        if let playerTimeObserver, let player = playerView.player {
            player.removeTimeObserver(playerTimeObserver)
        }
        playerTimeObserver = nil
    }

    private func timelineChanged(lower: Double, upper: Double, previewTime: Double) {
        startField.stringValue = formatEditorTime(lower)
        endField.stringValue = formatEditorTime(upper)
        persistJoinRangeIfNeeded(lower: lower, upper: upper)
        updateSelectionLabel()
        playerView.player?.seek(
            to: CMTime(seconds: previewTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        updateStartButtonAvailability()
    }

    @objc private func timeFieldsChanged(_ sender: NSTextField) {
        applyTimeFields(seekToStart: sender === startField)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === startField || field === endField else { return }
        applyTimeFields(seekToStart: field === startField)
    }

    private func applyTimeFields(seekToStart: Bool) {
        guard let lower = parseTime(startField.stringValue),
              let upper = parseTime(endField.stringValue),
              lower >= 0,
              upper > lower,
              upper <= timelineView.duration else {
            NSSound.beep()
            return
        }
        timelineView.lowerValue = lower
        timelineView.upperValue = upper
        persistJoinRangeIfNeeded(lower: lower, upper: upper)
        updateSelectionLabel()
        updateStartButtonAvailability()
        let previewTime = seekToStart ? lower : upper
        playerView.player?.seek(to: CMTime(seconds: previewTime, preferredTimescale: 600))
    }

    private func updateSelectionLabel() {
        let length = max(0, timelineView.upperValue - timelineView.lowerValue)
        if mode == .join, joinClips.indices.contains(joinTable.selectedRow) {
            selectionLabel.stringValue = text(
                "Ролик \(joinTable.selectedRow + 1)   •   фрагмент: \(formatEditorTime(length))",
                "Clip \(joinTable.selectedRow + 1)   •   selection: \(formatEditorTime(length))"
            )
        } else {
            selectionLabel.stringValue = text("Фрагмент: \(formatEditorTime(length))", "Selection: \(formatEditorTime(length))")
        }
    }

    private func persistJoinRangeIfNeeded(lower: Double, upper: Double) {
        guard mode == .join, joinClips.indices.contains(joinTable.selectedRow) else { return }
        let row = joinTable.selectedRow
        joinClips[row].lowerValue = lower
        joinClips[row].upperValue = upper
        joinTable.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func formatEditorTime(_ value: Double) -> String {
        let safe = max(0, value)
        let hours = Int(safe / 3600)
        let minutes = Int(safe.truncatingRemainder(dividingBy: 3600) / 60)
        let seconds = safe.truncatingRemainder(dividingBy: 60)
        if hours > 0 {
            return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
        }
        return String(format: "%02d:%06.3f", minutes, seconds)
    }

    @objc private func startWork(_ sender: Any?) {
        guard let inputURL = mode == .join ? joinClips.first?.url : selectedInputURL else {
            showError(
                title: text("Файл не выбран", "No file selected"),
                message: text("Сначала выберите исходный файл.", "Select a source file first.")
            )
            return
        }

        if mode == .cut {
            guard let start = parseTime(startField.stringValue),
                  let end = parseTime(endField.stringValue),
                  end > start,
                  end <= timelineView.duration else {
                showError(
                    title: text("Проверьте время", "Check the time range"),
                    message: text(
                        "Укажите старт и конец, например 1:30 и 1:50. Конец должен быть позже старта.",
                        "Enter a start and end time, for example 1:30 and 1:50. The end must be later than the start."
                    )
                )
                return
            }
        } else if mode == .join {
            guard joinClips.count >= 2 else {
                showError(
                    title: text("Недостаточно роликов", "Not enough clips"),
                    message: text("Для склейки добавьте минимум два ролика.", "Add at least two clips to join them.")
                )
                return
            }
        }

        let savePanel = NSSavePanel()
        savePanel.directoryURL = inputURL.deletingLastPathComponent()
        savePanel.canCreateDirectories = true
        savePanel.prompt = text("Сохранить", "Save")
        savePanel.allowsOtherFileTypes = false

        let stem = inputURL.deletingPathExtension().lastPathComponent
        switch mode {
        case .compress:
            guard availableProfiles.indices.contains(profilePopup.indexOfSelectedItem) else {
                showError(
                    title: text("Профиль недоступен", "Profile unavailable"),
                    message: text("Выберите другой видеофайл.", "Select a different video file.")
                )
                return
            }
            let profile = availableProfiles[profilePopup.indexOfSelectedItem]
            savePanel.title = text("Куда сохранить сжатое видео", "Save compressed video")
            savePanel.nameFieldStringValue = "\(stem).\(profile.suffix).mp4"
            savePanel.allowedContentTypes = contentTypes(for: compressedOutputExtensions)
        case .cut:
            let ext = inputURL.pathExtension.isEmpty ? "mkv" : inputURL.pathExtension
            savePanel.title = text("Куда сохранить фрагмент", "Save clip")
            savePanel.nameFieldStringValue = "\(stem).cut.\(ext)"
            savePanel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .audiovisualContent]
        case .join:
            savePanel.title = text("Куда сохранить склеенное видео", "Save joined video")
            savePanel.nameFieldStringValue = "\(stem).joined.mp4"
            savePanel.allowedContentTypes = contentTypes(for: compressedOutputExtensions)
        }

        guard savePanel.runModal() == .OK, var outputURL = savePanel.url else { return }
        pendingCompressionProfile = nil

        if mode == .cut || mode == .join {
            let candidates: [CompressionProfile]
            if mode == .cut, let sourceInfo {
                candidates = compressionProfiles(for: sourceInfo)
            } else if mode == .join {
                candidates = profiles.filter { profile in
                    joinClips.allSatisfy { isProfileAvailable(profile, for: $0.info) }
                }
            } else {
                candidates = []
            }

            switch askCompressionChoice(from: candidates) {
            case .cancelled:
                return
            case .original:
                break
            case .profile(let profile):
                pendingCompressionProfile = profile
                if !compressedOutputExtensions.contains(outputURL.pathExtension.lowercased()) {
                    outputURL = outputURL.deletingPathExtension().appendingPathExtension("mp4")
                }
            }
        }

        if mode == .compress || mode == .join,
           !compressedOutputExtensions.contains(outputURL.pathExtension.lowercased()) {
            outputURL = outputURL.deletingPathExtension().appendingPathExtension("mp4")
        }

        beginProcess(inputURL: inputURL, outputURL: outputURL)
    }

    private func askCompressionChoice(from candidates: [CompressionProfile]) -> CompressionChoice {
        let alert = NSAlert()
        alert.messageText = text("Сжать результат?", "Compress the result?")
        alert.informativeText = candidates.isEmpty
            ? text("Для качества исходника нет подходящих профилей. Можно сохранить без дополнительного сжатия.", "No compression profile is suitable for this source. You can save without additional compression.")
            : text("Выберите профиль или сохраните результат без дополнительного сжатия.", "Choose a profile or save without additional compression.")
        alert.addButton(withTitle: text("Продолжить", "Continue"))
        alert.addButton(withTitle: text("Отмена", "Cancel"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 30), pullsDown: false)
        popup.addItem(withTitle: text("Без дополнительного сжатия", "Without additional compression"))
        popup.addItems(withTitles: candidates.map(profileTitle))
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return .cancelled }
        let selectedIndex = popup.indexOfSelectedItem
        guard selectedIndex > 0, candidates.indices.contains(selectedIndex - 1) else { return .original }
        return .profile(candidates[selectedIndex - 1])
    }

    private func beginProcess(inputURL: URL, outputURL: URL) {
        guard let executable = locateVideoEngine() else {
            showError(
                title: text("Внутренний движок не найден", "Internal engine not found"),
                message: text(
                    "Переустановите приложение: необходимый компонент отсутствует внутри Video Editor.app.",
                    "Reinstall the application. A required component is missing from Video Editor.app."
                )
            )
            return
        }

        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        var arguments: [String]

        switch mode {
        case .compress:
            guard availableProfiles.indices.contains(profilePopup.indexOfSelectedItem) else { return }
            let profile = availableProfiles[profilePopup.indexOfSelectedItem]
            arguments = ["compress", profile.id]
            if let sourceInfo, sourceInfo.isHDR || sourceInfo.isHighBitDepth {
                arguments.append(hdrRadio.state == .on ? "--preserve-hdr" : "--convert-sdr")
            }
            if cpuCheckbox.state == .on {
                arguments.append("--no-gpu")
            }
            arguments += ["-f", inputURL.path]
        case .cut:
            if let profile = pendingCompressionProfile {
                arguments = ["compress", profile.id, "-s", startField.stringValue, "-e", endField.stringValue]
                if let sourceInfo, sourceInfo.isHDR || sourceInfo.isHighBitDepth {
                    arguments.append(hdrRadio.state == .on ? "--preserve-hdr" : "--convert-sdr")
                }
            } else {
                arguments = ["cut", "-s", startField.stringValue, "-e", endField.stringValue]
            }
            arguments += ["-f", inputURL.path]
        case .join:
            guard joinClips.count >= 2 else { return }
            let invalidPath = joinClips.first { $0.url.path.contains("\t") || $0.url.path.contains("\n") }
            guard invalidPath == nil else {
                showError(
                    title: text("Неподдерживаемое имя файла", "Unsupported file name"),
                    message: text("В имени ролика не должно быть табуляции или переноса строки.", "A clip name must not contain tabs or line breaks.")
                )
                return
            }
            let manifest = joinClips.map {
                "\($0.url.path)\t\(formatManifestTime($0.lowerValue))\t\(formatManifestTime($0.upperValue))"
            }.joined(separator: "\n") + "\n"
            let manifestURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("video-editor-join-\(UUID().uuidString).tsv")
            do {
                try manifest.data(using: .utf8)?.write(to: manifestURL, options: .atomic)
            } catch {
                showError(title: text("Не удалось подготовить склейку", "Could not prepare joining"), message: error.localizedDescription)
                return
            }
            processManifestURL = manifestURL
            arguments = ["join", "--manifest", manifestURL.path]
            if let profile = pendingCompressionProfile {
                arguments += ["--profile", profile.id]
            }
            if cpuCheckbox.state == .on {
                arguments.append("--no-gpu")
            }
        }
        arguments += [
            "--plain-progress",
            "-o", outputURL.path,
            "-y"
        ]

        task.executableURL = executable
        task.arguments = arguments
        task.currentDirectoryURL = inputURL.deletingLastPathComponent()
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = "en_US.UTF-8"
        task.environment = environment

        selectedOutputURL = outputURL
        process = task
        stdoutPipe = outputPipe
        stderrPipe = errorPipe
        stdoutBuffer = ""
        stderrBuffer = ""
        diagnosticOutput = ""
        wasCancelled = false
        playerView.player?.pause()
        setRunning(true)
        technicalValues.removeAll()
        technicalLabel.stringValue = ""
        technicalLabel.isHidden = true

        switch mode {
        case .compress:
            statusLabel.stringValue = text("Готовлю сжатие", "Preparing compression")
        case .cut:
            statusLabel.stringValue = pendingCompressionProfile == nil
                ? text("Готовлю вырезание", "Preparing cut")
                : text("Готовлю вырезание и сжатие", "Preparing cut and compression")
        case .join:
            statusLabel.stringValue = text("Готовлю склейку", "Preparing join")
        }
        detailLabel.stringValue = ""
        resourceLabel.stringValue = ""
        resourceLabel.isHidden = mode == .cut && pendingCompressionProfile == nil
        sizeLabel.stringValue = ""
        sizeLabel.isHidden = true
        progressBar.doubleValue = 0
        percentLabel.stringValue = "0%"

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.consume(text: text, isError: false)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self?.consume(text: text, isError: true)
            }
        }

        task.terminationHandler = { [weak self] finishedTask in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.finishProcess(exitCode: finishedTask.terminationStatus)
            }
        }

        do {
            try task.run()
        } catch {
            setRunning(false)
            process = nil
            removeProcessManifest()
            showError(title: text("Не удалось запустить", "Could not start"), message: error.localizedDescription)
        }
    }

    private func formatManifestTime(_ value: Double) -> String {
        String(format: "%.6f", max(0, value))
    }

    private func locateVideoEngine() -> URL? {
        guard let path = Bundle.main.path(forResource: "video_engine", ofType: nil),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func consume(text: String, isError: Bool) {
        if isError {
            diagnosticOutput += text
            if diagnosticOutput.count > 16_000 {
                diagnosticOutput = String(diagnosticOutput.suffix(16_000))
            }
            stderrBuffer += text
            extractLines(from: &stderrBuffer, isError: true)
        } else {
            diagnosticOutput += text
            if diagnosticOutput.count > 16_000 {
                diagnosticOutput = String(diagnosticOutput.suffix(16_000))
            }
            stdoutBuffer += text
            extractLines(from: &stdoutBuffer, isError: false)
        }
    }

    private func extractLines(from buffer: inout String, isError: Bool) {
        let parts = buffer.components(separatedBy: .newlines)
        buffer = parts.last ?? ""
        for part in parts.dropLast() {
            processLine(part, isError: isError)
        }
    }

    private func processLine(_ rawLine: String, isError: Bool) {
        let line = rawLine
            .replacingOccurrences(
                of: "\u{001B}\\[[0-9;?]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        if line.hasPrefix("Ресурсы:") {
            resourceLabel.stringValue = localizedEngineText(
                line.replacingOccurrences(of: "Ресурсы:", with: "").trimmingCharacters(in: .whitespaces)
            )
            resourceLabel.isHidden = false
            return
        }

        let technicalKeys = ["Профиль", "Исходник", "Разрешение", "Видео", "Аудио", "Ускорение", "Режим"]
        if let key = technicalKeys.first(where: { line.hasPrefix("\($0):") }) {
            technicalValues[key] = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            updateTechnicalDetails()
            return
        }

        if let percentText = capture(#"\]\s*(\d+)%"#, in: line),
           let percent = Double(percentText) {
            progressBar.doubleValue = percent
            percentLabel.stringValue = "\(Int(percent))%"
            switch mode {
            case .compress:
                statusLabel.stringValue = text("Сжимаю видео", "Compressing video")
            case .cut:
                statusLabel.stringValue = pendingCompressionProfile == nil
                    ? text("Вырезаю фрагмент", "Cutting clip")
                    : text("Вырезаю и сжимаю", "Cutting and compressing")
            case .join:
                statusLabel.stringValue = pendingCompressionProfile == nil
                    ? text("Склеиваю ролики", "Joining clips")
                    : text("Склеиваю и сжимаю", "Joining and compressing")
            }

            var details: [String] = []
            if let elapsed = capture(#"прошло\s+([^|]+)"#, in: line) {
                details.append(text("Прошло ", "Elapsed ") + elapsed.trimmingCharacters(in: .whitespaces))
            }
            if let remaining = capture(#"осталось\s+([^|]+)"#, in: line) {
                details.append(text("Осталось ", "Remaining ") + remaining.trimmingCharacters(in: .whitespaces))
            }
            if let speed = capture(#"\|\s*([0-9.eE+-]+x)(?:\s*\||$)"#, in: line) {
                details.append(text("Скорость ", "Speed ") + speed)
            }
            detailLabel.stringValue = details.joined(separator: "   •   ")

            if let sizes = capture(#"Исходники\s+(.+?)\s+\|\s+создано\s+(.+?)\s+\|\s+итог\s+~(.+)$"#, in: line, group: 0) {
                sizeLabel.stringValue = localizedEngineText(sizes)
                sizeLabel.isHidden = false
            } else if let sizes = capture(#"файл\s+(.+?)\s+->\s+итог\s+~(.+)$"#, in: line, group: 0) {
                sizeLabel.stringValue = localizedEngineText(sizes)
                sizeLabel.isHidden = false
            }
            return
        }

        if line.hasPrefix("Оценка размера:") {
            statusLabel.stringValue = text("Анализирую размер", "Estimating size")
        } else if line.hasPrefix("Прогноз размера:") {
            sizeLabel.stringValue = localizedEngineText(line)
            sizeLabel.isHidden = false
        } else if line.hasPrefix("Пробный VBR:") {
            detailLabel.stringValue = localizedEngineText(line)
        } else if line.hasPrefix("Размеры:") {
            sizeLabel.stringValue = localizedEngineText(
                line.replacingOccurrences(of: "Размеры:", with: "").trimmingCharacters(in: .whitespaces)
            )
            sizeLabel.isHidden = false
        } else if line.hasPrefix("Итоговый размер:") {
            sizeLabel.stringValue = localizedEngineText(line)
            sizeLabel.isHidden = false
        } else if line.hasPrefix("Ошибка:") || isError {
            if statusLabel.stringValue != text("Останавливаю", "Stopping") {
                statusLabel.stringValue = text("Ошибка", "Error")
            }
        }
    }

    private func updateTechnicalDetails() {
        let rows = [
            ["Профиль", "Исходник"],
            ["Разрешение", "Видео"],
            ["Аудио", "Ускорение", "Режим"]
        ].compactMap { keys -> String? in
            let values = keys.compactMap { key -> String? in
                guard let value = technicalValues[key], !value.isEmpty else { return nil }
                let localizedKey: String
                switch key {
                case "Профиль": localizedKey = text("Профиль", "Profile")
                case "Исходник": localizedKey = text("Исходник", "Source")
                case "Разрешение": localizedKey = text("Разрешение", "Resolution")
                case "Видео": localizedKey = text("Видео", "Video")
                case "Аудио": localizedKey = text("Аудио", "Audio")
                case "Ускорение": localizedKey = text("Ускорение", "Acceleration")
                case "Режим": localizedKey = text("Режим", "Mode")
                default: localizedKey = key
                }
                return "\(localizedKey): \(localizedEngineText(value))"
            }
            return values.isEmpty ? nil : values.joined(separator: "   •   ")
        }
        technicalLabel.stringValue = rows.joined(separator: "\n")
        technicalLabel.isHidden = rows.isEmpty
    }

    private func localizedEngineText(_ source: String) -> String {
        guard appLanguage == .en else { return source }
        let replacements = [
            ("Прогноз размера:", "Estimated size:"), ("Пробный VBR:", "VBR test:"),
            ("Итоговый размер:", "Final size:"), ("Оценка размера:", "Estimating size:"),
            ("Мбит/с", "Mbps"), ("кбит/с", "kbps"), ("кГц", "kHz"),
            ("КБ", "KB"), ("МБ", "MB"), ("ГБ", "GB"), ("стерео", "stereo"),
            ("аппаратный медиадвижок", "hardware media engine"),
            ("процессор", "CPU"), ("запись", "write"),
            ("Без повторного кодирования", "No re-encoding"),
            ("Без дополнительного сжатия", "No additional compression"),
            ("Сжатие", "Compression"), ("Вырезание", "Cutting"), ("Склейка", "Joining"),
            ("Исходники", "Sources"), ("исходники", "sources"), ("создано", "created"),
            ("результат", "result"), ("шт.", "items"),
            ("файл", "file"), ("итог", "result")
        ]
        return replacements.reduce(source) { result, replacement in
            result.replacingOccurrences(of: replacement.0, with: replacement.1)
        }
    }

    private func capture(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              group < match.numberOfRanges,
              let swiftRange = Range(match.range(at: group), in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func finishProcess(exitCode: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        removeProcessManifest()
        setRunning(false)
        pendingCompressionProfile = nil

        if wasCancelled {
            statusLabel.stringValue = text("Остановлено", "Stopped")
            detailLabel.stringValue = text("Незавершённый файл удалён", "The incomplete output file was deleted")
            return
        }

        if exitCode == 0 {
            progressBar.doubleValue = 100
            percentLabel.stringValue = "100%"
            statusLabel.stringValue = text("Готово", "Done")
            detailLabel.stringValue = selectedOutputURL?.path ?? ""
            revealButton.isHidden = false
        } else {
            statusLabel.stringValue = text("Ошибка", "Error")
            let message = diagnosticOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            showError(
                title: text("Операция не выполнена", "Operation failed"),
                message: appLanguage == .en
                    ? "The internal engine exited with code \(exitCode). Check the source file and selected settings."
                    : (message.isEmpty ? "Внутренний движок завершился с кодом \(exitCode)." : String(message.suffix(5_000)))
            )
        }
    }

    private func removeProcessManifest() {
        if let processManifestURL {
            try? FileManager.default.removeItem(at: processManifestURL)
        }
        processManifestURL = nil
    }

    private func setRunning(_ running: Bool) {
        modeControl.isEnabled = !running
        browseButton.isEnabled = !running
        profilePopup.isEnabled = !running && !availableProfiles.isEmpty
        let supportsHDRChoice = sourceInfo?.isHDR == true || sourceInfo?.isHighBitDepth == true
        hdrRadio.isEnabled = !running && supportsHDRChoice
        sdrRadio.isEnabled = !running && supportsHDRChoice
        cpuCheckbox.isEnabled = !running
        startField.isEnabled = !running
        endField.isEnabled = !running
        joinTable.isEnabled = !running
        joinEditButtons.forEach { $0.isEnabled = !running }
        timelineView.isEnabled = !running && (mode == .cut || mode == .join) && selectedInputURL != nil
        if running {
            startButton.title = text("Остановить", "Stop")
            startButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: text("Остановить", "Stop"))
            startButton.action = #selector(cancelWork(_:))
            startButton.keyEquivalent = ""
            startButton.isEnabled = true
        } else {
            startButton.title = text("Старт", "Start")
            startButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: text("Старт", "Start"))
            startButton.action = #selector(startWork(_:))
            startButton.keyEquivalent = "\r"
            updateStartButtonAvailability()
        }
        revealButton.isHidden = true
    }

    private func updateStartButtonAvailability() {
        switch mode {
        case .compress:
            guard selectedInputURL != nil else {
                startButton.isEnabled = false
                return
            }
            startButton.isEnabled = !availableProfiles.isEmpty && profilePopup.indexOfSelectedItem >= 0
        case .cut:
            guard selectedInputURL != nil else {
                startButton.isEnabled = false
                return
            }
            startButton.isEnabled = timelineView.isEnabled && timelineView.upperValue > timelineView.lowerValue
        case .join:
            startButton.isEnabled = joinClips.count >= 2 && joinClips.allSatisfy { $0.upperValue > $0.lowerValue }
        }
    }

    @objc private func cancelWork(_ sender: Any?) {
        guard let process, process.isRunning else { return }
        wasCancelled = true
        statusLabel.stringValue = text("Останавливаю", "Stopping")
        startButton.isEnabled = false
        process.interrupt()

        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                process.terminate()
            }
        }
    }

    @objc private func revealOutput(_ sender: Any?) {
        guard let selectedOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([selectedOutputURL])
    }

    private func parseTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ Double($0) != nil }) else { return nil }
        let values = parts.compactMap { Double($0) }
        if values.count == 1 { return values[0] }
        if values.count == 2, values[1] < 60 { return values[0] * 60 + values[1] }
        if values.count == 3, values[1] < 60, values[2] < 60 {
            return values[0] * 3600 + values[1] * 60 + values[2]
        }
        return nil
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private final class UnsupportedSystemDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let language = AppLanguage.initial()
        func text(_ russian: String, _ english: String) -> String {
            language == .ru ? russian : english
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text("Эта версия macOS не поддерживается", "This macOS version is not supported")
        alert.informativeText = text(
            "Минимальная версия: macOS 13 Ventura.\nПоддерживаются macOS 13, 14, 15 и 26.",
            "Minimum version: macOS 13 Ventura.\nmacOS 13, 14, 15, and 26 are supported."
        )
        alert.addButton(withTitle: text("Выйти", "Quit"))
        alert.runModal()
        NSApp.terminate(nil)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let applicationDelegate: NSApplicationDelegate
if #available(macOS 13.0, *) {
    applicationDelegate = AppDelegate()
} else {
    applicationDelegate = UnsupportedSystemDelegate()
}
application.delegate = applicationDelegate
application.run()
