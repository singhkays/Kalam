import XCTest
@testable import Kalam_test

final class KalamEngineIntegrationTests: XCTestCase {
    
    struct TestCase: Codable {
        let name: String
        let input: String
        let expected: String
        let description: String
    }
    
    func testGoldenCases() throws {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "engine_golden_tests", withExtension: "json") else {
            XCTFail("Missing engine_golden_tests.json in test bundle")
            return
        }
        
        do {
            let data = try Data(contentsOf: url)
            print("KalamTests: Data loaded successfully (\(data.count) bytes)")
            
            let cases = try JSONDecoder().decode([TestCase].self, from: data)
            print("KalamTests: Decoded \(cases.count) test cases")
            
            for testCase in cases {
                XCTContext.runActivity(named: "Running Test Case: \(testCase.name)") { _ in
                    print("\n--- Running Test Case: \(testCase.name) ---")
                    print("Description: \(testCase.description)")
                    
                    let result = KalamTestRunner.shared.runTextPipeline(testCase.input)
                    result.printSummary()
                    
                    XCTAssertEqual(result.final.lowercased(), testCase.expected.lowercased(), "Test case '\(testCase.name)' failed.")
                }
            }
        } catch {
            print("KalamTests: FATAL ERROR during test setup: \(error)")
            XCTFail("Fatal error during test setup: \(error)")
        }
    }
}
