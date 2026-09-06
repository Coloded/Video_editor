// Appended to main.swift by test_editor.py so private model/UI paths can be tested.
@available(macOS 13.0, *)
extension AppDelegate {
    func runRegressionTests(source: URL) {
        configureWindow()
        precondition(formatPopup.itemTitles == ["MP4 (.mp4)", "MOV (.mov)", "MKV (.mkv)"])
        precondition(selectedOutputExtension == "mp4")
        for (index, ext) in ["mp4", "mov", "mkv"].enumerated() {
            formatPopup.selectItem(at: index)
            let panel = NSSavePanel()
            configureVideoSavePanel(panel, stem: "clip.1080p")
            precondition(panel.nameFieldStringValue == "clip.1080p.\(ext)")
            precondition(panel.allowedContentTypes == contentTypes(for: [ext]))
            precondition(!panel.allowsOtherFileTypes && !panel.isExtensionHidden)
            precondition(videoOutputURL(URL(fileURLWithPath: "/tmp/clip.mp4")).pathExtension == ext)
        }
        formatPopup.selectItem(at: 0)
        for bad in ["inf", "nan", "1::30", "1:-30", "-1", "1:60", "999999999999999999999", "1e20", ""] {
            precondition(parseTime(bad) == nil, "Invalid time accepted: \(bad)")
        }
        precondition(parseTime("1:30.125") == 90.125)
        precondition(parseTime("01:02:03,5") == 3723.5)
        precondition(formatEditorTime(.infinity) == "00:00.000")
        guard let info = probeSource(source) else { fatalError("Fixture could not be read") }
        let camera = SourceInfo(width: 1920, height: 1080, fps: 60, videoBitrate: 3,
                                codec: "h264", pixelFormat: "yuv420p", colorTransfer: "bt709", duration: 900, hasAudio: false)
        let compact = compactProfiles.first { $0.targetShortSide == 720 }!
        precondition(isProfileAvailable(compact, for: camera))
        precondition(abs(compact.estimateMB(for: camera, preserveHDR: false) - 79.5375) < 0.01)
        let editor = ProfileEditor(profile: compact, info: camera, sourceMB: 340)
        editor.bitrate.stringValue = "0,5"
        editor.resolution.stringValue = "480"
        editor.audio.selectItem(at: 1)
        editor.changed()
        let custom = editor.result!
        precondition(custom.standardBitrate == 0.5 && custom.targetShortSide == 480 && custom.audioMode == "remove")
        let restored = try! JSONDecoder().decode(CompressionProfile.self, from: JSONEncoder().encode(custom))
        precondition(restored.valid && restored.custom && restored.standardBitrate == 0.5)
        sourceInfo = camera
        precondition(!compressionArguments(restored).contains("--allow-larger"))
        editor.bitrate.stringValue = "nan"; editor.changed()
        precondition(editor.result == nil && !editor.alert.buttons[0].isEnabled)
        editor.resetProfile()
        precondition(editor.result!.targetShortSide == compact.targetShortSide)
        precondition(abs(editor.result!.standardBitrate - compact.standardBitrate) < 0.00001)
        let beforeSize = editor.result!.estimateMB(for: camera, preserveHDR: false)
        editor.resolution.stringValue = "360"; editor.changed()
        precondition(editor.result!.estimateMB(for: camera, preserveHDR: false) < beforeSize)
        editor.resetProfile()
        precondition(editor.automaticBitrate.state == .on)
        precondition(profileNameKey("  TEST  ") == profileNameKey("test"))
        precondition(suggestedProfileName("HD", existing: ["hd — копия", " HD — КОПИЯ 2 "]) == "HD — копия 3")
        var override = compact
        override.custom = true
        customProfiles = [override]
        precondition(compressionProfiles(for: camera).filter { $0.id == compact.id }.count == 1)
        customProfiles = []
        availableProfiles = [compact]
        profilePopup.removeAllItems(); profilePopup.addItem(withTitle: compact.title); profilePopup.selectItem(at: 0)
        processLine("[####] 50% | файл 12 МБ -> итог ~24 МБ", isError: false)
        precondition(sourceSummaryLabel.stringValue.contains("1920×1080"))
        precondition(estimateLabel.stringValue.contains("1280×720"))
        precondition(estimateLabel.stringValue.contains("24 МБ (прогноз)"))
        processLine("Итоговый размер: 340 МБ → 23 МБ · экономия 93%", isError: false)
        precondition(estimateLabel.stringValue.contains("Размер: 23 МБ"))
        processLine("Видео: HEVC, VideoToolbox", isError: false)
        precondition(!technicalLabel.isHidden && !technicalHeading.isHidden && sizeLabel.isHidden)
        var multi = camera
        multi.audioTracks = [CompressionAudioTrack(index: 1, title: "Russian", bitrate: 640000), CompressionAudioTrack(index: 2, title: "English", bitrate: 448000)]
        sourceInfo = multi
        refreshCompressionAudio()
        let audioButton = audioTracksList.arrangedSubviews[0] as! NSButton
        audioButton.state = .off; changeCompressionAudio(audioButton)
        precondition(excludedAudioTracks == [1])
        precondition(compressionArguments(compact).suffix(3) == ["--select-audio", "--audio-track", "2"])
        precondition(compressionProfiles(for: multi).first?.id == "copy")
        precondition(compressionArguments(originalProfile).prefix(3) == ["compress", "--profile", "copy"])
        let small = SourceInfo(width: 720, height: 256, fps: 23.976, videoBitrate: 2,
            codec: "mpeg4", pixelFormat: "yuv420p", colorTransfer: "bt709", duration: 8000, hasAudio: true)
        let movieSize = source.deletingLastPathComponent().appendingPathComponent("movie-size.bin")
        FileManager.default.createFile(atPath: movieSize.path, contents: nil)
        let movieHandle = try! FileHandle(forWritingTo: movieSize)
        try! movieHandle.truncate(atOffset: 2_345_600_000); try! movieHandle.close()
        selectedInputURL = movieSize
        sourceInfo = small
        preferredProfileID = compact.id
        applyAvailableProfiles(for: small)
        precondition(preferredProfileID == compact.id)
        precondition(profilePopup.numberOfItems == 18)
        precondition(profilePopup.itemArray.filter { $0.isEnabled }.count == 11)
        for (index, profile) in availableProfiles.enumerated() where profile.id != "copy" {
            precondition(profilePopup.item(at: index)!.isEnabled == (estimatedProfileMB(profile, info: small) < sourceSizeMB))
            precondition(profile.outputShortSide(for: small) <= 256)
        }
        precondition(compact.dimensions(for: small) == "720×256")
        let args = compressionArguments(compact)
        precondition(args[args.firstIndex(of: "--short-side")! + 1] == "256")
        var excessive = compact
        excessive.fps = 60
        precondition(profileRestriction(excessive, info: small) == nil)
        precondition(!compressionArguments(excessive).contains("--fps"))
        precondition(excessive.outputFPS(for: small) == 23.976)
        profileModeControl.selectedSegment = 2
        profileModeChanged(profileModeControl)
        precondition(profilePopup.itemArray.filter { $0.isEnabled }.count == 4)
        precondition(rutubeProfiles[0].standardBitrate == 0.3)
        profileModeControl.selectedSegment = 1
        profileModeChanged(profileModeControl)
        precondition(profilePopup.itemArray.filter { $0.isEnabled }.count == 3)
        profileModeControl.selectedSegment = 0
        profileModeChanged(profileModeControl)
        restoreCompressionAudio()
        precondition(excludedAudioTracks.isEmpty)
        selectedInputURL = nil
        // YouTube uses a separate catalog, original fps and the same size/resolution guards.
        let sizedSource = source.deletingLastPathComponent().appendingPathComponent("size-only.bin")
        FileManager.default.createFile(atPath: sizedSource.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: sizedSource)
        try! handle.truncate(atOffset: 1_000_000_000); try! handle.close()
        selectedInputURL = sizedSource
        let upload = SourceInfo(width: 1920, height: 1080, fps: 30, videoBitrate: 10, codec: "h264", pixelFormat: "yuv420p", colorTransfer: "bt709", duration: 900, hasAudio: false)
        sourceInfo = upload
        profileModeControl.selectedSegment = 1
        profileModeChanged(profileModeControl)
        precondition(modeControl.segmentCount == 2 && profileModeControl.segmentCount == 3)
        precondition(mode == .compress && isYouTubeMode)
        precondition(youtubeProfiles.count == 8 && youtubeProfiles.allSatisfy(\.valid))
        precondition(youtubeProfiles.last!.highFPSBitrate == 180)
        preferredProfileID = "copy"
        applyAvailableProfiles(for: upload)
        precondition(profilePopup.numberOfItems == 9)
        let originalIndex = availableProfiles.firstIndex { $0.id == "copy" }!
        precondition(originalIndex == 5 && profilePopup.indexOfSelectedItem == originalIndex)
        precondition(availableProfiles[originalIndex - 1].targetShortSide == 1080)
        precondition(availableProfiles[originalIndex + 1].targetShortSide == 1440)
        precondition(profilePopup.item(at: originalIndex - 1)!.isEnabled)
        precondition(!profilePopup.item(at: originalIndex + 1)!.isEnabled)
        var expensive = youtubeProfiles[4]
        expensive = CompressionProfile(id: "expensive", title: "Expensive", suffix: "test", targetShortSide: 720,
            standardBitrate: 100, highFPSBitrate: 100, videoCodec: "h264")
        precondition(profileRestriction(expensive, info: upload) != nil)
        profilePopup.selectItem(at: originalIndex - 1); profileChanged(profilePopup)
        precondition(selectedOutputExtension == "mp4")
        precondition(compressionArguments(youtubeProfiles[4]).contains("384"))
        precondition(!compressionArguments(youtubeProfiles[4]).contains("--fps"))
        applyAvailableProfiles(for: upload)
        precondition(preferredProfileID == "yt-sdr-1080")
        profileModeControl.selectedSegment = 2
        profileModeChanged(profileModeControl)
        precondition(rutubeProfiles.count == 8 && rutubeProfiles.allSatisfy(\.valid))
        precondition(availableProfiles.filter { $0.id.hasPrefix("rt-sdr-") }.count == 8)
        precondition(!availableProfiles.contains { $0.id.hasPrefix("yt-sdr-") })
        precondition(rutubeProfiles.last!.targetShortSide == 2160)
        precondition(compressionArguments(rutubeProfiles[5]).contains("128"))
        profileModeControl.selectedSegment = 1
        profileModeChanged(profileModeControl)
        precondition(preferredProfileID == "yt-sdr-1080")
        setRunning(true)
        precondition(!profileModeControl.isEnabled)
        setRunning(false)
        precondition(profileModeControl.isEnabled)
        profileModeControl.selectedSegment = 0
        profileModeChanged(profileModeControl)
        precondition(!compressionProfiles(for: upload).contains { $0.id.hasPrefix("yt-sdr-") })
        selectedInputURL = nil
        sourceInfo = nil
        modeControl.selectedSegment = EditorMode.join.rawValue
        joinClips = [JoinClip(id: UUID(), url: source, info: info, lowerValue: 0, upperValue: 2, thumbnails: [], volume: 0.4, waveform: [0.1, 1, 0.2], speed: 2)]
        joinTable.reloadData()
        joinTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateJoinFileSummary()
        precondition(joinClips[0].timelineDuration == 1)
        let preview = makeJoinPreviewItem(at: 0)
        precondition(abs(preview.asset.duration.seconds - 1) < 0.05)
        precondition(!preview.asset.tracks(withMediaType: .audio).isEmpty)
        let menu = editorContextMenu(for: .video(0), projectTime: 0.4)!
        let speedMenu = menu.items.first { $0.submenu != nil }!.submenu!
        precondition(speedMenu.items.filter { $0.action != nil }.count == 19)
        timelineContextTarget = .video(0)
        timelineContextProjectTime = 0.4
        splitContextVideo()
        precondition(joinClips.count == 2)
        precondition(abs(joinClips[0].upperValue - 0.8) < 0.0001)
        precondition(joinClips.allSatisfy { $0.speed == 2 && $0.volume == 0.4 })
        precondition(abs(joinClips.reduce(0) { $0 + $1.timelineDuration } - 1) < 0.0001)
        joinTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        detachSelectedClipAudio(nil)
        detachSelectedClipAudio(nil)
        precondition(overlayAudioTracks.count == 1, "Duplicate detached audio")
        precondition(overlayAudioTracks[0].volume == 0.4 && overlayAudioTracks[0].speed == 2)
        precondition(joinClips[0].volume == 0 && joinClips[0].audioDetached)
        precondition(overlayAudioTable.enclosingScrollView?.superview != nil, "Audio list is inaccessible")
        setRunning(true)
        precondition(!formatPopup.isEnabled)
        precondition(!editorTimelineView.isEnabled && !clipVolumeSlider.isEnabled && !overlayVolumeSlider.isEnabled)
        precondition(editorContextMenu(for: .video(0), projectTime: 0) == nil)
        let previous = joinClips[0].lowerValue
        trimVideoFromEditorTimeline(index: 0, start: 0.1, end: 0.5)
        precondition(joinClips[0].lowerValue == previous, "Editing during export")
        setRunning(false)
        precondition(formatPopup.isEnabled)
        trimVideoFromEditorTimeline(index: 0, start: -0.1, end: 0.5)
        precondition(joinClips[0].lowerValue == previous)
        trimVideoFromEditorTimeline(index: 0, start: 0, end: 0.025)
        precondition(joinClips[0].upperValue == 0.025)
        let data = try! JSONEncoder().encode(projectSnapshot())
        let project = try! JSONDecoder().decode(EditorProject.self, from: data)
        precondition(project.clips.count == 2 && project.audio[0].speed == 2 && project.clips[0].detached)
        diagnosticOutput = ""
        let unicode = Data("Проверка русского текста 🎬\n".utf8)
        for byte in unicode { consume(data: Data([byte]), isError: false) }
        precondition(diagnosticOutput == "Проверка русского текста 🎬\n")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temporary = directory.appendingPathComponent("temp.m4a")
        let destination = directory.appendingPathComponent("result.m4a")
        try! Data("new".utf8).write(to: temporary)
        try! Data("previous".utf8).write(to: destination)
        let published = try! publishAudio(temporary, requested: destination)
        precondition(published.lastPathComponent == "result-1.m4a")
        precondition(try! String(contentsOf: destination) == "previous")
        precondition(try! String(contentsOf: published) == "new")
        removePlayerTimeObserver()
        playerView.player = nil
        mediaWorker.cancelAll()
        window.orderOut(nil)
        print("Editor regression tests passed: time validation, split at speed, detach, busy controls, short clips, project persistence, UTF-8")
    }
}
let testApp = NSApplication.shared
testApp.setActivationPolicy(.prohibited)
if #available(macOS 13.0, *) {
    let delegate = AppDelegate()
    delegate.runRegressionTests(source: URL(fileURLWithPath: CommandLine.arguments[1]))
}
