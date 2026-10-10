import CryptoKit
import XCTest
import ClickyCore
@testable import ClickyGuideNative

/// `LocalAIRuntime` against the fake worker process and a synthetic catalog installed into a temporary store.
@MainActor
final class LocalAIRuntimeTests: XCTestCase {
    private var root: URL!
    private var pressure: AsyncStream<LocalMemoryPressure>.Continuation!
    private var launches: [LocalWorkerRole] = []
    private var behaviors: [LocalWorkerRole: String] = [:]
    private var thermal = ProcessInfo.ThermalState.nominal
    private var runtimes: [LocalAIRuntime] = []
    private var clock: TimeInterval = 0

    private static func entry(_ id: String, _ group: LocalModelGroup, _ kind: LocalModelKind, _ sha: String) -> LocalModelCatalogEntry {
        LocalModelCatalogEntry(id: id, displayName: "Test \(id)", kind: kind, group: group, repository: "test/\(id)", revision: "rev1",
                               sourceSubdirectory: nil, installSubdirectory: nil, license: "MIT", quantization: "4-bit", notes: "",
                               files: [LocalModelFile(path: "weights.bin", size: 7, sha256: sha)])
    }

    private lazy var catalog: [LocalModelCatalogEntry] = {
        let sha = SHA256.hash(data: Data("weights".utf8)).map { String(format: "%02x", $0) }.joined()
        return [Self.entry("test-vision-a", .vision, .mlxVLM, sha), Self.entry("test-vision-b", .vision, .mlxVLM, sha),
                Self.entry("test-cleanup", .cleanup, .mlxLLM, sha), Self.entry("test-speech", .speech, .parakeetCoreML, sha)]
    }()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-localai-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for runtime in runtimes { runtime.shutdown() }
        runtimes = []
        pressure?.finish()
        try? FileManager.default.removeItem(at: root)
    }

    private func environment() -> LocalAIEnvironment {
        let worker = Bundle(for: LocalAIRuntimeTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("clicky-fake-worker")
        let (stream, continuation) = AsyncStream<LocalMemoryPressure>.makeStream()
        pressure = continuation
        return LocalAIEnvironment(
            workerExecutable: { worker },
            makeConnection: { [unowned self] url, role, onExit in
                launches.append(role)
                return LocalWorkerConnection(executable: url, role: role,
                                             arguments: ["--role", role.rawValue, "--behavior", behaviors[role] ?? "normal"],
                                             environment: [:], handshakeTimeout: 5, cancelGrace: 1, onExit: onExit)
            },
            modelsRoot: root.appendingPathComponent("Models"), benchmarksRoot: root.appendingPathComponent("Benchmarks"),
            catalog: catalog, now: { [unowned self] in clock }, physicalMemory: 64 << 30, memoryPressure: { stream },
            thermalState: { [unowned self] in thermal }, hostFootprint: { 1 })
    }

    /// A runtime whose catalog entries are all imported into the temporary store.
    private func makeRuntime(installed ids: [String] = ["test-vision-a", "test-vision-b", "test-cleanup", "test-speech"]) async throws -> LocalAIRuntime {
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("weights.bin"))
        let defaults = UserDefaults(suiteName: "clicky.localai.tests." + UUID().uuidString)!
        let env = environment()
        let store = LocalModelStore(root: env.modelsRoot)
        for entry in catalog where ids.contains(entry.id) { _ = try await store.importFolder(source, as: entry) }
        let runtime = LocalAIRuntime(environment: env, preferences: defaults)
        runtimes.append(runtime)
        return runtime
    }

    private func eventually(_ message: String = "condition", timeout: TimeInterval = 8, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out waiting for \(message)")
    }

    func testManualPolicyStartsNoWorkerAndLoadsNothing() async throws {
        let runtime = try await makeRuntime()
        await runtime.startupPreload()
        XCTAssertTrue(launches.isEmpty)
        XCTAssertTrue(LocalModelGroup.allCases.allSatisfy { !runtime.isLoaded($0) })
        XCTAssertEqual(runtime.workers[.inference], .stopped)
        XCTAssertEqual(runtime.workers[.speech], .stopped)
        XCTAssertEqual(runtime.groups[.vision]?.phase, .installed)
        XCTAssertEqual(runtime.groups[.vision]?.selectedEntryID, "test-vision-a")
    }

    func testPreloadAtStartupOnlyLoadsOptedInGroups() async throws {
        let runtime = try await makeRuntime()
        runtime.residency.speech.load = .preloadAtStartup
        await runtime.startupPreload()
        XCTAssertEqual(launches, [.speech])
        XCTAssertTrue(runtime.isLoaded(.speech))
        XCTAssertFalse(runtime.isLoaded(.vision))
        XCTAssertEqual(runtime.groups[.speech]?.phase, .ready)
        XCTAssertEqual(runtime.workers[.inference], .stopped)
    }

    func testManualPolicyRequiresExplicitLoadButExplicitRunLoads() async throws {
        let runtime = try await makeRuntime()
        do { try await runtime.ensureReady(.vision, explicitRun: false); XCTFail("expected needsExplicitLoad") }
        catch let error as LocalAIError {
            XCTAssertEqual(error, .needsExplicitLoad("Test test-vision-a"))
            XCTAssertEqual(error.errorDescription, "Load Test test-vision-a first.")
        }
        XCTAssertTrue(launches.isEmpty)
        try await runtime.ensureReady(.vision, explicitRun: true)
        XCTAssertTrue(runtime.isLoaded(.vision))
        XCTAssertEqual(launches, [.inference])
    }

    func testOnDemandPolicyLoadsAutomatically() async throws {
        let runtime = try await makeRuntime()
        runtime.residency.cleanup.load = .onDemand
        try await runtime.ensureReady(.cleanup, explicitRun: false)
        XCTAssertTrue(runtime.isLoaded(.cleanup))
    }

    func testSelectingAnotherModelDuringLoadCancelsAndLeavesItUnloaded() async throws {
        let runtime = try await makeRuntime()
        let loading = Task { try? await runtime.load(.vision) }
        await Task.yield()
        XCTAssertEqual(runtime.groups[.vision]?.phase, .loading)
        await runtime.select("test-vision-b", for: .vision)
        await loading.value
        XCTAssertEqual(runtime.groups[.vision]?.selectedEntryID, "test-vision-b")
        XCTAssertFalse(runtime.isLoaded(.vision))
        XCTAssertEqual(runtime.groups[.vision]?.phase, .installed)
        await eventually("worker stopped") { runtime.workers[.inference] == .stopped }
        XCTAssertEqual(runtime.activeJobs.count, 0)
    }

    func testSelectUnloadsLoadedModelFirst() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        XCTAssertEqual(runtime.loadedReference(.vision)?.identifier, "test-vision-a")
        await runtime.select("test-vision-b", for: .vision)
        XCTAssertFalse(runtime.isLoaded(.vision))
        XCTAssertEqual(runtime.workers[.inference], .stopped)
    }

    func testUnloadStopsWorkerOnlyWhenLastModelOfRoleUnloads() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        try await runtime.load(.cleanup)
        XCTAssertEqual(launches, [.inference], "vision and cleanup share one inference worker")
        await runtime.unload(.vision)
        if case .ready = runtime.workers[.inference] {} else { XCTFail("worker should stay while cleanup is loaded") }
        await runtime.unload(.cleanup)
        XCTAssertEqual(runtime.workers[.inference], .stopped)
        XCTAssertEqual(runtime.groups[.cleanup]?.phase, .installed)
    }

    func testWorkerCrashFailsJobAndGroupsWithoutRestart() async throws {
        behaviors[.inference] = "crashOnGenerate"
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        try await runtime.load(.cleanup)
        var failures = 0
        do {
            for try await _ in runtime.generate(group: .vision, messages: [LocalChatMessage(role: .user, text: "hi")], parameters: LocalGenerationParameters()) {}
        } catch { failures += 1 }
        XCTAssertEqual(failures, 1)
        await eventually("groups failed") {
            runtime.groups[.vision]?.phase == .failed(LocalAIRuntime.crashMessage)
                && runtime.groups[.cleanup]?.phase == .failed(LocalAIRuntime.crashMessage)
        }
        XCTAssertEqual(runtime.workers[.inference], .failed(LocalAIRuntime.crashMessage))
        XCTAssertFalse(runtime.isLoaded(.vision))
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(launches, [.inference], "no automatic restart")
    }

    func testGenerateStreamsTextFromTheLoadedModel() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        var text = ""
        for try await event in runtime.generate(group: .vision, messages: [LocalChatMessage(role: .user, text: "hi")],
                                                imagePNG: Data([1, 2, 3]), parameters: LocalGenerationParameters()) {
            if case .delta(_, _, let piece) = event { text += piece }
        }
        XCTAssertEqual(text, "abc")
        XCTAssertEqual(runtime.groups[.vision]?.phase, .ready)
    }

    func testForegroundJobCancelsRunningBenchmarkJob() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let benchmark = Task { () -> Result<Int, Error> in
            do { return .success(try await runtime.perform(.vision, jobClass: .benchmark) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000); return 1 }) }
            catch { return .failure(error) }
        }
        await eventually("benchmark started") { runtime.activeJobs[.inference]?.jobClass == .benchmark }
        let foreground = try await runtime.perform(.vision, jobClass: .foreground) { _, _ in 42 }
        XCTAssertEqual(foreground, 42)
        guard case .failure(let error) = await benchmark.value else { return XCTFail("benchmark should have been canceled") }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(runtime.groups[.vision]?.phase, .ready)
    }

    func testSecondForegroundJobIsRefusedAsBusy() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let first = Task { try? await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        do { _ = try await runtime.perform(.vision) { _, _ in 1 }; XCTFail("expected busy") }
        catch let error as LocalAIError { XCTAssertEqual(error, .busy) }
        first.cancel()
        _ = await first.value
    }

    func testAssistantSlotWaitRunsAfterTheForegroundJobInsteadOfBusy() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let first = Task { try? await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 200_000_000) } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        let waited = try await runtime.perform(.vision, slotWait: 5) { _, _ in 7 }
        XCTAssertEqual(waited, 7)
        _ = await first.value
    }

    func testAssistantSlotWaitStillReportsBusyAfterItsDeadline() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let first = Task { try? await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        do { _ = try await runtime.perform(.vision, slotWait: 0.2) { _, _ in 1 }; XCTFail("expected busy") }
        catch let error as LocalAIError { XCTAssertEqual(error, .busy) }
        first.cancel()
        _ = await first.value
    }

    func testMemoryPressureWarningCancelsBenchmarkJobButNotForeground() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let benchmark = Task { () -> Bool in
            do { _ = try await runtime.perform(.vision, jobClass: .benchmark) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }; return false }
            catch { return error is CancellationError }
        }
        await eventually("benchmark started") { runtime.activeJobs[.inference]?.jobClass == .benchmark }
        pressure.yield(.warning)
        let canceled = await benchmark.value
        XCTAssertTrue(canceled)
        XCTAssertEqual(runtime.memory.pressure, .warning)
        XCTAssertTrue(runtime.isLoaded(.vision), "warning drops caches but keeps weights")
    }

    func testCriticalPressureUnloadsIdleGroups() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.cleanup)
        pressure.yield(.critical)
        await eventually("cleanup unloaded") { !runtime.isLoaded(.cleanup) && runtime.workers[.inference] == .stopped }
    }

    func testSeriousThermalStateRefusesBenchmarkJobs() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        thermal = .serious
        do { _ = try await runtime.perform(.vision, jobClass: .benchmark) { _, _ in 1 }; XCTFail("expected thermal refusal") }
        catch let error as LocalAIError {
            XCTAssertEqual(error, .thermal("serious"))
            XCTAssertTrue(error.errorDescription?.contains("let it cool down") == true)
        }
        let foreground = try await runtime.perform(.vision) { _, _ in 7 }
        XCTAssertEqual(foreground, 7)
    }

    func testIdleUnloadHonorsPolicyAndSkipsBusyGroups() async throws {
        let runtime = try await makeRuntime()
        runtime.residency.vision.idleUnloadMinutes = 5
        try await runtime.load(.vision)
        clock = 299
        await runtime.idleTick()
        XCTAssertTrue(runtime.isLoaded(.vision))
        clock = 301
        let job = Task { try? await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        await runtime.idleTick()
        XCTAssertTrue(runtime.isLoaded(.vision), "a running job keeps its weights")
        job.cancel()
        _ = await job.value
        clock = 700
        await runtime.idleTick()
        XCTAssertFalse(runtime.isLoaded(.vision))
        XCTAssertEqual(runtime.workers[.inference], .stopped)
    }

    func testRemoveIsRefusedWhileLoaded() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.speech)
        XCTAssertThrowsError(try runtime.remove(.speech))
        await runtime.unload(.speech)
        try runtime.remove(.speech)
        XCTAssertEqual(runtime.groups[.speech]?.phase, .missing)
    }

    func testSpeechPipelineRequiresLoadedSpeechAndCleanupIsOptional() async throws {
        let runtime = try await makeRuntime()
        XCTAssertThrowsError(try runtime.speechPipeline(cleanup: true))
        try await runtime.load(.speech)
        XCTAssertFalse(try runtime.speechPipeline(cleanup: true).canClean)
        try await runtime.load(.cleanup)
        let pipeline = try runtime.speechPipeline(cleanup: true)
        XCTAssertTrue(pipeline.canClean)
        let result = try await runtime.perform(.speech) { _, _ in try await pipeline.transcribe([Int16](repeating: 5, count: 1600)) }
        XCTAssertEqual(result.text, "samples=1600")
    }

    // MARK: Review hardening

    func testAssetOperationsAreRefusedWhileLoadedAndKeepThePhase() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        runtime.download(.vision)
        await runtime.importFolder(root.appendingPathComponent("source"), for: .vision)
        await runtime.verify(.vision)
        XCTAssertNil(runtime.downloadTasks[.vision])
        XCTAssertEqual(runtime.groups[.vision]?.phase, .ready)
        XCTAssertTrue(runtime.isLoaded(.vision))
        XCTAssertFalse(runtime.assetsFree(.vision))
        XCTAssertTrue(runtime.assetsFree(.speech))
    }

    func testVerifyWhenIdleSettlesBackToInstalled() async throws {
        let runtime = try await makeRuntime()
        await runtime.verify(.vision)
        XCTAssertEqual(runtime.groups[.vision]?.phase, .installed)
        XCTAssertNil(runtime.groups[.vision]?.lastError)
    }

    func testLoadIsRefusedWhileAnotherForegroundJobHoldsTheWorker() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let job = Task { try? await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        do { try await runtime.load(.cleanup); XCTFail("expected busy") }
        catch let error as LocalAIError { XCTAssertEqual(error, .busy) }
        XCTAssertEqual(runtime.groups[.cleanup]?.phase, .installed)
        XCTAssertFalse(runtime.isLoaded(.cleanup))
        job.cancel()
        _ = await job.value
        try await runtime.load(.cleanup)
        XCTAssertTrue(runtime.isLoaded(.cleanup))
    }

    func testForegroundLoadPreemptsBenchmarkJob() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let benchmark = Task { () -> Bool in
            do { _ = try await runtime.perform(.vision, jobClass: .benchmark) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }; return false }
            catch { return error is CancellationError }
        }
        await eventually("benchmark started") { runtime.activeJobs[.inference]?.jobClass == .benchmark }
        try await runtime.load(.cleanup)
        let wasCanceled = await benchmark.value
        XCTAssertTrue(wasCanceled)
        XCTAssertTrue(runtime.isLoaded(.cleanup))
    }

    func testLoadIsRefusedUnderCriticalMemoryPressure() async throws {
        let runtime = try await makeRuntime()
        pressure.yield(.critical)
        await eventually("critical pressure") { runtime.memory.pressure == .critical }
        do { try await runtime.load(.vision); XCTFail("expected refusal") }
        catch let error as LocalAIError {
            guard case .overBudget(let detail) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue(detail.contains("critical memory pressure"))
        }
        XCTAssertTrue(launches.isEmpty)
        pressure.yield(.normal)
        await eventually("pressure cleared") { runtime.memory.pressure == .normal }
        try await runtime.load(.vision)
        XCTAssertTrue(runtime.isLoaded(.vision))
    }

    func testUnloadHidesTheModelBeforeAwaitingTheRunningJob() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let job = Task { try? await runtime.perform(.vision) { _, _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            await Task.detached { Thread.sleep(forTimeInterval: 0.4) }.value
        } }
        await eventually("job started") { runtime.activeJobs[.inference] != nil }
        let unloading = Task { await runtime.unload(.vision) }
        await eventually("unloading") { runtime.groups[.vision]?.phase == .unloading }
        XCTAssertFalse(runtime.isLoaded(.vision))
        do { _ = try await runtime.perform(.vision) { _, _ in 1 }; XCTFail("expected notLoaded") }
        catch let error as LocalAIError { if case .notLoaded = error {} else { XCTAssertEqual(error, .busy) } }
        do { try await runtime.load(.vision); XCTFail("expected busy") }
        catch let error as LocalAIError { XCTAssertEqual(error, .busy) }
        await unloading.value
        _ = await job.value
        XCTAssertEqual(runtime.groups[.vision]?.phase, .installed)
    }

    func testOnlyOneOfTwoRacingForegroundJobsPreemptsTheBenchmark() async throws {
        let runtime = try await makeRuntime()
        try await runtime.load(.vision)
        let benchmark = Task { () -> Bool in
            do { _ = try await runtime.perform(.vision, jobClass: .benchmark) { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }; return false }
            catch { return error is CancellationError }
        }
        await eventually("benchmark started") { runtime.activeJobs[.inference]?.jobClass == .benchmark }
        func foreground() -> Task<Result<Int, Error>, Never> {
            Task {
                do { return .success(try await runtime.perform(.vision) { _, _ in try await Task.sleep(nanoseconds: 300_000_000); return 1 }) }
                catch { return .failure(error) }
            }
        }
        let first = foreground(), second = foreground()
        let outcomes = [await first.value, await second.value]
        let busy = outcomes.filter { if case .failure(let error) = $0 { return (error as? LocalAIError) == .busy }; return false }
        let succeeded = outcomes.filter { if case .success = $0 { return true }; return false }
        XCTAssertEqual(busy.count, 1)
        XCTAssertEqual(succeeded.count, 1)
        let wasCanceled = await benchmark.value
        XCTAssertTrue(wasCanceled)
    }

    func testCrashMessageDependsOnPolicyAndNeverReplays() async throws {
        behaviors[.inference] = "crashOnGenerate"
        let runtime = try await makeRuntime()
        runtime.residency.vision.load = .onDemand
        runtime.residency.cleanup.load = .onDemand
        try await runtime.load(.vision)
        do {
            for try await _ in runtime.generate(group: .vision, messages: [LocalChatMessage(role: .user, text: "hi")], parameters: LocalGenerationParameters()) {}
            XCTFail("generate should have failed")
        } catch {}
        await eventually("failed phase") { runtime.groups[.vision]?.phase == .failed(LocalAIRuntime.crashMessageOnDemand) }
        XCTAssertEqual(runtime.workers[.inference], .failed(LocalAIRuntime.crashMessageOnDemand))
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(launches, [.inference], "the failed request is not replayed and the worker is not restarted")
    }
}
