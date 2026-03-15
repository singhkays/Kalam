import XCTest
@testable import Kalam_test

final class ModelSetupSupportTests: XCTestCase {
    private func makeTemporaryExecutable(named name: String) throws -> URL {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let fileURL = tempDir.appendingPathComponent(name)
        let contents = "#!/bin/sh\necho hello\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        return fileURL
    }

    override func tearDown() {
        super.tearDown()
        ModelSetupSupport.clearCustomHuggingFaceCLIPath()
    }

    func testCustomCLIPathIsRespected() throws {
        let cliURL = try makeTemporaryExecutable(named: "hf-test-cli")

        ModelSetupSupport.huggingFaceCLICustomURL = cliURL
        XCTAssertEqual(ModelSetupSupport.huggingFaceCLICustomURL, cliURL)
        XCTAssertEqual(ModelSetupSupport.findHuggingFaceCLIPath(), cliURL)
        XCTAssertTrue(ModelSetupSupport.isHuggingFaceCLIAvailable())
    }

    func testClearCustomCLIPathRemovesOverride() throws {
        let cliURL = try makeTemporaryExecutable(named: "hf-test-cli-2")
        ModelSetupSupport.huggingFaceCLICustomURL = cliURL
        XCTAssertNotNil(ModelSetupSupport.huggingFaceCLICustomURL)

        ModelSetupSupport.clearCustomHuggingFaceCLIPath()
        XCTAssertNil(ModelSetupSupport.huggingFaceCLICustomURL)
    }
}
