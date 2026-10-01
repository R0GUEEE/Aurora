import XCTest
@testable import AuroraCore

final class ProcessRunnerTests: XCTestCase {
    func testStandardInputCompletesAndOutputIsDrained() throws {
        let payload = Data(repeating: 0x61, count: 256 * 1024)
        let result = try ProcessRunner.run(executable: "/bin/cat", standardInput: payload)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, payload)
    }

    func testStandardOutputLimitStopsAChattyChild() {
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/bin/cat",
            standardInput: Data(repeating: 0x61, count: 4096),
            maximumOutputBytes: 64
        )) { error in
            guard case ProcessError.outputLimitExceeded(64) = error else {
                return XCTFail("expected output-limit error, got \(error)")
            }
        }
    }
}
