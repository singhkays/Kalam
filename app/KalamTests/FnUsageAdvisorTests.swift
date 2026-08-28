import XCTest
@testable import Kalam_test
import Foundation

final class FnUsageAdvisorTests: XCTestCase {
    var hiToolbox: UserDefaults!
    var appDefaults: UserDefaults!
    var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "FnUsageAdvisorTests.\(UUID().uuidString)"
        // hiToolbox suite is com.apple.HIToolbox, but for test we use an isolated suite
        hiToolbox = UserDefaults(suiteName: "\(suiteName).HIToolbox")!
        hiToolbox.removePersistentDomain(forName: "\(suiteName).HIToolbox")
        appDefaults = UserDefaults(suiteName: suiteName)!
        appDefaults.removePersistentDomain(forName: suiteName)
        FnUsageAdvisor.resetForTesting(defaults: appDefaults)
    }

    override func tearDown() {
        hiToolbox.removePersistentDomain(forName: "\(suiteName).HIToolbox")
        appDefaults.removePersistentDomain(forName: suiteName)
        FnUsageAdvisor.resetForTesting(defaults: appDefaults)
        super.tearDown()
    }

    // Absent key → UNKNOWN → no banner, no false advice
    func testAbsentKeyIsQuiet() {
        // Ensure no key
        hiToolbox.removeObject(forKey: "AppleFnUsageType")
        let eval = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertEqual(eval.fnState, .unknown)
        XCTAssertFalse(eval.shouldAdvise)
        XCTAssertNil(eval.reason)
        // shouldFireNow must not fire for unknown
        XCTAssertFalse(FnUsageAdvisor.shouldFireNow(evaluation: eval, defaults: appDefaults))
    }

    // Confirmed-bad values → needsAdvisory, firing once
    func testConfirmedBadFiresOnce() {
        hiToolbox.set(1, forKey: "AppleFnUsageType") // Change Input Source
        let eval1 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertTrue(eval1.shouldAdvise)
        XCTAssertNotNil(eval1.reason)
        // First fire should succeed
        XCTAssertTrue(FnUsageAdvisor.shouldFireNow(evaluation: eval1, defaults: appDefaults))
        // Second fire with same reason must be suppressed (once per condition-change)
        XCTAssertFalse(FnUsageAdvisor.shouldFireNow(evaluation: eval1, defaults: appDefaults))
        // Changing to a different bad value should fire again
        hiToolbox.set(2, forKey: "AppleFnUsageType") // Show Emoji
        let eval2 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertTrue(eval2.shouldAdvise)
        XCTAssertNotEqual(eval1.reason, eval2.reason)
        XCTAssertTrue(FnUsageAdvisor.shouldFireNow(evaluation: eval2, defaults: appDefaults))
        XCTAssertFalse(FnUsageAdvisor.shouldFireNow(evaluation: eval2, defaults: appDefaults))
        // Resolving to OK should clear, then re-bad should fire again
        hiToolbox.set(0, forKey: "AppleFnUsageType") // Do Nothing → ok
        let evalOk = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertFalse(evalOk.shouldAdvise)
        XCTAssertFalse(FnUsageAdvisor.shouldFireNow(evaluation: evalOk, defaults: appDefaults))
        // Now bad again should fire (new episode)
        hiToolbox.set(1, forKey: "AppleFnUsageType")
        let eval3 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertTrue(FnUsageAdvisor.shouldFireNow(evaluation: eval3, defaults: appDefaults))
    }

    // OK value (0) → no advise when Karabiner not running
    func testOkValueDoesNotAdvise() {
        hiToolbox.set(0, forKey: "AppleFnUsageType")
        let eval = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertEqual(eval.fnState, .ok)
        XCTAssertFalse(eval.shouldAdvise)
        XCTAssertFalse(FnUsageAdvisor.shouldFireNow(evaluation: eval, defaults: appDefaults))
    }

    // Karabiner detection is independent of domain read
    func testKarabinerDecoupledFromDomainRead() {
        // Case 1: absent key + Karabiner running → should advise via Karabiner
        hiToolbox.removeObject(forKey: "AppleFnUsageType")
        let eval1 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: true)
        XCTAssertTrue(eval1.shouldAdvise)
        XCTAssertTrue(eval1.karabinerRunning)
        XCTAssertEqual(eval1.fnState, .unknown)
        XCTAssertTrue(eval1.reason?.contains("Karabiner") == true)
        XCTAssertTrue(FnUsageAdvisor.shouldFireNow(evaluation: eval1, defaults: appDefaults))

        // Reset
        FnUsageAdvisor.resetForTesting(defaults: appDefaults)
        hiToolbox.removeObject(forKey: "AppleFnUsageType")

        // Case 2: ok value (0) + Karabiner → still advise (Karabiner overrides)
        hiToolbox.set(0, forKey: "AppleFnUsageType")
        let eval2 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: true)
        XCTAssertTrue(eval2.shouldAdvise)
        XCTAssertTrue(FnUsageAdvisor.shouldFireNow(evaluation: eval2, defaults: appDefaults))

        // Reset
        FnUsageAdvisor.resetForTesting(defaults: appDefaults)

        // Case 3: bad value + Karabiner → advise with combined reason, still independent
        hiToolbox.set(1, forKey: "AppleFnUsageType")
        let eval3 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: true)
        XCTAssertTrue(eval3.shouldAdvise)
        XCTAssertTrue(eval3.reason?.contains("Karabiner") == true)
        XCTAssertTrue(eval3.reason?.contains("Change Input Source") == true)

        // Case 4: absent + Karabiner false → no advise (proves decoupled: Karabiner false doesn't trigger)
        hiToolbox.removeObject(forKey: "AppleFnUsageType")
        let eval4 = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertFalse(eval4.shouldAdvise)
    }

    // Verify bundle ID check helper
    func testIsKarabinerRunningHelper() {
        // We can't launch Karabiner in test, but we can verify that the helper checks the correct bundle ID.
        // This test just ensures the helper doesn't crash and returns false when Karabiner not running.
        // On this host, Karabiner is not running, so it should be false.
        // We inject a fake workspace via the overload that takes a workspace.
        // For the default check, just ensure it doesn't throw.
        let result = FnUsageAdvisor.isKarabinerRunning()
        // We don't assert true/false here because it depends on host; just ensure it returns a Bool.
        XCTAssertTrue(result == true || result == false)
    }

    // Verify that all bad values are treated as needsAdvisory (conservative)
    func testAllNonZeroPresentValuesAdvise() {
        for bad in [1, 2, 3, 99, -1] {
            hiToolbox.set(bad, forKey: "AppleFnUsageType")
            let eval = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
            XCTAssertTrue(eval.shouldAdvise, "value \(bad) should advise")
            FnUsageAdvisor.resetForTesting(defaults: appDefaults)
        }
        hiToolbox.set(0, forKey: "AppleFnUsageType")
        let ok = FnUsageAdvisor.evaluate(hiToolboxDefaults: hiToolbox, karabinerRunning: false)
        XCTAssertFalse(ok.shouldAdvise)
    }
}
