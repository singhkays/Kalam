import XCTest
@testable import Kalam_test
import FluidAudio

@MainActor
final class ModelSetupSupportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ModelSetupSupportTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        SystemSettingsNavigator.openURL = { url in
            NSWorkspace.shared.open(url)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDownloadCommandTargetsSelectedFolder() throws {
        let folderURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var config = ModelsConfiguration.defaults
        try config.setModelLibraryURL(folderURL)

        let command = ModelSetupSupport.downloadCommand(for: .v2, config: config)

        XCTAssertTrue(command.contains("hf download FluidInference/parakeet-tdt-0.6b-v2-coreml"))
        XCTAssertTrue(command.contains("--local-dir '\(folderURL.path)/parakeet-tdt-0.6b-v2'"))
        XCTAssertTrue(command.contains("--include \"JointDecision.mlmodelc/*\""))
    }

    func testDownloadCommandShellQuotesSelectedFolderPath() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kalam model 'drop' \(UUID().uuidString) ; $HOME", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        var config = ModelsConfiguration.defaults
        try config.setModelLibraryURL(folderURL)

        let command = ModelSetupSupport.downloadCommand(for: .v2, config: config)
        let expectedDestination = "'\(folderURL.path.replacingOccurrences(of: "'", with: "'\\''"))/parakeet-tdt-0.6b-v2'"

        XCTAssertTrue(command.contains("--local-dir \(expectedDestination)"))
        XCTAssertFalse(command.contains("--local-dir \(folderURL.path)/parakeet-tdt-0.6b-v2"))
    }

    func testDownloadCommandShellQuotesUnicodeAndLeadingHyphenPaths() throws {
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("-模型 😀\nfolder", isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folderURL) }

        var config = ModelsConfiguration.defaults
        try config.setModelLibraryURL(folderURL)

        let command = ModelSetupSupport.downloadCommand(for: .v3, config: config)
        let expectedDestination = "'\(folderURL.path)/parakeet-tdt-0.6b-v3'"

        XCTAssertTrue(command.contains("--local-dir \(expectedDestination)"))
    }

    func testDownloadCommandUsesV3JointModelName() throws {
        let folderURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        var config = ModelsConfiguration.defaults
        try config.setModelLibraryURL(folderURL)

        let command = ModelSetupSupport.downloadCommand(for: .v3, config: config)

        XCTAssertTrue(command.contains("hf download FluidInference/parakeet-tdt-0.6b-v3-coreml"))
        XCTAssertTrue(command.contains("--include \"JointDecisionv3.mlmodelc/*\""))
        XCTAssertFalse(command.contains("--include \"JointDecision.mlmodelc/*\""))
    }

    func testSelectedModelRepoFolderVersionDetectsKnownRepoFolder() {
        let repoURL = URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3", isDirectory: true)

        XCTAssertEqual(ModelSetupSupport.selectedModelRepoFolderVersion(for: repoURL), .v3)
    }

    func testLoadPersistedNormalizedSelectedModelPromotesInstalledVersion() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelSetupSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let modelURL = rootURL.appendingPathComponent(ASRModelVersion.v3.repositoryFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for modelDirectoryName in ASRModelVersion.v3.requiredModelDirectoryNames {
            try FileManager.default.createDirectory(
                at: modelURL.appendingPathComponent(modelDirectoryName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        FileManager.default.createFile(atPath: modelURL.appendingPathComponent("parakeet_vocab.json").path, contents: Data("{}".utf8))

        var config = ModelsConfiguration.defaults
        config.asrVersion = .v2
        try config.setModelLibraryURL(rootURL)
        config.save(to: defaults)

        let normalized = ModelSetupSupport.loadPersistedNormalizedSelectedModel(from: defaults)

        XCTAssertEqual(normalized.asrVersion, .v3)
        XCTAssertEqual(ModelsConfiguration.load(from: defaults).asrVersion, .v3)
    }

    func testLoadRefreshesStaleModelLibraryBookmark() throws {
        let staleBookmark = Data([0x01, 0x02, 0x03])
        let refreshedBookmark = Data([0x04, 0x05, 0x06])
        let resolvedURL = URL(fileURLWithPath: "/tmp/kalam-models", isDirectory: true)
        let config = ModelsConfiguration(
            asrVersion: .v2,
            modelLibraryBookmarkData: staleBookmark,
            textCleanup: .defaults
        )
        config.save(to: defaults)

        let loaded = ModelsConfiguration.load(
            from: defaults,
            resolveBookmark: { data in
                XCTAssertEqual(data, staleBookmark)
                return (resolvedURL, true)
            },
            makeBookmark: { url in
                XCTAssertEqual(url, resolvedURL.standardizedFileURL)
                return refreshedBookmark
            }
        )

        XCTAssertEqual(loaded.modelLibraryBookmarkData, refreshedBookmark)
        XCTAssertEqual(defaults.data(forKey: "models.modelLibraryBookmark"), refreshedBookmark)
    }

    func testLoadClearsUnresolvableModelLibraryBookmark() throws {
        let invalidBookmark = Data([0x09, 0x08, 0x07])
        let config = ModelsConfiguration(
            asrVersion: .v2,
            modelLibraryBookmarkData: invalidBookmark,
            textCleanup: .defaults
        )
        config.save(to: defaults)

        let loaded = ModelsConfiguration.load(
            from: defaults,
            resolveBookmark: { _ in
                throw CocoaError(.fileNoSuchFile)
            },
            makeBookmark: { _ in
                XCTFail("Unresolvable bookmarks should not be refreshed")
                return Data()
            }
        )

        XCTAssertNil(loaded.modelLibraryBookmarkData)
        XCTAssertNil(defaults.data(forKey: "models.modelLibraryBookmark"))
    }

    func testSystemSettingsNavigatorPrefersLegacyAccessibilityDeepLink() {
        var openedURLs: [URL] = []
        SystemSettingsNavigator.openURL = { url in
            openedURLs.append(url)
            return true
        }

        XCTAssertTrue(SystemSettingsNavigator.open(.accessibility))
        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            ["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]
        )
    }

    func testSystemSettingsNavigatorFallsBackToExtensionDeepLinkWhenNeeded() {
        var openedURLs: [URL] = []
        SystemSettingsNavigator.openURL = { url in
            openedURLs.append(url)
            return openedURLs.count > 1
        }

        XCTAssertTrue(SystemSettingsNavigator.open(.microphone))
        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Microphone",
            ]
        )
    }

    func testSystemSettingsNavigatorFallsBackToRootSettingsWhenAllDeepLinksFail() {
        var openedURLs: [URL] = []
        SystemSettingsNavigator.openURL = { url in
            openedURLs.append(url)
            return url.absoluteString == "x-apple.systempreferences:"
        }

        XCTAssertTrue(SystemSettingsNavigator.open(.accessibility))
        XCTAssertEqual(
            openedURLs.map(\.absoluteString),
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility",
                "x-apple.systempreferences:",
            ]
        )
    }

    // MARK: - Per-file manifest (v3 adoption Task 6)

    func testRequiredModelFilesMatchFluidAudioValidatorSource() {
        // The manifest must be derived from the same ModelNames.ASR source the
        // FluidAudio validator uses — assert against the source itself, not
        // literals, so a FluidAudio upgrade that changes the required set fails
        // loudly here instead of silently lying in the UI.
        for version in ASRModelVersion.allCases {
            let files = ModelSetupSupport.requiredModelFiles(for: version)
            let faVersion = version.fluidAudioVersion

            var expected: Set<String>
            if faVersion == .v3 {
                expected = ModelNames.ASR.requiredModelsV3(precision: .int8)
            } else if faVersion.hasFusedEncoder {
                expected = ModelNames.ASR.requiredModelsFused
            } else {
                expected = ModelNames.ASR.requiredModels
            }
            expected.insert(ModelNames.ASR.vocabularyFile)

            XCTAssertEqual(Set(files), expected, "\(version) manifest drifted from FluidAudio's required set")
            XCTAssertTrue(files.contains(ModelNames.ASR.vocabularyFile), "\(version) manifest must include the vocab file")
            XCTAssertFalse(files.isEmpty)
        }
    }

    func testManifestMapsPresencePerFile() {
        let library = URL(fileURLWithPath: "/tmp/KalamLib", isDirectory: true)
        let repoPath = library.deletingLastPathComponent()
            .appendingPathComponent("parakeet-tdt-0.6b-v2")
        let files = ModelSetupSupport.requiredModelFiles(for: .v2)
        precondition(files.count >= 2)

        // First file present, everything else missing.
        let present = Set([repoPath.appendingPathComponent(files[0]).path])
        let manifest = ModelSetupSupport.modelFileManifest(
            for: .v2,
            libraryURL: library,
            fileExists: { present.contains($0) }
        )

        XCTAssertEqual(manifest.count, files.count)
        XCTAssertTrue(manifest[0].isPresent)
        XCTAssertTrue(manifest.dropFirst().allSatisfy { !$0.isPresent })
        XCTAssertEqual(manifest[0].name, files[0])
    }

    func testManifestEmptyWhenLibraryNotConfigured() {
        let manifest = ModelSetupSupport.modelFileManifest(
            for: .v2,
            libraryURL: nil,
            fileExists: { _ in true }
        )
        XCTAssertTrue(manifest.isEmpty)
    }

    func testRefinedAvailabilityPromotesPartialWhenSomeFilesArrived() {
        let manifest = [
            ASRModelFileEntry(name: "a.mlmodelc", isPresent: true),
            ASRModelFileEntry(name: "b.mlmodelc", isPresent: true),
            ASRModelFileEntry(name: "c.mlmodelc", isPresent: false),
        ]
        let refined = ModelSetupSupport.refinedAvailability(
            base: .invalidModelFolder(expectedPath: "/tmp/lib/parakeet-tdt-0.6b-v2"),
            manifest: manifest
        )
        XCTAssertEqual(
            refined,
            .partial(expectedPath: "/tmp/lib/parakeet-tdt-0.6b-v2", missing: ["c.mlmodelc"], total: 3)
        )
    }

    func testRefinedAvailabilityKeepsInvalidWhenNothingArrived() {
        let manifest = [
            ASRModelFileEntry(name: "a.mlmodelc", isPresent: false),
            ASRModelFileEntry(name: "b.mlmodelc", isPresent: false),
        ]
        let refined = ModelSetupSupport.refinedAvailability(
            base: .invalidModelFolder(expectedPath: "/tmp/lib/parakeet-tdt-0.6b-v2"),
            manifest: manifest
        )
        XCTAssertEqual(refined, .invalidModelFolder(expectedPath: "/tmp/lib/parakeet-tdt-0.6b-v2"))
    }

    func testRefinedAvailabilityLeavesOtherCasesUntouched() {
        let manifest = [ASRModelFileEntry(name: "a.mlmodelc", isPresent: true)]
        XCTAssertEqual(
            ModelSetupSupport.refinedAvailability(base: .installed(path: "/x"), manifest: manifest),
            .installed(path: "/x")
        )
        XCTAssertEqual(
            ModelSetupSupport.refinedAvailability(base: .modelLibraryNotConfigured, manifest: []),
            .modelLibraryNotConfigured
        )
    }

    func testPartialStatusLabelShowsArrivalCount() {
        let availability = ASRModelAvailability.partial(
            expectedPath: "/tmp/lib/parakeet-tdt-0.6b-v2",
            missing: ["JointDecision.mlmodelc"],
            total: 5
        )
        XCTAssertEqual(availability.statusLabel, "4/5")
        XCTAssertFalse(availability.isInstalled)
    }
}
