import Foundation
@preconcurrency import FluidAudio
import XCTest
@testable import Kalam_test

@MainActor
final class ASRModelSelectionTests: XCTestCase {
    func testOlderSuccessCannotReplaceNewerSelection() async throws {
        try await verifySupersededLoad(fails: false)
    }

    func testOlderFailureCannotClearNewerSelection() async throws {
        try await verifySupersededLoad(fails: true)
    }

    private func verifySupersededLoad(fails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KalamLoad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = try makeConfiguration(.v2, in: directory.appendingPathComponent("Old"))
        let new = try makeConfiguration(.v3, in: directory.appendingPathComponent("New"))
        let loader = ControlledModelLoader()
        let service = ASRService(loadModel: loader.load)
        let first = Task { try await service.initialize(using: old) }
        try await loader.waitForStart(.v2)
        let second = Task { try await service.initialize(using: new) }
        try await loader.waitForStart(.v3)
        await loader.finish(.v3, fails: false)
        try await second.value
        await loader.finish(.v2, fails: fails)
        do {
            try await first.value
            XCTFail("Superseded loads must report cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let status = await service.status
        let model = await service.currentModelVersion
        XCTAssertTrue(status.isReady)
        XCTAssertFalse(status.isSetupIssue)
        XCTAssertEqual(model, .v3)
    }

    private func makeConfiguration(_ version: ASRModelVersion, in library: URL) throws -> ModelsConfiguration {
        let directory = library.appendingPathComponent(version.repositoryFolderName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ModelSetupSupport.requiredModelFiles(for: version) {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        var config = ModelsConfiguration.defaults
        config.asrVersion = version
        try config.setModelLibraryURL(library)
        return config
    }
}

private actor ControlledModelLoader {
    private var loads: [ASRModelVersion: CheckedContinuation<AsrManager, Error>] = [:]

    func load(_ directory: URL, _ library: URL, _ version: ASRModelVersion) async throws -> AsrManager {
        XCTAssertEqual(directory.deletingLastPathComponent().path, library.path)
        return try await withCheckedThrowingContinuation { continuation in
            loads[version] = continuation
        }
    }

    func waitForStart(_ version: ASRModelVersion) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while loads[version] == nil {
            guard .now < deadline else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func finish(_ version: ASRModelVersion, fails: Bool) {
        let load = loads.removeValue(forKey: version)
        if fails {
            load?.resume(throwing: CocoaError(.fileReadCorruptFile))
        } else {
            load?.resume(returning: AsrManager())
        }
    }
}
