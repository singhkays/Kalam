import Foundation

enum OnboardingDeckRoute: Equatable {
    case welcome
    case microphone
    case microphoneSelection
    case accessibility
    case modelFolder
    case modelAcquisition
    case hotkey
    case ready
}

enum OnboardingDeckMode: Equatable {
    case firstRun
    case repair
}

struct OnboardingDeckProgress: Equatable {
    let completedRequirements: Int
    let totalRequirements: Int
    let activeRequirement: OnboardingRequirement?
}

func initialDeckRoute(
    mode: OnboardingMode,
    snapshot: OnboardingStatusSnapshot,
    isFreshStart: Bool = false
) -> OnboardingDeckRoute {
    // First run ALWAYS opens on welcome ("The promise, before the paperwork") —
    // that is the deck's first screen in the mockup, not something skippable
    // because some requirement happens to be satisfied already. Only repair
    // (setup was completed before; something broke) resumes at the broken gate.
    // isFreshStart retained for API compatibility; no longer load-bearing.
    switch mode {
    case .firstRun:
        return .welcome
    case .repair:
        return firstIncompleteDeckRoute(for: snapshot)
    }
}

func routeAfterSnapshotUpdate(
    current route: OnboardingDeckRoute,
    snapshot: OnboardingStatusSnapshot,
    preservingDebugResetWelcome: Bool = false
) -> OnboardingDeckRoute {
    if preservingDebugResetWelcome {
        return .welcome
    }
    // Pinned cards (2026-08-21): snapshot refreshes must not move the deck.
    // - .welcome: Begin setup is the only exit (TCC re-checks, audio prepare).
    // - .microphoneSelection: a multi-choice card whose rows call refreshAction
    //   on every tap; the selection updates the highlight, Continue is the
    //   contract. Permission cards intentionally keep snapshot-following so
    //   "Check again" can advance them.
    // - .modelFolder/.modelAcquisition (2026-08-22): the model card is the
    //   first run's one-time ACKNOWLEDGMENT stop for carried-over installs —
    //   its rows (folder pick, version picker, copy actions) refresh the
    //   snapshot too, and a ready model must not bounce the user past the
    //   confirmation they are sitting on. Continue is the contract, same as
    //   the selection card.
    switch route {
    case .welcome, .microphoneSelection:
        return route
    case .modelFolder, .modelAcquisition:
        // Model acknowledgment hold (2026-08-22): while the hold is LIVE
        // (first run, model ready, location not yet confirmed) the card must
        // not snapshot-bounce the user past the confirmation they are sitting
        // on — its rows (folder pick, version picker, copy actions, Check
        // again) all refresh the snapshot. Once confirmed (or in repair mode,
        // which never routes to the hold), the card returns to normal
        // snapshot-following so "Check again" keeps its auto-advance.
        if snapshot.mode == .firstRun,
           !snapshot.hasConfirmedModelLocation,
           snapshot.modelStatus.isReady {
            return route
        }
        return nextDeckRoute(after: route, snapshot: snapshot)
    default:
        break
    }
    return nextDeckRoute(after: route, snapshot: snapshot)
}

func previousDeckRoute(
    before route: OnboardingDeckRoute,
    snapshot: OnboardingStatusSnapshot
) -> OnboardingDeckRoute {
    switch route {
    case .welcome: return .welcome
    case .microphone: return .welcome
    case .microphoneSelection: return .microphone
    case .accessibility: return .microphoneSelection
    case .modelFolder, .modelAcquisition:
        // Back skips SATISFIED gates (2026-08-22): the forward router holds
        // the model card open for confirmation, so the naive predecessor
        // (.accessibility) would immediately snapshot-advance back to the
        // model card — a loop. Land on the nearest earlier card that can
        // actually hold.
        if !snapshot.microphoneStatus.isReady { return .microphone }
        return .microphoneSelection
    case .hotkey:
        // Same skip-back: the nearest earlier card that can actually hold.
        // A broken model step IS a valid destination (its card holds);
        // a satisfied one is not (the forward router would bounce straight
        // back here), so skip to accessibility instead.
        if !snapshot.modelStatus.isReady {
            return snapshot.modelLibraryURL == nil ? .modelFolder : .modelAcquisition
        }
        return .accessibility
    case .ready: return .hotkey
    }
}

func nextDeckRoute(
    after route: OnboardingDeckRoute,
    snapshot: OnboardingStatusSnapshot
) -> OnboardingDeckRoute {
    switch route {
    case .welcome:
        // Cards BEFORE the model step acknowledge a carried-over model as
        // their next stop (2026-08-22): Begin setup must land on the model
        // card once, even though its gate is already satisfied.
        return firstIncompleteDeckRoute(for: snapshot, acknowledgingCarriedOverModel: true)
    case .microphone:
        return snapshot.microphoneStatus.isReady ? .microphoneSelection : .microphone
    case .microphoneSelection:
        return firstIncompleteDeckRoute(for: snapshot, acknowledgingCarriedOverModel: true)
    case .accessibility:
        return snapshot.accessibilityStatus.isReady
            ? firstIncompleteDeckRoute(for: snapshot, acknowledgingCarriedOverModel: true)
            : .accessibility
    case .modelFolder:
        if snapshot.modelStatus.isReady {
            // First-run acknowledgment hold (2026-08-22): a carried-over
            // model does NOT auto-advance past its own step. The card shows
            // the detected library and the Continue press is the user's
            // confirmation; repair mode never routes here (broken gates only).
            if snapshot.mode == .firstRun && !snapshot.hasConfirmedModelLocation {
                return .modelFolder
            }
            return firstIncompleteDeckRoute(for: snapshot)
        }
        return snapshot.modelLibraryURL == nil ? .modelFolder : .modelAcquisition
    case .modelAcquisition:
        return snapshot.modelStatus.isReady ? firstIncompleteDeckRoute(for: snapshot) : .modelAcquisition
    case .hotkey:
        // Deliberately NO acknowledgment here: once the user has walked past
        // the model card (or resumed in repair), later snapshot refreshes on
        // the hotkey/ready cards must not drag them backwards to re-confirm.
        return snapshot.hotkeyStatus.isReady ? firstIncompleteDeckRoute(for: snapshot) : .hotkey
    case .ready:
        return snapshot.canStartDictating ? .ready : firstIncompleteDeckRoute(for: snapshot)
    }
}

func deckProgress(for snapshot: OnboardingStatusSnapshot) -> OnboardingDeckProgress {
    OnboardingDeckProgress(
        completedRequirements: snapshot.completedRequirements,
        totalRequirements: 4,
        // The rail reports REAL requirements only — the first-run model
        // acknowledgment stop is routing metadata, not an unmet requirement,
        // so it must never tint the Speech-model column as active.
        activeRequirement: firstBrokenRequirement(for: snapshot)
    )
}

private func firstIncompleteDeckRoute(
    for snapshot: OnboardingStatusSnapshot,
    acknowledgingCarriedOverModel: Bool = false
) -> OnboardingDeckRoute {
    let requirement = acknowledgingCarriedOverModel
        ? firstRoutingStopRequirement(for: snapshot)
        : firstBrokenRequirement(for: snapshot)
    if let requirement {
        switch requirement {
        case .microphone:
            return .microphone
        case .accessibility:
            return .accessibility
        case .hotkey:
            return .hotkey
        case .model:
            if snapshot.modelLibraryURL == nil { return .modelFolder }
            // Acknowledgment stop (model READY, location unconfirmed) lands
            // on the step's front door; a genuinely broken model with a
            // configured library goes to the acquisition/download card.
            if snapshot.modelStatus.isReady { return .modelFolder }
            return .modelAcquisition
        }
    }

    return .ready
}

/// The next ROUTING stop in gate order (microphone → accessibility → model →
/// key): the first broken real gate, or — first run only — the carried-over
/// model acknowledgment, which occupies the model step's slot in the walk
/// (between accessibility and the key). Repair mode and the rail's
/// active-tint path use `firstBrokenRequirement` instead.
private func firstRoutingStopRequirement(for snapshot: OnboardingStatusSnapshot) -> OnboardingRequirement? {
    if !snapshot.microphoneStatus.isReady {
        return .microphone
    }
    if !snapshot.accessibilityStatus.isReady {
        return .accessibility
    }
    // Model step (rail order): genuinely broken, OR the one-time first-run
    // acknowledgment of a carried-over ready model.
    if !snapshot.modelStatus.isReady {
        return .model
    }
    if snapshot.mode == .firstRun,
       !snapshot.hasConfirmedModelLocation,
       snapshot.modelStatus.isReady {
        return .model
    }
    if !snapshot.hotkeyStatus.isReady {
        return .hotkey
    }
    return nil
}

private func firstBrokenRequirement(for snapshot: OnboardingStatusSnapshot) -> OnboardingRequirement? {
    if !snapshot.microphoneStatus.isReady {
        return .microphone
    }
    if !snapshot.accessibilityStatus.isReady {
        return .accessibility
    }
    if !snapshot.hotkeyStatus.isReady {
        return .hotkey
    }
    if !snapshot.modelStatus.isReady {
        return .model
    }
    return nil
}

/// Human-centric step kicker shown on each gate card. Uses "Step N of 4"
/// language (per the v1.2 visual revision) mapped onto the live four-requirement
/// route model. The welcome and ready cards are not numbered steps.
func stepKicker(for route: OnboardingDeckRoute) -> String {
    switch route {
    case .welcome:
        return "Welcome"
    case .microphone, .microphoneSelection:
        return "Step 1 of 4 · Microphone"
    case .accessibility:
        return "Step 2 of 4 · Accessibility"
    case .modelFolder, .modelAcquisition:
        return "Step 3 of 4 · The model"
    case .hotkey:
        return "Step 4 of 4 · The key"
    case .ready:
        return "Ready"
    }
}

/// Canonical welcome-card privacy copy. Plan-compliant: honest about local
/// processing and states audio/transcripts are not saved. Deliberately avoids
/// the banned "never connects to the internet" / "no data collection"
/// absolutes and any hardcoded duration.
///
/// 2026-08-22 user decision: the welcome plate carries the CORE PROMISE
/// only. Download/Terminal mechanics moved fully to the model step card,
/// where they are actionable (progressive disclosure) — the test pin now
/// FORBIDS "Terminal" here.
let kalamOnboardingWelcomeCopy = "Your dictation is processed entirely on this Mac. Audio and transcripts are not saved."

// MARK: - Rail milestone mapping (v3 adoption, Task 2)

/// The four rail milestones, in gate order. Each carries a fixed number of
/// sub-ticks rendered as capsules above its label.
enum OnboardingDeckMilestone: Int, CaseIterable {
    case microphone = 0
    case accessibility = 1
    case model = 2
    case key = 3

    var tickCount: Int {
        switch self {
        case .microphone, .model: return 2
        case .accessibility, .key: return 1
        }
    }
}

/// Maps a deck route onto (milestone, active sub-tick) for the progress rail.
/// Sub-ticks are 1-based. Completion is NOT encoded here — the rail derives
/// per-milestone completion from the live snapshot statuses so a broken gate
/// can still tint its column.
func railMilestone(for route: OnboardingDeckRoute) -> (milestone: OnboardingDeckMilestone, subtick: Int) {
    switch route {
    case .welcome, .microphone:
        return (.microphone, 1)
    case .microphoneSelection:
        return (.microphone, 2)
    case .accessibility:
        return (.accessibility, 1)
    case .modelFolder:
        return (.model, 1)
    case .modelAcquisition:
        return (.model, 2)
    case .hotkey:
        return (.key, 1)
    case .ready:
        // Everything complete; the rail renders all columns done via snapshot.
        return (.key, 1)
    }
}
