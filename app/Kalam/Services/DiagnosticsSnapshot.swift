import Foundation
import OSLog

// MARK: - Diagnostics snapshot (support bundle)
//
// Privacy-safe, user-facing support bundle for the UpdatesPane Maintenance
// "Copy diagnostics" row. Allowlist enforced by construction: the inputs
// struct carries ONLY counts/timings/versions/flags (see the plan allowlist
// in app/docs/dev-design/2026-09-07-diagnostics-export.md). There is no
// transcript, audio, pasteboard, device-name, UID, path, hotkey-chord,
// trigger, or replacement field anywhere in this file — so none can leak
// into the bundle. Pure value types only, no singletons, and this file never
// logs bundle content.

/// Our OSLog subsystem. Single source for the snapshot reader and the UI;
///
/// matches every `Logger(subsystem: "singhkays.Kalam", ...)` callsite.
enum DiagnosticsLogSubsystem {
    static let name = "singhkays.Kalam"
}

/// Bounds for the persisted-log excerpt window.
enum DiagnosticsSnapshotLimits {
    static let maxExcerptLines = 80
    static let maxExcerptCharacters = 8_000
    /// How far back the store query looks (recent window only).
    static let excerptWindowSeconds: TimeInterval = 600
}

enum DiagnosticsEngineState: String, Sendable, Equatable {
    case verified
    case missing
    case incomplete
}

enum DiagnosticsMicPermission: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// The persisted-log excerpt: either bounded lines from our own subsystem,
/// or an explicit unavailable marker (reader failure must surface as a
/// friendly notice, never throw into the UI).
enum DiagnosticsLogExcerpt: Sendable, Equatable {
    case lines([String])
    case unavailable
}

/// All snapshot inputs, caller-supplied so tests never touch UserDefaults,
/// the dictionary manager, or the log store. Every field is a count, timing,
/// version, flag, or enum label — see the plan allowlist.
struct DiagnosticsSnapshotInputs: Sendable, Equatable {
    // Identity
    var appName: String
    var appVersion: String
    var osVersion: String
    var modelVersion: String
    // Flags
    var verboseAudio: Bool
    var stageTimingEnabled: Bool
    var startStageTimingEnabled: Bool
    var duckEnabled: Bool
    var muteOtherAudio: Bool
    var cleanupEnabled: Bool
    // Dictionary (counts only)
    var dictionaryTotal: Int
    var dictionaryEnabled: Int
    // Engine (presence + manifest counts, no paths)
    var engineState: DiagnosticsEngineState
    var manifestPresent: Int
    var manifestTotal: Int
    // Last failures (privacySafeErrorSummary domain+code strings, nil = none)
    var lastASRInitError: String?
    var lastAudioError: String?
    var lastPasteError: String?
    // Mic (no names, UIDs, or serials)
    var micPermission: DiagnosticsMicPermission
    var usableInputCount: Int
    var connectedTransport: String?
    var connectedChannels: Int?
    // Cleanup / ITN config
    var removeFillers: Bool
    var handleBacktracks: Bool
    var formatLists: Bool
    var normalizePunctuation: Bool
    var grammarPass: String
    var itnEnabled: Bool
    var itnAvailable: Bool
    var itnVersion: String?
    // Trigger (no retention: audio is never persisted — K-57 removed 2026-10-02)
    var activationMode: String
    var hotkeySet: Bool
    // Last dictation (numbers only, nil = not recorded this launch)
    var lastTrimmedMs: Int?
    var lastAsrMs: Int?
    var lastReplacements: Int?
    var gateFallback: Bool?
    var gateReason: String?
    // Permissions / runtime
    var axTrusted: Bool
    var sandbox: Bool
    var audioInput: Bool
    var accessibilityEntitlement: Bool
    var outgoingNetwork: Bool
    // Log excerpt
    var logExcerpt: DiagnosticsLogExcerpt
}

enum DiagnosticsSnapshot {
    /// Build the formatted bundle string from injected inputs.
    static func makeBundle(from inputs: DiagnosticsSnapshotInputs) -> String {
        var out: [String] = []
        out.append("Kalam diagnostics")
        out.append("app=\(inputs.appName) \(inputs.appVersion)")
        out.append("os=\(inputs.osVersion)")
        out.append("model=\(inputs.modelVersion)")
        out.append("engine=\(inputs.engineState.rawValue) manifest=\(inputs.manifestPresent)/\(inputs.manifestTotal)")
        out.append("verboseAudio=\(yesNo(inputs.verboseAudio))")
        out.append("stageTiming=\(yesNo(inputs.stageTimingEnabled))")
        out.append("startStageTiming=\(yesNo(inputs.startStageTimingEnabled))")
        out.append("duckEnabled=\(yesNo(inputs.duckEnabled))")
        out.append("muteOtherAudio=\(yesNo(inputs.muteOtherAudio))")
        out.append("cleanupEnabled=\(yesNo(inputs.cleanupEnabled))")
        out.append("dictionaryTotal=\(inputs.dictionaryTotal)")
        out.append("dictionaryEnabled=\(inputs.dictionaryEnabled)")
        out.append("lastASRInitError=\(inputs.lastASRInitError ?? "none")")
        out.append("lastAudioError=\(inputs.lastAudioError ?? "none")")
        out.append("lastPasteError=\(inputs.lastPasteError ?? "none")")
        out.append("micPermission=\(inputs.micPermission.rawValue)")
        out.append("usableInputs=\(inputs.usableInputCount)")
        out.append("connectedTransport=\(inputs.connectedTransport ?? "none")")
        out.append("connectedChannels=\(inputs.connectedChannels.map(String.init) ?? "none")")
        out.append("removeFillers=\(yesNo(inputs.removeFillers))")
        out.append("handleBacktracks=\(yesNo(inputs.handleBacktracks))")
        out.append("formatLists=\(yesNo(inputs.formatLists))")
        out.append("normalizePunctuation=\(yesNo(inputs.normalizePunctuation))")
        out.append("grammarPass=\(inputs.grammarPass)")
        out.append("itnEnabled=\(yesNo(inputs.itnEnabled))")
        out.append("itnAvailable=\(yesNo(inputs.itnAvailable))")
        out.append("itnVersion=\(inputs.itnVersion ?? "unknown")")
        out.append("activationMode=\(inputs.activationMode)")
        out.append("hotkeySet=\(yesNo(inputs.hotkeySet))")
        out.append("lastTrimmedMs=\(inputs.lastTrimmedMs.map(String.init) ?? "not-recorded")")
        out.append("lastAsrMs=\(inputs.lastAsrMs.map(String.init) ?? "not-recorded")")
        out.append("lastReplacements=\(inputs.lastReplacements.map(String.init) ?? "not-recorded")")
        out.append("gateFallback=\(inputs.gateFallback.map(yesNo) ?? "not-recorded")")
        out.append("gateReason=\(inputs.gateReason ?? "not-recorded")")
        out.append("axTrusted=\(yesNo(inputs.axTrusted))")
        out.append("sandbox=\(yesNo(inputs.sandbox))")
        out.append("audioInput=\(yesNo(inputs.audioInput))")
        out.append("accessibilityEntitlement=\(yesNo(inputs.accessibilityEntitlement))")
        out.append("outgoingNetwork=\(yesNo(inputs.outgoingNetwork))")
        out.append("logExcerpt:")
        switch inputs.logExcerpt {
        case .unavailable:
            out.append("(log excerpt unavailable)")
        case .lines(let lines) where lines.isEmpty:
            out.append("(no recent log entries)")
        case .lines(let lines):
            out.append(contentsOf: lines)
        }
        return out.joined(separator: "\n")
    }

    /// Bound an excerpt to the most recent lines / characters. Keeps the
    /// tail (most recent entries); drops oldest first. Pure helper so the
    /// reader and tests share one bounding rule.
    static func boundExcerpt(_ lines: [String], maxLines: Int, maxCharacters: Int) -> [String] {
        guard maxLines > 0, maxCharacters > 0 else { return [] }
        var tail = Array(lines.suffix(maxLines))
        var total = tail.reduce(0) { $0 + $1.count + 1 }
        while total > maxCharacters, !tail.isEmpty {
            total -= tail[0].count + 1
            tail.removeFirst()
        }
        if let last = tail.last, last.count > maxCharacters {
            tail[tail.count - 1] = String(last.suffix(maxCharacters))
        }
        return tail
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}

// MARK: - Log excerpt reader

/// Protocol-gated store reader: takes a subsystem string plus entry bounds,
/// returns bounded lines or `.unavailable` (never throws into the UI).
protocol DiagnosticsLogReader: Sendable {
    func fetchExcerpt(subsystem: String, maxLines: Int, maxCharacters: Int) async -> DiagnosticsLogExcerpt
}

/// Real implementation: queries the current-process store for our subsystem
/// only (in-process via OSLogStore — no subprocess, no file writes, no
/// network). Persisted logs are already counts-only and debug is never
/// persisted, so no transcript redaction is needed here.
actor OSLogStoreDiagnosticsReader: DiagnosticsLogReader {
    func fetchExcerpt(subsystem: String, maxLines: Int, maxCharacters: Int) async -> DiagnosticsLogExcerpt {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let windowStart = Date().addingTimeInterval(-DiagnosticsSnapshotLimits.excerptWindowSeconds)
            let position = store.position(date: windowStart)
            let predicate = NSPredicate(format: "subsystem == %@", subsystem)
            let raw = try store.getEntries(at: position, matching: predicate)
            var messages: [String] = []
            messages.reserveCapacity(min(maxLines * 2, 256))
            for entry in raw {
                guard let log = entry as? OSLogEntryLog else { continue }
                guard log.subsystem == subsystem else { continue }
                messages.append("[\(log.category)] \(log.composedMessage)")
                if messages.count > 512 {
                    messages.removeFirst(messages.count - 512)
                }
            }
            let bounded = DiagnosticsSnapshot.boundExcerpt(messages, maxLines: maxLines, maxCharacters: maxCharacters)
            return .lines(bounded)
        } catch {
            return .unavailable
        }
    }
}
