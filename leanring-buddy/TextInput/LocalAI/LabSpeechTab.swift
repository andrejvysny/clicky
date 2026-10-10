import SwiftUI

struct LabSpeechTab: View {
    @ObservedObject var model: LabSpeechModel
    @ObservedObject var runtime: LocalAIRuntime
    @State private var showSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureCard
            if model.capture == .ready || model.rawTranscript != nil || model.processing { resultCard }
            savedCard
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $showSave) {
            LabSaveSampleSheet(model: model, isPresented: $showSave)
        }
    }

    // MARK: Capture

    private var captureCard: some View {
        LabCard(title: "Speech test · \(runtime.displayName(.speech))") {
            if model.capture == .recording {
                // While recording only the clock, limit, device and level are shown; no transcript exists.
                HStack(spacing: 14) {
                    Circle().fill(DS.Colors.destructiveText).frame(width: 9, height: 9)
                    Text(Self.clock(model.elapsed)).font(.system(size: 18, weight: .medium, design: .monospaced))
                    Text("of \(Self.clock(Double(LabSpeechModel.maximumSeconds))) · \(model.activeDeviceName)")
                        .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                    LevelMeter(level: model.level).frame(width: 160, height: 8)
                    Spacer()
                    Button("Stop") { model.stopRecording() }.islandButton(.primary)
                    Button("Cancel") { model.cancelRecording() }.islandButton(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Button("Record") { model.startRecording() }.islandButton(.primary).disabled(model.processing)
                    Button("Import audio…") { model.importAudio() }.islandButton(.secondary).disabled(model.processing)
                    Picker("Input", selection: $model.deviceUID) {
                        Text("System default").tag(String?.none)
                        ForEach(model.devices) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    .frame(maxWidth: 280).font(.system(size: 12))
                    Spacer()
                }
                labNote("The microphone is used only while you press Record, and the permission prompt appears on that click. Recordings stay in memory (up to \(LabSpeechModel.maximumSeconds) s).")
            }
            if model.capture == .ready {
                HStack(spacing: 8) {
                    Text(String(format: "Audio ready: %.1f s", model.audioSeconds)).font(.system(size: 12))
                    Spacer()
                    Toggle("Clean up transcript", isOn: $model.cleanupEnabled).font(.system(size: 12))
                    if model.cleanupEnabled {
                        Picker("", selection: $model.promptIndex) {
                            ForEach(Array(LocalCleanupPrompt.all.enumerated()), id: \.offset) { Text($0.element.identifier).tag($0.offset) }
                        }
                        .labelsHidden().frame(maxWidth: 220).font(.system(size: 11))
                    }
                    if model.processing { Button("Cancel") { model.cancelProcessing() }.islandButton(.warning) }
                    else { Button("Transcribe") { model.transcribe() }.islandButton(.primary) }
                    Button("Discard audio") { model.discardAudio() }.islandButton(.quiet).disabled(model.processing)
                }
            }
            if let error = model.errorMessage {
                labError(error)
                if error.hasPrefix("Load "), runtime.installedModel(.speech) != nil {
                    Button("Load \(runtime.displayName(.speech))") { Task { try? await runtime.load(.speech) } }.islandButton(.secondary)
                }
            }
        }
    }

    // MARK: Results

    private var resultCard: some View {
        LabCard(title: "Transcript") {
            if model.processing { HStack(spacing: 6) { SpinnerRing(size: 10); Text("Working on this Mac…").font(.system(size: 12)).foregroundStyle(DS.Colors.textSecondary) } }
            if let raw = model.rawTranscript {
                column("Raw transcript", raw)
                if let cleaned = model.cleanedTranscript {
                    column("Cleaned transcript", cleaned)
                    if let assessment = model.assessment { gateView(assessment) }
                    diffView(cleaned)
                    Toggle("Use original transcript", isOn: $model.useOriginal).font(.system(size: 12))
                } else if let error = model.cleanupError {
                    labError("Cleanup: \(error)")
                    if error.hasPrefix("Load "), runtime.installedModel(.cleanup) != nil {
                        Button("Load \(runtime.displayName(.cleanup))") { Task { try? await runtime.load(.cleanup) } }.islandButton(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Button("Copy result") { if let text = model.resultText { labCopy(text) } }.islandButton(.secondary)
                    Button("Save as benchmark sample…") { showSave = true }.islandButton(.secondary)
                    labNote("Copy only; nothing is inserted anywhere.")
                }
                timings
            }
        }
    }

    private func column(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            LabOutputBox(text: text, placeholder: "(empty)", minHeight: 40)
        }
    }

    private func gateView(_ assessment: CleanupAssessment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Gate: \(assessment.verdict.rawValue)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(assessment.verdict == .accept ? DS.Colors.success : DS.Colors.warningText)
            if !assessment.concerns.isEmpty {
                Text(assessment.concerns.map(\.rawValue).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            }
        }
    }

    @ViewBuilder private func diffView(_ cleaned: String) -> some View {
        if let segments = model.diffSegments {
            let text = segments.reduce(Text("")) { partial, segment in
                let word: Text
                switch segment.kind {
                case .same: word = Text(segment.text + " ").foregroundColor(DS.Colors.textPrimary)
                case .removed: word = Text(segment.text + " ").strikethrough().foregroundColor(DS.Colors.destructiveText)
                case .added: word = Text(segment.text + " ").foregroundColor(DS.Colors.success)
                }
                return partial + word
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Word diff · removed struck through, added in green").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                text.font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8).background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        } else {
            labNote("The transcript is too long for a word diff (over \(LabWordDiff.maximumWords) words); compare the two texts above.")
        }
    }

    private var timings: some View {
        let rows: [(String, String)] = [
            ("ASR worker", LabFormat.milliseconds(model.asrMetrics?.worker.totalMilliseconds)),
            ("ASR host", LabFormat.milliseconds(model.asrMetrics?.hostMilliseconds)),
            ("Cleanup worker", LabFormat.milliseconds(model.cleanupMetrics?.worker.totalMilliseconds)),
            ("Cleanup host", LabFormat.milliseconds(model.cleanupMetrics?.hostMilliseconds)),
            ("Stop to final", LabFormat.milliseconds(model.stopToFinalMilliseconds)),
            ("Worker memory (phys_footprint)", LabFormat.megabytes(model.asrMetrics?.worker.memory?.physicalFootprintBytes)),
        ]
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.0).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary)
                    Text(row.1).font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    // MARK: Saved samples

    private var savedCard: some View {
        LabCard(title: "Personal benchmark samples") {
            labNote("Stored only on this Mac. Never uploaded or used for training.")
            if let message = model.saveMessage { labNote(message) }
            if model.datasetIndexDamaged {
                Button("Back up and start new index") { model.backUpDamagedIndex() }.islandButton(.secondary)
            }
            if model.savedSamples.isEmpty { labNote("No samples saved yet.") }
            ForEach(model.savedSamples) { sample in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(sample.id) · \(sample.split == .heldOut ? "Held-out" : "Development") · \(sample.isApproved ? "approved" : "not approved")")
                            .font(.system(size: 11, design: .monospaced))
                        if !sample.tags.isEmpty { Text(sample.tags.joined(separator: ", ")).font(.system(size: 10)).foregroundStyle(DS.Colors.textTertiary) }
                    }
                    Spacer()
                    Button("Delete") { model.deleteSample(sample) }.islandButton(.secondary)
                }
            }
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Colors.surface4)
                Capsule().fill(level > 0.9 ? DS.Colors.warning : DS.Colors.success)
                    .frame(width: geometry.size.width * CGFloat(min(1, max(0, level))))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Explicit consent for keeping a recording: both references are editable and nothing is saved until Save.
private struct LabSaveSampleSheet: View {
    @ObservedObject var model: LabSpeechModel
    @Binding var isPresented: Bool
    @State private var raw = ""
    @State private var clean = ""
    @State private var split = LocalBenchmarkSample.Split.development
    @State private var tags = ""
    @State private var approve = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save as benchmark sample").font(.system(size: 14, weight: .semibold))
            labNote("Stored only on this Mac. Never uploaded or used for training. Correct both references to what was actually said and meant.")
            field("Raw reference (exactly what was said)", $raw)
            field("Intended clean reference (what the text should become)", $clean)
            Picker("Split", selection: $split) {
                Text("Development").tag(LocalBenchmarkSample.Split.development)
                Text("Held-out").tag(LocalBenchmarkSample.Split.heldOut)
            }
            .pickerStyle(.segmented)
            TextField("Tags, comma separated", text: $tags).textFieldStyle(.roundedBorder)
            Toggle("Approve for quality metrics (needs both references)", isOn: $approve).font(.system(size: 12))
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.islandButton(.secondary)
                Button("Save") {
                    model.saveSample(raw: raw.trimmingCharacters(in: .whitespacesAndNewlines), clean: clean.trimmingCharacters(in: .whitespacesAndNewlines),
                                     split: split, tags: tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                     approve: approve)
                    isPresented = false
                }.islandButton(.primary).disabled(approve && (raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20).frame(width: 520)
        .background(ClickyChrome.panel).preferredColorScheme(.dark)
        .onAppear { raw = model.rawTranscript ?? ""; clean = model.cleanedTranscript ?? model.rawTranscript ?? "" }
    }

    private func field(_ title: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            TextEditor(text: text).font(.system(size: 12)).scrollContentBackground(.hidden).padding(4).frame(height: 64)
                .background(DS.Colors.background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        }
    }
}
