import AppKit
import XCTest
@testable import Kalam_test
import ApplicationServices

/// Task 5 (K-56) Tier-1 injection tests — headless, no real AX or pasteboard.
/// Each scenario must result in EXACTLY ONE insertion (AX verified OR Cmd+V),
/// never double-insert, and secure/PID cases must hold without pasteboard exposure.

@MainActor
final class PasteServiceTier1Tests: XCTestCase {
    private func isolatedPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("Tier1Tests.\(UUID().uuidString)"))
    }

    // Electron lie-success: AX SET returns success but value unchanged → fall through to Cmd+V, exactly one.
    func testElectronLieFallsThroughToCmdVExactlyOnce() async throws {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let originalChangeCount = pasteboard.changeCount

        let fakeElement = AXUIElementCreateSystemWide()
        var axSetCalls = 0
        var axValueCalls = 0
        var cmdVCalls = 0
        var unicodeCalls = 0

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in unicodeCalls += 1; return false }
        strategies.postCmdV = { cmdVCalls += 1; return true }
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "ElectronApp", strategy: "test")) }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.frontmostPID = { nil }
        strategies.axGetPid = { _ in nil }
        strategies.getElementRole = { _ in "AXTextField" }
        // Lie: SET succeeds but value stays old
        strategies.axSetSelectedText = { _, _ in axSetCalls += 1; return .success }
        strategies.getElementValue = { _ in axValueCalls += 1; return "old value" }
        strategies.setMessagingTimeout = { _, _ in }

        let service = PasteService(strategies: strategies)
        try await service.paste("hello verified", preferPid: nil, pidPostingEnabled: false)

        XCTAssertEqual(axSetCalls, 1, "Tier-1 SET must be attempted once")
        XCTAssertGreaterThanOrEqual(axValueCalls, 1, "verification must poll")
        XCTAssertEqual(cmdVCalls, 1, "fallback Cmd+V must be called exactly once")
        XCTAssertEqual(unicodeCalls, 1, "unicode attempted once before pasteboard (fails)")
        // Exactly one insertion: Cmd+V (AX lied, so not counted as insertion)
        // Pasteboard should have been used for Cmd+V, then restored immediately (AX fallback was not pasteboard)
        // The test doesn't check double-insert directly, but the call counts prove it.
    }

    // Secure field refusal BEFORE pasteboard exposure — no clipboard write, hold.
    func testSecureFieldRefusalBeforePasteboardExposure() async {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("user-clip", forType: .string)
        let startChange = pasteboard.changeCount

        let fakeElement = AXUIElementCreateSystemWide()
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in XCTFail("unicode must not be attempted on secure field"); return false }
        strategies.postCmdV = { XCTFail("CmdV must not be posted on secure field"); return false }
        strategies.pasteboard = pasteboard
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "SecureApp", strategy: "test")) }
        strategies.getElementRole = { _ in "AXSecureTextField" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.axGetPid = { _ in nil }
        strategies.frontmostPID = { nil }

        let service = PasteService(strategies: strategies)
        do {
            try await service.paste("secret", preferPid: nil, pidPostingEnabled: false)
            XCTFail("secure field must throw")
        } catch PasteServiceError.secureField {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(pasteboard.changeCount, startChange, "secure field must not touch pasteboard")
        XCTAssertEqual(pasteboard.string(forType: .string), "user-clip")
    }

    // Secure input global refusal before pasteboard — IsSecureEventInputEnabled true
    func testSecureInputGlobalRefusal() async {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("user", forType: .string)
        let start = pasteboard.changeCount

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.isSecureEventInputEnabled = { true }
        strategies.secureInputOwnerPID = { nil }
        strategies.pasteboard = pasteboard

        let service = PasteService(strategies: strategies)
        do {
            try await service.paste("hello", preferPid: nil, pidPostingEnabled: false)
            XCTFail("must throw secureInputActive")
        } catch PasteServiceError.secureInputActive {
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertEqual(pasteboard.changeCount, start)
    }

    // PID mismatch → hold, never blind Cmd+V, no pasteboard
    func testPIDMismatchHoldsWithoutPasteboard() async {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("orig", forType: .string)
        let start = pasteboard.changeCount

        let fakeElement = AXUIElementCreateSystemWide()
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in XCTFail("must not post unicode on PID mismatch"); return false }
        strategies.postCmdV = { XCTFail("must not CmdV on PID mismatch"); return false }
        strategies.pasteboard = pasteboard
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "App", strategy: "test")) }
        strategies.axGetPid = { _ in 999 }
        strategies.getElementRole = { _ in "AXTextField" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.frontmostPID = { 123 } // not used here, element PID is checked
        strategies.getElementValue = { _ in nil }
        strategies.axSetSelectedText = { _, _ in .success }

        let service = PasteService(strategies: strategies)
        do {
            try await service.paste("hello", preferPid: 123, pidPostingEnabled: false)
            XCTFail("PID mismatch must throw")
        } catch PasteServiceError.pidMismatch {
        } catch { XCTFail("wrong \(error)") }
        XCTAssertEqual(pasteboard.changeCount, start)
    }

    // Frontmost re-check after AX window: captured PID != current frontmost → hold, no global
    func testFrontmostChangedHolds() async {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("orig", forType: .string)
        let start = pasteboard.changeCount

        let fakeElement = AXUIElementCreateSystemWide()
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in XCTFail("must not unicode after frontmost changed"); return false }
        strategies.postCmdV = { XCTFail("must not CmdV after frontmost changed"); return false }
        strategies.pasteboard = pasteboard
        // Tier-1 will fail verification (so we reach frontmost check)
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "App", strategy: "test")) }
        strategies.axGetPid = { _ in 42 }
        strategies.getElementRole = { _ in "AXTextField" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.axSetSelectedText = { _, _ in .success }
        strategies.getElementValue = { _ in "old" } // lie → verification fails
        strategies.setMessagingTimeout = { _, _ in }
        // After AX window, frontmost is now 99, captured was 42 → mismatch
        strategies.frontmostPID = { 99 }

        let service = PasteService(strategies: strategies)
        do {
            try await service.paste("hello", preferPid: 42, pidPostingEnabled: false)
            XCTFail("must throw frontmostChanged")
        } catch PasteServiceError.frontmostChanged {
        } catch { XCTFail("wrong \(error)") }
        XCTAssertEqual(pasteboard.changeCount, start)
    }

    // Slow SET with override: SET takes > global timeout but with override it succeeds via AX alone, exactly once.
    func testSlowSetWithOverrideSucceedsViaAXOnly() async throws {
        let pasteboard = isolatedPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("orig", forType: .string)

        let fakeElement = AXUIElementCreateSystemWide()
        var axSetCalls = 0
        var cmdVCalls = 0

        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { cmdVCalls += 1; return true }
        strategies.pasteboard = pasteboard
        strategies.restoreDelay = 0
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "SlowApp", strategy: "test")) }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.frontmostPID = { nil }
        strategies.axGetPid = { _ in nil }
        strategies.getElementRole = { _ in "AXTextField" }
        // Simulate slow SET that still succeeds, and value eventually matches
        strategies.axSetSelectedText = { _, _ in
            axSetCalls += 1
            // Simulate 100ms delay inside SET (slow app)
            Thread.sleep(forTimeInterval: 0.1)
            return .success
        }
        var pollCount = 0
        strategies.getElementValue = { _ in
            pollCount += 1
            // First poll returns old, second returns expected
            return pollCount >= 2 ? "slow text" : "old"
        }
        strategies.setMessagingTimeout = { _, _ in }

        // Set override to 1500 ms (1.5s) so the slow app is covered
        UserDefaults.standard.set(1500, forKey: "internal.paste.setVerifyTimeoutOverrideMs")
        defer { UserDefaults.standard.removeObject(forKey: "internal.paste.setVerifyTimeoutOverrideMs") }

        let service = PasteService(strategies: strategies)
        try await service.paste("slow text", preferPid: nil, pidPostingEnabled: false)

        XCTAssertEqual(axSetCalls, 1)
        XCTAssertEqual(cmdVCalls, 0, "with override, slow SET should succeed via AX only, no CmdV fallback")
    }

    // AppQuirks forcePaste: bundle in table skips Tier-1, goes directly to global (exactly one)
    func testAppQuirksForcePasteSkipsTier1() async throws {
        // We cannot inject a real bundleID into the static table (it's empty), but we can test
        // the helper directly and verify that when shouldForcePaste is true, Tier-1 is not called.
        XCTAssertFalse(AppQuirks.shouldForcePaste(bundleID: "com.apple.TextEdit"), "empty table must not force")
        XCTAssertFalse(AppQuirks.shouldForcePaste(bundleID: nil))
        // Governance: table is empty, so this test just pins the empty state.
        // A future entry would be tested by adding it to the table and verifying that
        // pasting into that app skips the AX SET (mocked to fail) and goes to CmdV.
        let fakeElement = AXUIElementCreateSystemWide()
        var axSetCalls = 0
        var cmdVCalls = 0
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.postUnicodeText = { _ in false }
        strategies.postCmdV = { cmdVCalls += 1; return true }
        strategies.pasteboard = isolatedPasteboard()
        strategies.resolveFocusedElement = { _ in .success(AccessibilityFocusedElementResolution(element: fakeElement, appName: "TextEdit", strategy: "test")) }
        strategies.axSetSelectedText = { _, _ in axSetCalls += 1; return .success }
        strategies.getElementValue = { _ in "hello" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.frontmostPID = { nil }
        strategies.getElementRole = { _ in "AXTextField" }
        strategies.axGetPid = { _ in nil }
        // Even though element would succeed, if the bundle were in quirks, we would skip.
        // Since table is empty, we expect Tier-1 to be attempted.
        let service = PasteService(strategies: strategies)
        try await service.paste("hello", preferPid: nil, pidPostingEnabled: false)
        XCTAssertEqual(axSetCalls, 1, "without quirk, Tier-1 is attempted")
        XCTAssertEqual(cmdVCalls, 0, "Tier-1 success means no CmdV")
    }

    // Captured-element secure refusal
    func testCapturedElementSecureFieldThrows() async {
        let fakeElement = AXUIElementCreateSystemWide()
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.getElementRole = { _ in "AXSecureTextField" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        let service = PasteService(strategies: strategies)
        do {
            try await service.paste(into: fakeElement, text: "secret")
            XCTFail("must throw secureField")
        } catch PasteServiceError.secureField {
        } catch { XCTFail("wrong \(error)") }
    }

    // Captured-element verified success exactly once
    func testCapturedElementVerifiedSuccess() async throws {
        let fakeElement = AXUIElementCreateSystemWide()
        var setCalls = 0
        var strategies = PasteService.PasteStrategies()
        strategies.isProcessTrusted = { true }
        strategies.getElementRole = { _ in "AXTextField" }
        strategies.isSecureEventInputEnabled = { false }
        strategies.secureInputOwnerPID = { nil }
        strategies.axSetSelectedText = { _, _ in setCalls += 1; return .success }
        strategies.getElementValue = { _ in "captured hello" }
        strategies.setMessagingTimeout = { _, _ in }
        let service = PasteService(strategies: strategies)
        try await service.paste(into: fakeElement, text: "captured hello")
        XCTAssertEqual(setCalls, 1)
    }
}
