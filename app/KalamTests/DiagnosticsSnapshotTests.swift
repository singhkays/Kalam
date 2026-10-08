import XCTest
@testable import Kalam_test

/// Diagnostics export (support bundle) pins: formatter emits every
/// allowlisted section, excerpt bounding + subsystem scoping, failure-as-
/// notice, and redaction-by-construction (no transcript/device/UID/path/
/// chord/trigger/replacement field can round-trip through the snapshot).
final class DiagnosticsSnapshotTests: XCTestCase {

    // MARK: - Fixture

    private func makeInputs(
        logExcerpt: DiagnosticsLogExcerpt = .lines(["[Lifecycle] ctx=start idle -> warming effects=0"])
    ) -> DiagnosticsSnapshotInputs {
        DiagnosticsSnapshotInputs(
            appName: "Kalam",
            appVersion: "1.3.8",
            osVersion: "macOS 15.6.1 (24G90)",
            modelVersion: "v2",
            verboseAudio: false,
            stageTimingEnabled: true,
            startStageTimingEnabled: true,
            duckEnabled: true,
            muteOtherAudio: true,
            cleanupEnabled: true,
            dictionaryTotal: 2,
            dictionaryEnabled: 2,
            engineState: .verified,
            manifestPresent: 4,
            manifestTotal: 4,
            lastASRInitError: nil,
            lastAudioError: nil,
            lastPasteError: nil,
            micPermission: .granted,
            usableInputCount: 1,
            connectedTransport: "usb",
            connectedChannels: 1,
            removeFillers: true,
            handleBacktracks: true,
            formatLists: false,
            normalizePunctuation: true,
            grammarPass: "light",
            itnEnabled: true,
            itnAvailable: true,
            itnVersion: "0.1.0",
            activationMode: "holdOrToggle",
            hotkeySet: true,
            lastTrimmedMs: 412,
            lastAsrMs: 219,
            lastReplacements: 1,
            gateFallback: false,
            gateReason: "accept",
            axTrusted: true,
            sandbox: true,
            audioInput: true,
            accessibilityEntitlement: true,
            outgoingNetwork: false,
            logExcerpt: logExcerpt
        )
    }

    // MARK: - Task 1: formatting

    func testFormatterEmitsEveryAllowlistedSection() {
        let bundle = DiagnosticsSnapshot.makeBundle(from: makeInputs())
        let requiredKeys = [
            "Kalam diagnostics",
            "app=", "os=", "model=", "engine=", "manifest=",
            "verboseAudio=", "stageTiming=", "startStageTiming=",
            "duckEnabled=", "muteOtherAudio=", "cleanupEnabled=",
            "dictionaryTotal=", "dictionaryEnabled=",
            "lastASRInitError=", "lastAudioError=", "lastPasteError=",
            "micPermission=", "usableInputs=", "connectedTransport=", "connectedChannels=",
            "removeFillers=", "handleBacktracks=", "formatLists=", "normalizePunctuation=",
            "grammarPass=", "itnEnabled=", "itnAvailable=", "itnVersion=",
            "activationMode=", "hotkeySet=",
            "lastTrimmedMs=", "lastAsrMs=", "lastReplacements=",
            "gateFallback=", "gateReason=",
            "axTrusted=", "sandbox=", "audioInput=", "accessibilityEntitlement=", "outgoingNetwork=",
            "logExcerpt:",
        ]
        for key in requiredKeys {
            XCTAssertTrue(bundle.contains(key), "bundle missing section \(key)")
        }
    }

    func testFormatterIncludesVersionsFlagsCountsEngineMicPermissionsFailuresLastDictation() {
        var inputs = makeInputs()
        inputs.lastASRInitError = "Kalam.ASR#4865"
        inputs.lastAudioError = "Kalam.AudioDeviceDebug#-10877"
        inputs.lastPasteError = "Kalam.Paste#1"
        let bundle = DiagnosticsSnapshot.makeBundle(from: inputs)
        XCTAssertTrue(bundle.contains("Kalam 1.3.8"))
        XCTAssertTrue(bundle.contains("macOS 15.6.1"))
        XCTAssertTrue(bundle.contains("model=v2"))
        XCTAssertTrue(bundle.contains("engine=verified manifest=4/4"))
        XCTAssertTrue(bundle.contains("dictionaryTotal=2"))
        XCTAssertTrue(bundle.contains("dictionaryEnabled=2"))
        XCTAssertTrue(bundle.contains("micPermission=granted"))
        XCTAssertTrue(bundle.contains("connectedTransport=usb"))
        XCTAssertTrue(bundle.contains("Kalam.ASR#4865"))
        XCTAssertTrue(bundle.contains("lastTrimmedMs=412"))
        XCTAssertTrue(bundle.contains("lastAsrMs=219"))
        XCTAssertTrue(bundle.contains("gateReason=accept"))
        XCTAssertTrue(bundle.contains("outgoingNetwork=false"))
    }

    func testEmptyExcerptRendersGracefully() {
        let bundle = DiagnosticsSnapshot.makeBundle(from: makeInputs(logExcerpt: .lines([])))
        XCTAssertTrue(bundle.contains("(no recent log entries)"))
        XCTAssertFalse(bundle.contains("(log excerpt unavailable)"))
    }

    func testUnavailableExcerptRendersNotice() {
        let bundle = DiagnosticsSnapshot.makeBundle(from: makeInputs(logExcerpt: .unavailable))
        XCTAssertTrue(bundle.contains("(log excerpt unavailable)"))
    }

    func testNilOptionalsRenderWithoutFreeText() {
        var inputs = makeInputs(logExcerpt: .lines([]))
        inputs.connectedTransport = nil
        inputs.connectedChannels = nil
        inputs.itnVersion = nil
        inputs.lastTrimmedMs = nil
        inputs.gateFallback = nil
        inputs.gateReason = nil
        let bundle = DiagnosticsSnapshot.makeBundle(from: inputs)
        XCTAssertTrue(bundle.contains("connectedTransport=none"))
        XCTAssertTrue(bundle.contains("itnVersion=unknown"))
        XCTAssertTrue(bundle.contains("lastTrimmedMs=not-recorded"))
        XCTAssertTrue(bundle.contains("gateReason=not-recorded"))
    }

    // MARK: - Task 1: redaction by construction

    func testInputsHaveNoTranscriptField() {
        let mirror = Mirror(reflecting: makeInputs())
        let names = mirror.children.compactMap(\.label).map { $0.lowercased() }
        XCTAssertFalse(names.contains("transcript"), "snapshot inputs must not carry transcript text")
        XCTAssertFalse(names.contains("text"), "snapshot inputs must not carry free text")
        let bundle = DiagnosticsSnapshot.makeBundle(from: makeInputs()).lowercased()
        XCTAssertFalse(bundle.contains("transcript="))
    }

    func testRedactionNoSensitiveFieldsRoundTrip() {
        let mirror = Mirror(reflecting: makeInputs())
        let names = mirror.children.compactMap(\.label).map { $0.lowercased() }
        let banned = [
            "trigger", "replacement", "spoken", "typed",
            "devicename", "deviceid", "uid", "serial",
            "path", "url", "file", "chord", "keycode",
            "pasteboard", "clipboard", "audio", "sample", "transcript",
        ]
        for field in banned {
            XCTAssertFalse(names.contains(field), "snapshot inputs must not carry \(field)")
        }
        // Substring sweep: a sensitive-named field may only exist as a
        // non-String value (a count/flag such as lastReplacements: Int? or
        // the audioInput entitlement bool) — never as free text.
        for child in mirror.children {
            guard let label = child.label?.lowercased() else { continue }
            guard banned.contains(where: { label.contains($0) }) else { continue }
            if label == "audioinput" { continue }
            XCTAssertFalse(child.value is String, "\(label) must not be free text")
            XCTAssertFalse(child.value is [String], "\(label) must not be free text")
        }
    }

    // MARK: - Task 2: reader behind a protocol

    struct FakeReader: DiagnosticsLogReader {
        var lines: [String]?
        func fetchExcerpt(subsystem: String, maxLines: Int, maxCharacters: Int) async -> DiagnosticsLogExcerpt {
            guard subsystem == DiagnosticsLogSubsystem.name else { return .lines([]) }
            guard let lines else { return .unavailable }
            return .lines(DiagnosticsSnapshot.boundExcerpt(lines, maxLines: maxLines, maxCharacters: maxCharacters))
        }
    }

    struct CapturingReader: DiagnosticsLogReader {
        var captured: CapturedBox
        func fetchExcerpt(subsystem: String, maxLines: Int, maxCharacters: Int) async -> DiagnosticsLogExcerpt {
            captured.subsystem = subsystem
            captured.maxLines = maxLines
            return .lines([])
        }
    }

    final class CapturedBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _subsystem = ""
        private var _maxLines = 0
        var subsystem: String { get { lock.lock(); defer { lock.unlock() }; return _subsystem } set { lock.lock(); defer { lock.unlock() }; _subsystem = newValue } }
        var maxLines: Int { get { lock.lock(); defer { lock.unlock() }; return _maxLines } set { lock.lock(); defer { lock.unlock() }; _maxLines = newValue } }
    }

    func testExcerptBoundedInLinesAndCharacters() async {
        let reader = FakeReader(lines: (0..<200).map { "line-\($0)-padding-padding-padding" })
        let excerpt = await reader.fetchExcerpt(
            subsystem: DiagnosticsLogSubsystem.name, maxLines: 80, maxCharacters: 800
        )
        guard case .lines(let lines) = excerpt else { return XCTFail("expected lines") }
        XCTAssertLessThanOrEqual(lines.count, 80)
        XCTAssertLessThanOrEqual(lines.joined(separator: "\n").count, 800)
        XCTAssertTrue(lines.last?.contains("line-199") ?? false, "bounding must keep the most recent tail")
    }

    func testBoundExcerptKeepsTailWhenOverCharBudget() {
        let lines = ["oldest-" + String(repeating: "x", count: 500), "newest"]
        let bounded = DiagnosticsSnapshot.boundExcerpt(lines, maxLines: 80, maxCharacters: 50)
        XCTAssertEqual(bounded, ["newest"])
    }

    func testExcerptSubsystemScopedToOurSubsystem() async {
        // Contract: callers pass our subsystem; anything else yields no lines
        // (mirrors the real reader's predicate + in-code subsystem filter).
        XCTAssertEqual(DiagnosticsLogSubsystem.name, "singhkays.Kalam")
        let box = CapturedBox()
        let reader = CapturingReader(captured: box)
        _ = await reader.fetchExcerpt(subsystem: DiagnosticsLogSubsystem.name, maxLines: 10, maxCharacters: 100)
        XCTAssertEqual(box.subsystem, "singhkays.Kalam")

        let foreign = FakeReader(lines: ["[Lifecycle] ctx=start idle -> warming effects=0"])
        let foreignExcerpt = await foreign.fetchExcerpt(subsystem: "com.apple.audio.toolbox", maxLines: 10, maxCharacters: 1000)
        XCTAssertEqual(foreignExcerpt, .lines([]))
    }

    func testReaderFailureSurfacesUnavailableNotice() async {
        let reader = FakeReader(lines: nil)
        let excerpt = await reader.fetchExcerpt(
            subsystem: DiagnosticsLogSubsystem.name,
            maxLines: DiagnosticsSnapshotLimits.maxExcerptLines,
            maxCharacters: DiagnosticsSnapshotLimits.maxExcerptCharacters
        )
        XCTAssertEqual(excerpt, .unavailable)
        let bundle = DiagnosticsSnapshot.makeBundle(from: makeInputs(logExcerpt: excerpt))
        XCTAssertTrue(bundle.contains("(log excerpt unavailable)"))
    }

    func testRealReaderNeverThrowsIntoCaller() async {
        // Exercises the real OSLogStore path: in a sandboxed test host the
        // store may be empty or denied — either way the caller gets lines or
        // a friendly notice, never a throw.
        let reader = OSLogStoreDiagnosticsReader()
        let excerpt = await reader.fetchExcerpt(
            subsystem: DiagnosticsLogSubsystem.name, maxLines: 10, maxCharacters: 1000
        )
        switch excerpt {
        case .lines(let lines):
            XCTAssertLessThanOrEqual(lines.count, 10)
        case .unavailable:
            break
        }
    }
}
