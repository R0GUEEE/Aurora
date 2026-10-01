import XCTest
@testable import AuroraCore

final class HTTPDownloaderTests: XCTestCase {

    func testPackageDownloadFallsBackForURLFileIOErrors() {
        for code in -3005 ... -3000 {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(
                HTTPDownloader.shouldFallbackToStreamingDownload(error),
                "expected NSURLErrorDomain \(code) to use the streaming fallback"
            )
        }
    }

    func testPackageDownloadDoesNotFallbackForNetworkErrors() {
        for code in [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorCancelled,
        ] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertFalse(
                HTTPDownloader.shouldFallbackToStreamingDownload(error),
                "network error \(code) should not be hidden by a file-I/O retry"
            )
        }
        XCTAssertFalse(
            HTTPDownloader.shouldFallbackToStreamingDownload(
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            )
        )
    }
}
