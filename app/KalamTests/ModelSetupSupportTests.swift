import XCTest
@testable import Kalam_test

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
        XCTAssertTrue(command.contains("--local-dir \(folderURL.path)/parakeet-tdt-0.6b-v2-coreml"))
    }

    func testSelectedModelRepoFolderVersionDetectsKnownRepoFolder() {
        let repoURL = URL(fileURLWithPath: "/tmp/parakeet-tdt-0.6b-v3-coreml", isDirectory: true)

        XCTAssertEqual(ModelSetupSupport.selectedModelRepoFolderVersion(for: repoURL), .v3)
    }

    func testLoadPersistedNormalizedSelectedModelPromotesInstalledVersion() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelSetupSupportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let modelURL = rootURL.appendingPathComponent(ASRModelVersion.v3.repositoryFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelURL.appendingPathComponent("Preprocessor.mlmodelc", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelURL.appendingPathComponent("Encoder.mlmodelc", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelURL.appendingPathComponent("Decoder.mlmodelc", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelURL.appendingPathComponent("JointDecision.mlmodelc", isDirectory: true), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: modelURL.appendingPathComponent("parakeet_vocab.json").path, contents: Data("{}".utf8))

        var config = ModelsConfiguration.defaults
        config.asrVersion = .v2
        try config.setModelLibraryURL(rootURL)
        config.save(to: defaults)

        let normalized = ModelSetupSupport.loadPersistedNormalizedSelectedModel(from: defaults)

        XCTAssertEqual(normalized.asrVersion, .v3)
        XCTAssertEqual(ModelsConfiguration.load(from: defaults).asrVersion, .v3)
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
}
