import Foundation
@preconcurrency import FluidAudio

// MARK: - ASR Model Version

public enum ASRModelVersion: String, CaseIterable, Identifiable, Sendable {
    case v2 = "v2"
    case v3 = "v3"
    case tdtCtc110m = "110m"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .v2:
            return "Parakeet TDT v2 (English-only)"
        case .v3:
            return "Parakeet TDT v3 (Multilingual - 25+ languages)"
        case .tdtCtc110m:
            return "Parakeet TDT-CTC 110M (Lightweight)"
        }
    }
    
    
    public var description: String {
        switch self {
        case .v2:
            return "English only • Highest accuracy • 2.1% WER"
        case .v3:
            return "25 European languages • 2.5% WER"
        case .tdtCtc110m:
            return "Fastest • Lower memory usage • 3.6% WER"
        }
    }
    
    public var fluidAudioVersion: AsrModelVersion {
        switch self {
        case .v2:
            return .v2
        case .v3:
            return .v3
        case .tdtCtc110m:
            return .tdtCtc110m
        }
    }
    
    public var modelSize: String {
        switch self {
        case .v2, .v3: return "~600 MB"
        case .tdtCtc110m: return "~110 MB"
        }
    }

    var repositoryFolderName: String {
        switch self {
        case .v2:
            return "parakeet-tdt-0.6b-v2"
        case .v3:
            return "parakeet-tdt-0.6b-v3"
        case .tdtCtc110m:
            return "parakeet-tdt-110m"
        }
    }

    public var requiredModelDirectoryNames: [String] {
        switch self {
        case .v2:
            return [
                "Preprocessor.mlmodelc",
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecision.mlmodelc",
            ]
        case .v3:
            return [
                "Preprocessor.mlmodelc",
                "Encoder.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecisionv3.mlmodelc",
            ]
        case .tdtCtc110m:
            return [
                "Preprocessor.mlmodelc",
                "Decoder.mlmodelc",
                "JointDecision.mlmodelc",
            ]
        }
    }
}

enum ASRModelAvailability: Equatable, Sendable {
    case modelLibraryNotConfigured
    case missingModelFolder(expectedPath: String)
    case invalidModelFolder(expectedPath: String)
    case installed(path: String)

    var isInstalled: Bool {
        if case .installed = self {
            return true
        }
        return false
    }

    var statusLabel: String {
        switch self {
        case .modelLibraryNotConfigured:
            return "No library"
        case .missingModelFolder:
            return "Missing"
        case .invalidModelFolder:
            return "Invalid"
        case .installed:
            return "Installed"
        }
    }
}

// MARK: - Models Configuration

struct ModelsConfiguration: Equatable, Sendable {
    typealias BookmarkResolver = (Data) throws -> (url: URL, isStale: Bool)
    typealias BookmarkCreator = (URL) throws -> Data

    static let defaults = ModelsConfiguration(
        asrVersion: .v2,
        modelLibraryBookmarkData: nil,
        textCleanup: .defaults
    )
    
    var asrVersion: ASRModelVersion
    var modelLibraryBookmarkData: Data?
    var textCleanup: TextCleanupConfiguration
    
    private static let userDefaultsASRVersionKey = "models.asrVersion"
    private static let userDefaultsModelLibraryBookmarkKey = "models.modelLibraryBookmark"
    
    static func load(
        from defaults: UserDefaults = .standard,
        resolveBookmark: BookmarkResolver = Self.resolveSecurityScopedBookmark,
        makeBookmark: BookmarkCreator = Self.makeSecurityScopedBookmark
    ) -> ModelsConfiguration {
        let versionRaw = defaults.string(forKey: userDefaultsASRVersionKey)
        let version = versionRaw.flatMap(ASRModelVersion.init(rawValue:)) ?? Self.defaults.asrVersion
        let storedBookmarkData = defaults.data(forKey: userDefaultsModelLibraryBookmarkKey)
        let modelLibraryBookmarkData: Data?
        if let resolvedBookmark = resolvedModelLibraryBookmark(
            from: storedBookmarkData,
            resolveBookmark: resolveBookmark,
            makeBookmark: makeBookmark
        ) {
            modelLibraryBookmarkData = resolvedBookmark.bookmarkData
            if resolvedBookmark.bookmarkData != storedBookmarkData {
                defaults.set(resolvedBookmark.bookmarkData, forKey: userDefaultsModelLibraryBookmarkKey)
            }
        } else {
            modelLibraryBookmarkData = nil
            if storedBookmarkData != nil {
                defaults.removeObject(forKey: userDefaultsModelLibraryBookmarkKey)
            }
        }
        
        return ModelsConfiguration(
            asrVersion: version,
            modelLibraryBookmarkData: modelLibraryBookmarkData,
            textCleanup: TextCleanupConfiguration.load(from: defaults)
        )
    }
    
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(asrVersion.rawValue, forKey: Self.userDefaultsASRVersionKey)
        defaults.set(modelLibraryBookmarkData, forKey: Self.userDefaultsModelLibraryBookmarkKey)
        textCleanup.save(to: defaults)
    }

    var modelLibraryURL: URL? {
        Self.resolveModelLibraryURL(from: modelLibraryBookmarkData)
    }

    mutating func setModelLibraryURL(_ url: URL?) throws {
        guard let url else {
            modelLibraryBookmarkData = nil
            return
        }
        let bookmark = try url.standardizedFileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        modelLibraryBookmarkData = bookmark
    }

    func modelDirectoryURL(for version: ASRModelVersion) -> URL? {
        guard let modelLibraryURL else { return nil }
        return modelLibraryURL.appendingPathComponent(version.repositoryFolderName, isDirectory: true)
    }

    func availability(for version: ASRModelVersion) -> ASRModelAvailability {
        guard let modelLibraryURL else {
            return .modelLibraryNotConfigured
        }

        return Self.withSecurityScopedAccess(to: modelLibraryURL) {
            let expectedDirectory = modelLibraryURL.appendingPathComponent(version.repositoryFolderName, isDirectory: true)
            var isDirectory: ObjCBool = false
            let fileExists = FileManager.default.fileExists(atPath: expectedDirectory.path, isDirectory: &isDirectory)
            if !fileExists || !isDirectory.boolValue {
                return .missingModelFolder(expectedPath: expectedDirectory.path)
            }

            let exists = AsrModels.modelsExist(at: expectedDirectory, version: version.fluidAudioVersion)
            if !exists {
                return .invalidModelFolder(expectedPath: expectedDirectory.path)
            }

            return .installed(path: expectedDirectory.path)
        }
    }

    static func resolveModelLibraryURL(from bookmarkData: Data?) -> URL? {
        resolvedModelLibraryBookmark(from: bookmarkData)?.url
    }

    struct ResolvedModelLibraryBookmark: Equatable {
        let url: URL
        let bookmarkData: Data
    }

    static func resolvedModelLibraryBookmark(
        from bookmarkData: Data?,
        resolveBookmark: BookmarkResolver = Self.resolveSecurityScopedBookmark,
        makeBookmark: BookmarkCreator = Self.makeSecurityScopedBookmark
    ) -> ResolvedModelLibraryBookmark? {
        guard let bookmarkData else { return nil }

        do {
            let resolved = try resolveBookmark(bookmarkData)
            let url = resolved.url.standardizedFileURL
            let bookmarkData = resolved.isStale ? try makeBookmark(url) : bookmarkData
            return ResolvedModelLibraryBookmark(url: url, bookmarkData: bookmarkData)
        } catch {
            return nil
        }
    }

    private static func resolveSecurityScopedBookmark(_ bookmarkData: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    private static func makeSecurityScopedBookmark(for url: URL) throws -> Data {
        try url.standardizedFileURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func withSecurityScopedAccess<T>(to url: URL, _ operation: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try operation()
    }

    static func withSecurityScopedAccess<T>(to url: URL, _ operation: () async throws -> T) async rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try await operation()
    }
}

// MARK: - Notification

extension Notification.Name {
    static let modelsConfigurationDidChange = Notification.Name("modelsConfigurationDidChange")
}
