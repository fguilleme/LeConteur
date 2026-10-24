import XCTest
import Foundation
import CryptoKit
@testable import LeConteur

@MainActor final class VoiceDownloadTests: XCTestCase {
    func testBackgroundConfigurationKeepsTransfersOutsideAppOnWiFi() {
        let config = VoiceDownloads.configuration()
        XCTAssertEqual(config.identifier, "com.guilleme.conteur.voice-downloads.v1")
        XCTAssertTrue(config.sessionSendsLaunchEvents)
        XCTAssertFalse(config.isDiscretionary)
        XCTAssertFalse(config.allowsCellularAccess)
        XCTAssertTrue(config.waitsForConnectivity)
        XCTAssertGreaterThan(config.timeoutIntervalForResource, 86_400)
    }

    func testRecoversStagedFilesAndWaitsBeforeBackgroundCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.stage(index: 0)
        try VoiceDownloadDisk.write(fixture.data[1], to: fixture.spec.directory.appending(path: fixture.spec.files[1].path))
        let downloader = fixture.downloader()
        defer { downloader.closeForTesting() }
        var completed = false
        downloader.handleBackgroundEvents { completed = true }
        downloader.finishedEvents() // May arrive before asynchronous recovery returns.
        XCTAssertFalse(completed)
        try await wait { downloader.snapshot("test").installed && completed }
        XCTAssertEqual(downloader.snapshot("test").progress, 1)
        XCTAssertFalse(downloader.snapshot("test").busy)
        XCTAssertTrue(fixture.spec.isInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.incoming(0).path))
        let tasks = await downloader.testTransfers()
        XCTAssertTrue(tasks.isEmpty, "Restoration must not redownload already staged/verified bytes")
        #if !targetEnvironment(simulator)
        // The simulator's host filesystem does not implement iOS Data Protection.
        let protection = try FileManager.default.attributesOfItem(atPath: fixture.spec.directory.appending(path: "part0.bin").path)[.protectionKey] as? String
        XCTAssertEqual(protection, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        #endif
    }

    func testCorruptStagingNeverMarksModelInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.stage(index: 0, corrupt: true)
        try fixture.stage(index: 1)
        let downloader = fixture.downloader()
        defer { downloader.closeForTesting() }
        try await wait { downloader.snapshot("test").error != nil }
        XCTAssertFalse(fixture.spec.isInstalled)
        XCTAssertFalse(downloader.snapshot("test").busy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spec.directory.appending(path: "part0.bin").path))
    }

    func testCancelRejectsLateFilesAcrossRelaunchAndKeepsValidFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try VoiceDownloadDisk.write(fixture.data[0], to: fixture.spec.directory.appending(path: "part0.bin"))
        try fixture.stage(index: 1)
        let downloader = fixture.downloader()
        downloader.cancel("test")
        defer { downloader.closeForTesting() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(fixture.spec.isInstalled)
        XCTAssertFalse(downloader.snapshot("test").busy)
        XCTAssertEqual(try Data(contentsOf: fixture.spec.directory.appending(path: "part0.bin")), fixture.data[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.spec.directory.appending(path: "part1.bin").path))
        let restored = fixture.downloader()
        defer { restored.closeForTesting() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(restored.snapshot("test").busy, "A cancelled download must not silently restart")
        let tasks = await restored.testTransfers()
        XCTAssertTrue(tasks.isEmpty)
    }

    func testAllMissingFilesAreScheduledBeforeFirstCompletes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let downloader = fixture.downloader()
        defer { downloader.closeForTesting() }
        try await wait {
            let tasks = await downloader.testTransfers()
            return tasks.count == 2
        }
        let tasks = await downloader.testTransfers()
        XCTAssertEqual(Set(tasks.compactMap { VoiceDownloadTag($0.taskDescription)?.path }), Set(fixture.spec.files.map(\.path)))
        XCTAssertTrue(downloader.snapshot("test").busy)
        downloader.cancel("test")
        try await wait { await downloader.testTransfers().isEmpty }
        XCTAssertFalse(downloader.snapshot("test").busy)
    }

    private func wait(_ predicate: @escaping @MainActor () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        let fulfilled = await predicate()
        XCTAssertTrue(fulfilled)
    }

    private struct Fixture {
        let root = URL.temporaryDirectory.appending(path: "voice-download-test-\(UUID())")
        let data = [Data(repeating: 42, count: 200_000), Data(repeating: 51, count: 100_000)]
        let spec: VoiceDownloadSpec
        let plan: VoiceDownloadPlan
        init() throws {
            spec = VoiceDownloadSpec(id: "test", revision: "v1", directory: root.appending(path: "model"), marker: "verified", files: data.enumerated().map { index, data in
                .init(path: "part\(index).bin", url: URL(string: "https://example.invalid/part\(index)")!, bytes: Int64(data.count),
                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
            })
            plan = VoiceDownloadPlan(revision: "v1")
            try VoiceDownloadDisk.write(JSONEncoder().encode(["test": plan]), to: root.appending(path: "plans.json"))
        }
        func incoming(_ index: Int) -> URL { root.appending(path: "Incoming/\(index).download") }
        func stage(index: Int, corrupt: Bool = false) throws {
            let tag = VoiceDownloadTag(model: "test", generation: plan.generation, path: spec.files[index].path)
            try VoiceDownloadDisk.write(corrupt ? Data(repeating: 0, count: data[index].count) : data[index], to: incoming(index))
            try VoiceDownloadDisk.write(Data(tag.encoded.utf8), to: root.appending(path: "Incoming/\(index).json"))
        }
        @MainActor func downloader() -> VoiceDownloads {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [WaitingDownloadProtocol.self]
            return VoiceDownloads(specs: [spec], root: root, configuration: config)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private final class WaitingDownloadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {} // Deterministically hold the transfer without network I/O.
    override func stopLoading() {}
}
