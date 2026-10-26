import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct CameraRecordingsView: View {
    let cameraID: UUID
    @Bindable var store: CameraStore
    let windows: CameraWindows
    @Bindable var model: CameraRecordingsModel
    @ViewState private var authenticating = false
    @ViewState private var requestedTime = Date()
    @ViewState private var startDraft: String?
    @ViewState private var endDraft: String?
    @Environment(\.locale) private var locale
    private var camera: Camera? { store.cameras.first { $0.id == cameraID } }
    var body: some View {
        Group {
            if let camera {
                VStack(spacing: 0) {
                    header(camera)
                    if let error = model.error { banner(error, warning: true) }
                    HSplitView {
                        sidebar.frame(minWidth: 265, idealWidth: 300, maxWidth: 360)
                        playback.frame(minWidth: 500, maxWidth: .infinity)
                    }
                    if !model.notices.isEmpty {
                        ScrollView { VStack(alignment: .leading, spacing: 4) { ForEach(model.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 74).padding(10)
                    }
                }
                .onAppear {
                    requestedTime = model.selectedDay
                    if !model.connected && !model.connecting, let credentials = store.sessions[cameraID]?.credentialsForControls() { model.authenticate(credentials) }
                }
                .onChange(of: camera) { _, value in model.update(camera: value); windows.updateRecordingsTitle(value.name, id: cameraID) }
                .onChange(of: model.selectedDay) { _, day in requestedTime = day }
                .onChange(of: model.movie?.url) { _, _ in startDraft = nil; endDraft = nil }
                .sheet(isPresented: $authenticating) { CredentialSheet(camera: camera) { model.authenticate($0) } }
            } else { Color.clear.onAppear { windows.closeRecordings(cameraID) } }
        }
    }
    private func header(_ camera: Camera) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(camera.name).font(.title2.weight(.semibold)).lineLimit(1)
                Text("SD-card recordings").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.connecting || model.querying { ProgressView().controlSize(.small) }
            Button("Refresh recordings", systemImage: "arrow.clockwise") { model.loadDay(model.selectedDay, refreshCalendar: true) }
                .disabled(!model.connected || model.querying || model.exporting)
            Button(model.connected ? String(localized: "Change credentials…") : String(localized: "Authenticate…"), systemImage: "lock") { authenticating = true }
                .disabled(model.connecting || model.exporting)
        }.padding(16)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            RecordingCalendarView(model: model)
            HStack {
                Stepper(value: $model.channel, in: 0...63) { Text("Channel \(model.channel + 1)") }
                Toggle("Substream", isOn: $model.substream).toggleStyle(.checkbox)
            }.font(.caption).disabled(!model.connected || model.querying || model.exporting)
                .onChange(of: model.channel) { _, _ in model.loadDay(model.selectedDay) }
                .onChange(of: model.substream) { _, _ in model.loadDay(model.selectedDay) }
            if let storage = model.storage {
                if let free = storage.freeBytes, let total = storage.totalBytes {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: free), countStyle: .file)) free of \(ByteCountFormatter.string(fromByteCount: Int64(clamping: total), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if storage.presence == .absent { Label("Camera reports no storage card.", systemImage: "sdcard").font(.caption).foregroundStyle(.orange) }
                if storage.statuses.contains(where: { $0 != 0 }) { Text("The camera reports a storage status that needs attention.").font(.caption).foregroundStyle(.orange) }
            }
            Divider()
            HStack { Text("\(model.records.count) recordings").font(.headline); Spacer(); if model.querying { ProgressView().controlSize(.mini) } }
            ScrollView {
                LazyVStack(spacing: 5) {
                    if model.records.isEmpty && !model.querying {
                        Text(model.connected ? String(localized: "No recordings returned for this day and channel.") : String(localized: "Authenticate to browse the camera's memory card."))
                            .foregroundStyle(.secondary).font(.callout).padding(.vertical, 20)
                    }
                    ForEach(model.records) { recording in
                        Button { model.play(recording) } label: {
                            HStack(alignment: .top) {
                                Image(systemName: model.selectedRecording?.id == recording.id ? "play.circle.fill" : "film")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(recordingClock(recording.begin.date) + " – " + recordingClock(recording.end.date))
                                        .font(.callout.monospacedDigit()).lineLimit(1)
                                    HStack {
                                        Text(recordingDuration(recording.end.date.timeIntervalSince(recording.begin.date)))
                                        if let bytes = recording.estimatedBytes { Text("≈ " + ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)) }
                                    }.font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(9).contentShape(Rectangle())
                                .background(model.selectedRecording?.id == recording.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(model.exporting)
                            .accessibilityLabel(String(localized: "Play recording at \(recordingClock(recording.begin.date))"))
                    }
                }
            }
        }.padding(14)
    }
    private var playback: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Camera time", systemImage: "clock")
                Text(recordingDate(model.selectedDay)).fontWeight(.medium)
                Spacer()
                if let clock = model.cameraClock { Text(recordingClock(clock.date)).foregroundStyle(.secondary).help("Camera clock at connection time") }
            }.font(.callout)
            RecordingTimelineView(model: model).frame(height: 60)
            HStack {
                DatePicker("Go to time", selection: $requestedTime, displayedComponents: [.hourAndMinute])
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                Button("Go") { model.selectCameraTime(requestedTime) }.disabled(model.records.isEmpty || model.exporting)
                Spacer()
            }
            ZStack {
                Color.black
                if let player = model.player { RecordingNativePlayer(player: player) }
                else if model.transferActive {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(model.converting ? String(localized: "Preparing native playback…") : String(localized: "Downloading recording…"))
                        if model.downloading { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.receivedBytes), countStyle: .file)).font(.caption.monospacedDigit()) }
                        Button(model.converting ? String(localized: "Cancel preparation") : String(localized: "Cancel download")) { model.cancelPlayback() }
                    }.foregroundStyle(.white)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "play.rectangle").font(.system(size: 40))
                        Text("Select a recording or a recorded time.")
                        if model.selectedRecording != nil && model.error != nil { Text("Native playback unavailable. Export original to save a fresh camera download.").font(.caption) }
                    }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }.frame(minHeight: 260, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            transport
            exportControls
        }.padding(16)
    }
    private var transport: some View {
        VStack(spacing: 8) {
            HStack {
                Text(recordingDuration(model.position)).monospacedDigit()
                Slider(value: Binding(get: { model.position }, set: { model.seek($0) }), in: 0...max(0.01, model.duration))
                    .accessibilityLabel("Recording position")
                Text(recordingDuration(model.duration)).monospacedDigit()
            }.font(.caption).disabled(model.movie == nil)
            HStack(spacing: 14) {
                Button { model.adjacent(-1) } label: { Image(systemName: "backward.end.fill") }.help("Previous recording")
                Button { model.jump(-15) } label: { Image(systemName: "gobackward.15") }.help("Back 15 seconds")
                Button { model.togglePlayback() } label: { Image(systemName: "playpause.fill") }.help("Play or pause")
                Button { model.jump(15) } label: { Image(systemName: "goforward.15") }.help("Forward 15 seconds")
                Button { model.adjacent(1) } label: { Image(systemName: "forward.end.fill") }.help("Next recording")
                Picker("Speed", selection: Binding(get: { model.playbackRate }, set: { model.setRate($0) })) {
                    Text("0.5×").tag(Float(0.5)); Text("1×").tag(Float(1)); Text("2×").tag(Float(2)); Text("4×").tag(Float(4))
                }.frame(width: 130)
                Spacer()
                if let date = model.cameraPosition { Text(recordingClock(date)).monospacedDigit().font(.caption) }
            }.disabled(model.movie == nil)
        }
    }
    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Export original…", systemImage: "square.and.arrow.up") { save(original: true, interval: false) }
                    .disabled(model.selectedRecording == nil || !model.connected || model.querying || model.exporting || model.transferActive)
                Button("Export movie…") { save(original: false, interval: false) }.disabled(model.movie == nil || model.exporting)
                Spacer()
                if model.exporting {
                    ProgressView().controlSize(.small); Text("Exporting…").font(.caption)
                    if model.receivedBytes > 0 { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: model.receivedBytes), countStyle: .file)).font(.caption.monospacedDigit()) }
                }
            }
            if model.movie != nil {
                HStack {
                    Text("Interval").font(.caption)
                    TextField("Start (seconds)", text: intervalInput(start: true)).frame(width: 82)
                    Text("–")
                    TextField("End (seconds)", text: intervalInput(start: false)).frame(width: 82)
                    Button("Start here") { model.intervalStart = model.position; startDraft = nil }.font(.caption)
                    Button("End here") { model.intervalEnd = model.position; endDraft = nil }.font(.caption)
                    Spacer()
                    Button("Export interval…") { save(original: false, interval: true) }.disabled(!intervalInputValid)
                }.disabled(model.exporting)
                if intervalInputValid, let range = model.alignedExportRange {
                    Text("Keyframe-aligned export: \(recordingDuration(range.start)) – \(recordingDuration(range.end))")
                        .font(.caption).foregroundStyle(.secondary)
                } else { Text("Select a valid interval within the recording.").font(.caption).foregroundStyle(.orange) }
            }
        }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
    private func save(original: Bool, interval: Bool) {
        guard !interval || intervalInputValid else { return }
        let recordingID = model.selectedRecording?.id
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = original ? [.data] : [.quickTimeMovie]
        panel.nameFieldStringValue = "recording-" + (model.selectedRecording?.begin.wire.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: " ", with: "_") ?? "export") + (original ? ".xm" : ".mov")
        panel.begin { response in
            guard response == .OK, let url = panel.url, model.selectedRecording?.id == recordingID else { return }
            if original { model.exportOriginal(to: url) } else { model.exportMovie(to: url, interval: interval) }
        }
    }
    private var intervalInputValid: Bool {
        [startDraft, endDraft].allSatisfy { value in
            guard let value else { return true }
            return DeviceSettingsInput.decimal(value, locale: locale).map { NSDecimalNumber(decimal: $0).doubleValue.isFinite } ?? false
        } && model.alignedExportRange != nil
    }
    private func intervalInput(start: Bool) -> Binding<String> {
        Binding(get: { (start ? startDraft : endDraft) ?? (start ? model.intervalStart : model.intervalEnd).formatted(.number.locale(locale)) }, set: { text in
            if start { startDraft = text } else { endDraft = text }
            guard let decimal = DeviceSettingsInput.decimal(text, locale: locale) else { return }
            let value = NSDecimalNumber(decimal: decimal).doubleValue
            guard value.isFinite else { return }
            if start { model.intervalStart = value } else { model.intervalEnd = value }
        })
    }
    private func banner(_ value: String, warning: Bool) -> some View {
        HStack(alignment: .top) { Image(systemName: "exclamationmark.triangle"); Text(value).font(.callout); Spacer(); Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss error") }
            .foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 8)
    }
}

private struct RecordingNativePlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

private struct RecordingCalendarView: View {
    @Bindable var model: CameraRecordingsModel
    private var calendar: Calendar { var c = CameraRecordingsModel.clockCalendar; c.firstWeekday = Calendar.current.firstWeekday; return c }
    private var offset: Int { (calendar.component(.weekday, from: model.month) - calendar.firstWeekday + 7) % 7 }
    private var days: Int { calendar.range(of: .day, in: .month, for: model.month)?.count ?? 0 }
    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Button { model.changeMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous month")
                Spacer(); Text(recordingMonth(model.month)).font(.headline); Spacer()
                Button { model.changeMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next month")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(0..<7, id: \.self) { index in Text(calendar.veryShortStandaloneWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7]).font(.caption2).foregroundStyle(.secondary) }
                ForEach(0..<(offset + days), id: \.self) { cell in
                    if cell < offset { Color.clear.frame(height: 32) }
                    else {
                        let day = cell - offset + 1
                        let selected = calendar.component(.day, from: model.selectedDay) == day
                        Button {
                            if let date = calendar.date(byAdding: .day, value: day - 1, to: model.month) { model.loadDay(date) }
                        } label: {
                            VStack(spacing: 2) {
                                Text(day.formatted()).font(.callout)
                                Circle().fill(model.calendarDays?.contains(day) == true ? Color.accentColor : Color.clear).frame(width: 4, height: 4)
                            }.frame(maxWidth: .infinity).frame(height: 32)
                                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain).accessibilityLabel(String(localized: "Day \(day)"))
                            .accessibilityValue(model.calendarDays?.contains(day) == true ? String(localized: "Recordings available") : String(localized: "Select to search"))
                    }
                }
            }
            Text("Dots indicate recordings reported by the camera for this month.").font(.caption2).foregroundStyle(.secondary)
        }.disabled(!model.connected || model.querying || model.exporting)
    }
}

private struct RecordingTimelineView: View {
    @Bindable var model: CameraRecordingsModel
    private struct Interval: Identifiable {
        let id: String
        let recordingID: String
        let start: Date
        let end: Date
    }
    private var intervals: [Interval] {
        model.records.flatMap { recording in
            if model.selectedRecording?.id == recording.id, let movie = model.movie {
                return movie.mappingSegments.enumerated().map { index, segment in
                    Interval(id: recording.id + "-\(index)", recordingID: recording.id, start: segment.cameraStart, end: segment.cameraStart.addingTimeInterval(segment.cameraDuration))
                }
            }
            return [Interval(id: recording.id, recordingID: recording.id, start: recording.begin.date, end: recording.end.date)]
        }
    }
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                    ForEach(intervals) { interval in
                        let lower = max(0, interval.start.timeIntervalSince(model.selectedDay)) / 86400
                        let upper = min(86400, interval.end.timeIntervalSince(model.selectedDay)) / 86400
                        if upper > lower {
                            Rectangle().fill(model.selectedRecording?.id == interval.recordingID ? Color.accentColor : Color.accentColor.opacity(0.5))
                                .frame(width: max(2, (upper - lower) * geometry.size.width)).offset(x: lower * geometry.size.width)
                        }
                    }
                    if let date = model.cameraPosition {
                        let offset = date.timeIntervalSince(model.selectedDay) / 86400
                        if offset >= 0 && offset <= 1 { Rectangle().fill(.primary).frame(width: 2).offset(x: offset * geometry.size.width) }
                    }
                }.frame(height: 28).clipped().contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        guard !model.exporting, geometry.size.width > 0 else { return }
                        let seconds = min(max(value.location.x / geometry.size.width, 0), 1) * 86399
                        model.selectCameraTime(model.selectedDay.addingTimeInterval(seconds))
                    })
                    .accessibilityElement(children: .ignore).accessibilityLabel("Daily recording timeline")
                    .help("Click a recorded interval to play that camera time. Empty areas are gaps.")
                HStack { ForEach(["00:00", "06:00", "12:00", "18:00", "24:00"], id: \.self) { value in Text(value).font(.caption2.monospacedDigit()); if value != "24:00" { Spacer() } } }
            }
        }
    }
}

@MainActor private func recordingClock(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.setLocalizedDateFormatFromTemplate("HHmmss")
    return formatter.string(from: date)
}
@MainActor private func recordingDate(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateStyle = .medium
    return formatter.string(from: date)
}
@MainActor private func recordingMonth(_ date: Date) -> String {
    let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter.string(from: date)
}
