import Darwin
import Foundation
import MaintenanceCore
import SoftwareInventoryCore

struct CheckRunner {
    private var failures = 0

    mutating func run() -> Int32 {
        checkPaths()
        checkProcessUsage()
        checkSessionsAndRepositories()
        checkVerdicts()
        checkDiskImagesAndInspection()
        checkVersionsAndCaches()
        do {
            try checkInspectionWalk()
            try checkMergedArtifacts()
            try checkApplyAndWorktreeRemoval()
            try checkDiskImageEject()
            try checkSessionArtifacts()
            try checkStores()
            try checkSkillSteps()
        } catch {
            fail("fixture setup: \(error.localizedDescription)")
        }
        if failures == 0 {
            print("All MaintenanceCore checks passed.")
            return 0
        }
        fputs("\(failures) MaintenanceCore check(s) failed.\n", stderr)
        return 1
    }

    // MARK: Units

    private mutating func checkPaths() {
        let home = URL(fileURLWithPath: "/Users/synthetic")
        check(MaintenancePath.expand("~/workspace", home: home) == "/Users/synthetic/workspace", "expands home-relative roots")
        check(MaintenancePath.isDescendant("/a/b/c", of: "/a/b") && !MaintenancePath.isDescendant("/a/bc", of: "/a/b")
              && !MaintenancePath.isDescendant("/a/b", of: "/a/b", orEqual: false), "compares path components, not string prefixes")
        check(MaintenancePath.relative("/a/b/c/d", to: "/a/b") == "c/d", "derives relative paths")
        check(MaintenancePath.protectedReason("/Users/synthetic/Library/Caches/x", home: home) != nil
              && MaintenancePath.protectedReason("/Users/synthetic/.Trash/x", home: home) != nil
              && MaintenancePath.protectedReason("/Users/synthetic", home: home) != nil
              && MaintenancePath.protectedReason("/private/tmp/x", home: home) != nil
              && MaintenancePath.protectedReason("/Users/synthetic/Downloads/a.dmg", home: home) != nil
              && MaintenancePath.protectedReason("/Users/synthetic/Downloads/a.dmg", home: home, allowsDownloadsDiskImages: true) == nil
              && MaintenancePath.protectedReason("/Users/synthetic/Downloads/a.zip", home: home, allowsDownloadsDiskImages: true) != nil
              && MaintenancePath.protectedReason("/Users/synthetic/workspace/x/node_modules", home: home) == nil,
              "never moves items outside home, in Library, the Trash, or Downloads except installed DMGs")
        check(GitHubRepository(remoteURL: "git@github.com:synthetic-owner/demo.git")?.description == "synthetic-owner/demo"
              && GitHubRepository(remoteURL: "https://github.com/synthetic-owner/demo")?.description == "synthetic-owner/demo"
              && GitHubRepository(remoteURL: "https://gitlab.com/synthetic-owner/demo.git") == nil
              && GitHubRepository(slug: "../etc") == nil && GitHubRepository(slug: "owner/repo;rm") == nil,
              "parses only well-formed github.com remotes")
    }

    private mutating func checkProcessUsage() {
        let snapshot = ProcessUsageSnapshot.parse("p10\ncshell\nfcwd\nn/work/repo/sub\nf3r\nn/work/other/file.txt\np11\ncdiskimages-helper\nf4r\nn/work/image.dmg\n")
        check(snapshot.processes(workingIn: "/work/repo") == [10] && snapshot.processes(workingIn: "/work/other").isEmpty,
              "finds processes working inside a folder")
        check(snapshot.isOpen("/work/other") && snapshot.isOpen("/work/other/file.txt") && !snapshot.isOpen("/work/oth"),
              "finds open files inside a folder by component")
        check(snapshot.isOpen("/work/image.dmg") && !snapshot.isOpen("/work/image.dmg", ignoring: ProcessUsageSnapshot.diskImageHelpers),
              "can ignore a disk image helper that holds a mounted image")
        let empty = ScriptedRunner { _ in ScriptedRunner.ok("") }
        check((try? ProcessUsageReader.read(runner: empty)) == nil, "an empty lsof listing fails closed")
        let failing = ScriptedRunner { _ in ScriptedRunner.failed("synthetic lsof failure", status: 2) }
        check((try? ProcessUsageReader.read(runner: failing)) == nil, "a failed lsof fails closed")
    }

    private mutating func checkSessionsAndRepositories() {
        let fields = AgentSessionRegistry.parseMetadata("id: abc\ncwd: \"/work/repo\"\nnested:\n  cwd: /elsewhere\nbranch: feature\n")
        check(fields["id"] == "abc" && fields["cwd"] == "/work/repo" && fields["branch"] == "feature", "reads top-level session metadata only")
        let now = Date()
        func session(_ pids: [Int32], _ age: TimeInterval?) -> AgentSession {
            AgentSession(directory: "/s", sessionID: "s", workingDirectory: "/w", gitRoot: nil, repository: nil, branch: nil,
                         livePIDs: pids, lastActivity: age.map { now.addingTimeInterval(-$0) })
        }
        check(session([42], 86_400).activityReason(now: now, quietPeriod: 900) != nil, "a live agent process protects its session even when idle-looking")
        check(session([], 60).activityReason(now: now, quietPeriod: 900) != nil && session([], 7_200).activityReason(now: now, quietPeriod: 900) == nil,
              "recent history writes protect a session")
        check(session([], nil).activityReason(now: now, quietPeriod: 900) != nil, "unknown activity is protected")
    }

    private mutating func checkVerdicts() {
        let merged = PullRequestRecord(number: 7, state: "closed", mergedAt: Date(timeIntervalSince1970: 100), headSHA: "aaa", headRef: "f", htmlURL: nil)
        let closed = PullRequestRecord(number: 8, state: "closed", mergedAt: nil, headSHA: "bbb", headRef: "f", htmlURL: nil)
        let open = PullRequestRecord(number: 9, state: "open", mergedAt: nil, headSHA: "ccc", headRef: "f", htmlURL: nil)
        check(PullRequestVerdict.evaluate([merged], headSHA: "aaa").mergedRecord?.number == 7, "a merged PR with the same head is eligible")
        check(PullRequestVerdict.evaluate([merged], headSHA: "zzz") == .headMismatch(7), "newer commits after a merged PR are not eligible")
        check(PullRequestVerdict.evaluate([closed], headSHA: "bbb") == .closedUnmerged(8), "closed but unmerged PRs are not eligible")
        check(PullRequestVerdict.evaluate([merged, open], headSHA: "aaa") == .open(9), "an open PR for the branch wins")
        check(PullRequestVerdict.evaluate([], headSHA: nil) == .notFound, "no PR is not eligible")
    }

    private mutating func checkDiskImagesAndInspection() {
        let info = Fixture.hdiutilInfo([(path: "/synthetic/a.dmg", owner: 501, writeable: false, device: "/dev/disk9", mount: "/Volumes/A")])
        let images = (try? DiskImageInspector.parse(Data(info.utf8))) ?? []
        check(images.count == 1 && images[0].wholeDisk == "/dev/disk9" && images[0].mountPoints == ["/Volumes/A"]
              && images[0].ownerUID == 501 && !images[0].isWriteable, "parses attached images, devices, and mount points")
        check(DiskImageInspector.detachCommand("/dev/disk9").arguments == ["detach", "/dev/disk9"], "ejects without -force")
        check(ArtifactInspector.isLocalConfiguration(".env") && ArtifactInspector.isLocalConfiguration(".env.local")
              && !ArtifactInspector.isLocalConfiguration(".env.example") && ArtifactInspector.isLocalConfiguration("server.pem")
              && !ArtifactInspector.isLocalConfiguration("report.pdf"), "recognizes local configuration and secrets")
        check(ArtifactInspector.isStagedApplication(relativePath: ".build/macos-package.x/image/Demo.app")
              && ArtifactInspector.isStagedApplication(relativePath: "dist/Demo.app")
              && !ArtifactInspector.isStagedApplication(relativePath: "Sources/Demo.app"), "recognizes staged apps in packaging folders")
        check(ArchiveSweeper.isArchive("a.TAR.GZ") && ArchiveSweeper.isArchive("x.zip") && !ArchiveSweeper.isArchive("a.pkg")
              && !ArchiveSweeper.isArchive("a.jar"), "matches the skill's archive extensions in any case")
        check(MaintenancePath.isGitMetadata(".GIT") && MaintenancePath.containsGitMetadata(["dist", ".Git", "HEAD"])
              && !MaintenancePath.isGitMetadata(".github"), "recognizes Git metadata names in any case")
        let listing = ScriptedRunner { command in
            command.executable == "/usr/bin/tar" ? ScriptedRunner.ok("./\n./Release/\n./Release/Synthetic.app/Contents/Info.plist\n") : nil
        }
        check(ArtifactInspector.archiveContainsApplication("/synthetic/Synthetic.tar.gz", runner: listing),
              "a leading ./ in an archive listing does not change the app's depth")
    }

    private mutating func checkInspectionWalk() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        try home.write("dist/nested/.GIT/HEAD", "ref: refs/heads/main")
        try home.write("dist/app.js")
        let nested = ArtifactInspector.inspect(home.path("dist"), checkLocalConfiguration: true)
        check(nested.nestedGitPaths.contains { $0.hasSuffix("nested/.GIT") }, "protects nested checkouts whose metadata folder is .GIT")
        try home.write("outside/.env", "SYNTHETIC=1")
        try home.write("linked/app.js")
        try FileManager.default.createSymbolicLink(atPath: home.path("linked/.env"), withDestinationPath: home.path("outside/.env"))
        let linked = ArtifactInspector.inspect(home.path("linked"), checkLocalConfiguration: true)
        check(linked.localConfigurationPaths.contains { $0.hasSuffix("linked/.env") }, "a link named like local configuration protects its folder")
    }

    private mutating func checkVersionsAndCaches() {
        check(AppVersionComparison.compare("2.10", "2.9") == .orderedDescending && AppVersionComparison.compare("1.0", "1.0.0") == .orderedSame
              && AppVersionComparison.compare("2.0-beta", "2.0") == nil, "compares versions numerically and refuses unorderable labels")
        let image = DiskImageApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: "2.0", build: "5")
        func installed(_ version: String, _ build: String?) -> [DiskImageApplication] {
            [DiskImageApplication(bundleIdentifier: "com.example.demo", name: "Demo", version: version, build: build)]
        }
        check(AppVersionComparison.isCovered(image: image, installed: installed("2.1", "1"))
              && AppVersionComparison.isCovered(image: image, installed: installed("2.0", "5"))
              && !AppVersionComparison.isCovered(image: image, installed: installed("2.0", "4"))
              && !AppVersionComparison.isCovered(image: image, installed: installed("1.9", "9"))
              && !AppVersionComparison.isCovered(image: image, installed: []), "an image is covered only by the same or a newer install")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playwright-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["chromium-1140", "chromium-1155", "firefox-400", "ffmpeg-1010", ".links"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        check(ToolCacheManager.playwrightOldRevisions(root: root.path, fileManager: .default).map { ($0 as NSString).lastPathComponent } == ["chromium-1140"],
              "keeps the newest revision of each Playwright browser")
        let definitions = ToolCache.definitions(home: URL(fileURLWithPath: "/Users/synthetic"))
        check(definitions.contains { $0.id == "npm" && $0.clearing == .command(tool: "npm", arguments: ["cache", "clean", "--force"], whileRunning: nil) }
              && definitions.contains { $0.id == "cargo-registry" && !$0.paths.contains { $0.hasSuffix(".cargo/bin") } },
              "cache definitions match the skill and never include ~/.cargo/bin")
    }

    // MARK: Merged artifacts

    private func environment(home: SyntheticHome, runner: ScriptedRunner, trashed: Box<[String]>? = nil, alive: Set<Int32> = []) -> MergedArtifactPlanner.Environment {
        MergedArtifactPlanner.Environment(
            runner: runner, home: home.home, now: { Date() }, isProcessAlive: { alive.contains($0) },
            trash: { url in
                trashed?.value.append(url.path)
                try FileManager.default.removeItem(at: url)
            },
            ghExecutable: "/synthetic/gh", ownExecutable: "", sessionQuietPeriod: 900, gitQuietPeriod: 0
        )
    }

    private func mergedRunner(sha: @escaping () -> String, lsof: @escaping () -> String = { Fixture.idleLsof },
                              hdiutil: @escaping () -> String = { Fixture.hdiutilInfo([]) },
                              pulls: (() -> String)? = nil) -> ScriptedRunner {
        ScriptedRunner { command in
            switch command.executable {
            case "/usr/sbin/lsof": return ScriptedRunner.ok(lsof())
            case "/usr/bin/hdiutil":
                return command.arguments.first == "info" ? ScriptedRunner.ok(hdiutil()) : ScriptedRunner.ok("")
            case "/synthetic/gh":
                let branch = command.arguments.first { $0.hasPrefix("head=") }.map { String($0.split(separator: ":").last ?? "") } ?? ""
                return ScriptedRunner.ok(pulls?() ?? Fixture.pullRequests([(7, "closed", "2026-01-01T00:00:00Z", sha(), branch)]))
            default: return nil
            }
        }
    }

    private func makeMergedWorktree(_ home: SyntheticHome) throws -> (main: String, worktree: String) {
        let main = try home.makeRepository()
        let worktree = try home.addWorktree("session-a", branch: "feature-a", main: main)
        let base = "workspace/copilot-worktrees/demo/session-a"
        try home.write("\(base)/node_modules/pkg/index.js")
        try home.write("\(base)/dist/app.js")
        try home.write("\(base)/dist/report.pdf")
        try home.write("\(base)/target/debug/demo")
        try home.write("\(base)/installer.dmg")
        try home.write("\(base)/notes.zip")
        try home.makeApp("\(base)/build/macos-package/Demo.app", identifier: "com.example.demo", version: "1.0")
        try home.write("\(base)/coverage/.env", "SYNTHETIC_TOKEN=placeholder")
        return (main, worktree)
    }

    private mutating func checkMergedArtifacts() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let (_, worktree) = try makeMergedWorktree(home)
        let head = try home.git(["rev-parse", "HEAD"], in: worktree)
        let roots = MaintenanceSettings.defaultArtifactRoots(home: home.home)
        let plan = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: mergedRunner(sha: { head }))).plan()
        let names = Set(plan.artifacts.map { ($0.path as NSString).lastPathComponent })
        check(plan.isComplete && plan.errors.isEmpty, "a merged worktree plan completes: \(plan.errors)")
        check(names == ["node_modules", "dist", "target", "installer.dmg", "Demo.app"],
              "collects eligible dependency, build, installer, and staged-app artifacts: \(names.sorted())")
        check(plan.protected.contains { $0.path.hasSuffix("coverage") && $0.reason.contains("local configuration") },
              "keeps output that holds local configuration")
        check(!names.contains("notes.zip") && !names.contains("build"), "never takes arbitrary archives or unrecognized ignored folders")
        check(plan.worktreeCandidates.map(\.path) == [MaintenancePath.resolved(worktree)] && plan.worktreeCandidates.first?.pullRequest == 7,
              "lists the merged worktree only as an approval candidate")
        check(plan.artifacts.allSatisfy { $0.repository == "synthetic-owner/demo" && $0.pullRequest == 7 }, "associates artifacts with their PR")
        check(!plan.artifacts.contains { $0.path.contains("/.git") }, "never touches Git metadata")

        let refusals: [(String, ScriptedRunner)] = [
            ("an open PR", mergedRunner(sha: { head }, pulls: { Fixture.pullRequests([(9, "open", nil, head, "feature-a")]) })),
            ("a closed-unmerged PR", mergedRunner(sha: { head }, pulls: { Fixture.pullRequests([(8, "closed", nil, head, "feature-a")]) })),
            ("newer commits than the merged head", mergedRunner(sha: { "0000000000000000000000000000000000000000" })),
            ("a process working in it", mergedRunner(sha: { head }, lsof: { Fixture.lsof(cwd: [worktree + "/dist"]) })),
            ("an open file in it", mergedRunner(sha: { head }, lsof: { Fixture.lsof(open: [(worktree + "/node_modules/pkg/index.js", "node")]) }))
        ]
        for (name, runner) in refusals {
            let refused = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner)).plan()
            check(refused.artifacts.isEmpty && refused.worktreeCandidates.isEmpty, "\(name) makes the worktree ineligible")
        }
        let githubDown = ScriptedRunner { command in
            switch command.executable {
            case "/usr/sbin/lsof": return ScriptedRunner.ok(Fixture.idleLsof)
            case "/usr/bin/hdiutil": return ScriptedRunner.ok(Fixture.hdiutilInfo([]))
            case "/synthetic/gh": return ScriptedRunner.failed("HTTP 401: Bad credentials")
            default: return nil
            }
        }
        let failed = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: githubDown)).plan()
        check(failed.artifacts.isEmpty && !failed.isComplete && failed.errors.contains { $0.contains("401") },
              "a GitHub failure fails closed and is reported")
        let noLsof = ScriptedRunner { $0.executable == "/usr/sbin/lsof" ? ScriptedRunner.failed("synthetic", status: 2) : nil }
        let blind = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: noLsof)).plan()
        check(blind.artifacts.isEmpty && !blind.isComplete, "an lsof failure plans nothing")

        try home.write("workspace/copilot-worktrees/demo/session-a/scratch.txt")
        let dirty = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: mergedRunner(sha: { head }))).plan()
        check(dirty.artifacts.isEmpty && dirty.protected.contains { $0.reason.contains("uncommitted or untracked") },
              "a worktree with untracked files is protected")
        try FileManager.default.removeItem(atPath: worktree + "/scratch.txt")

        let session = home.path(".copilot/session-state/live-session")
        try home.write(".copilot/session-state/live-session/workspace.yaml", "id: live-session\ncwd: \(worktree)\nrepository: synthetic-owner/demo\nbranch: feature-a\n")
        try home.write(".copilot/session-state/live-session/inuse.4242.lock", "4242")
        let live = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: mergedRunner(sha: { head }), alive: [4242])).plan()
        check(live.artifacts.isEmpty && live.protected.contains { $0.reason.contains("4242") }, "a live agent session protects its worktree")
        try FileManager.default.removeItem(atPath: session)

        let unsafe = MergedArtifactPlanner(roots: [home.path("Downloads"), home.home.path], environment: environment(home: home, runner: mergedRunner(sha: { head }))).plan()
        check(unsafe.roots.isEmpty && unsafe.skipped.count == 2, "refuses Downloads and the home folder as roots")
    }

    private mutating func checkApplyAndWorktreeRemoval() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let (_, worktree) = try makeMergedWorktree(home)
        let head = try home.git(["rev-parse", "HEAD"], in: worktree)
        let roots = MaintenanceSettings.defaultArtifactRoots(home: home.home)
        let openPath = Box<String?>(nil)
        let runner = mergedRunner(sha: { head }, lsof: { Fixture.lsof(open: openPath.value.map { [($0, "node")] } ?? []) })
        let planner = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner))
        let plan = planner.plan()
        openPath.value = MaintenancePath.resolved(worktree) + "/node_modules/pkg/index.js"
        let busy = planner.apply(plan)
        check(busy.trashed.isEmpty && busy.kept.count == plan.artifacts.count, "a file opened in the worktree after the preview keeps every artifact")
        openPath.value = nil
        let stopped = planner.apply(plan, shouldContinue: { false })
        check(stopped.trashed.isEmpty && stopped.kept.count == plan.artifacts.count && stopped.kept.allSatisfy { $0.reason.contains("stopped") },
              "a withdrawn schedule stops the run before any move")
        try home.write("workspace/copilot-worktrees/demo/session-a/dist/new.js", "changed after preview")
        let result = planner.apply(plan)
        let removed = Set(result.trashed.map { ($0.path as NSString).lastPathComponent })
        check(removed == ["target", "installer.dmg", "Demo.app", "node_modules"], "trashes only unchanged manifest entries: \(removed.sorted()) kept \(result.kept)")
        check(result.kept.contains { $0.path.hasSuffix("/dist") }, "keeps an entry that changed after the preview")
        check(result.errors.isEmpty && (try? home.git(["status", "--porcelain"], in: worktree)) == "" && (try? home.git(["rev-parse", "HEAD"], in: worktree)) == head,
              "leaves the worktree clean at its HEAD: \(result.errors)")
        check(FileManager.default.fileExists(atPath: worktree + "/README.md") && FileManager.default.fileExists(atPath: worktree + "/.git"),
              "never removes tracked files or Git metadata")
        let audit = MergedArtifactAuditRecord(mode: "apply", plan: plan, result: result)
        let encoded = (try? JSONEncoder().encode(audit)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(encoded.contains("\"pullRequest\":7") && !encoded.contains("SYNTHETIC_TOKEN"), "audit records list PRs and paths but no file contents")

        for name in ["dist", "coverage"] { try FileManager.default.removeItem(atPath: worktree + "/" + name) }
        try home.write("workspace/copilot-worktrees/demo/session-a/untracked.txt")
        guard let candidate = plan.worktreeCandidates.first else {
            fail("a worktree candidate exists")
            return
        }
        if case .success = planner.removeWorktree(candidate) { fail("refuses to remove a worktree with untracked files") }
        check(FileManager.default.fileExists(atPath: worktree), "an untracked file keeps the worktree")
        try FileManager.default.removeItem(atPath: worktree + "/untracked.txt")
        if case .failure(let error) = planner.removeWorktree(candidate) { fail("removes an approved clean merged worktree: \(error.localizedDescription)") }
        check(!FileManager.default.fileExists(atPath: worktree) && runner.commands.contains { $0.arguments.suffix(3) == ["worktree", "remove", candidate.path] }
              && !runner.commands.contains { $0.arguments.contains("--force") }, "removes it with git worktree remove, never forced")
    }

    private mutating func checkDiskImageEject() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let (_, worktree) = try makeMergedWorktree(home)
        let head = try home.git(["rev-parse", "HEAD"], in: worktree)
        let image = MaintenancePath.resolved(worktree + "/installer.dmg")
        let attached = Box(true)
        let writeable = Box(false)
        let owner = Box(getuid())
        let runner = mergedRunner(sha: { head },
                                  lsof: { Fixture.lsof(open: attached.value ? [(image, "diskimages-helper")] : []) },
                                  hdiutil: { attached.value ? Fixture.hdiutilInfo([(image, owner.value, writeable.value, "/dev/disk77", "/Volumes/Synthetic")]) : Fixture.hdiutilInfo([]) })
        let base = runner.handler
        runner.handler = { command in
            if command.executable == "/usr/bin/hdiutil", command.arguments.first == "detach" { attached.value = false; return ScriptedRunner.ok() }
            return base(command)
        }
        let roots = MaintenanceSettings.defaultArtifactRoots(home: home.home)
        let planner = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner))
        let plan = planner.plan()
        check(plan.artifacts.first { MaintenancePath.resolved($0.path) == image }?.ejectDevice == "/dev/disk77",
              "plans a normal eject for a user-owned read-only mounted installer")
        let result = planner.apply(plan)
        check(result.ejected.count == 1 && result.trashed.contains { $0.kind == .installer }
              && runner.commands.filter { $0.arguments.first == "detach" }.allSatisfy { $0.arguments == ["detach", "/dev/disk77"] },
              "ejects normally before trashing the image: \(result.kept)")

        try home.write("workspace/copilot-worktrees/demo/session-a/installer.dmg")
        attached.value = true
        writeable.value = true
        check(MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner)).plan().artifacts.allSatisfy { $0.kind != .installer },
              "keeps a writable mounted image")
        writeable.value = false
        owner.value = getuid() + 1
        check(MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner)).plan().artifacts.allSatisfy { $0.kind != .installer },
              "keeps an image attached by another user")
    }

    private mutating func checkSessionArtifacts() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let old = Date(timeIntervalSince1970: 1_767_000_000)
        let directory = ".copilot/session-state/archived-session"
        try home.write("\(directory)/workspace.yaml", "id: archived-session\ncwd: \(home.path("workspace/copilot-worktrees/demo/gone"))\nrepository: synthetic-owner/demo\nbranch: feature-old\n", modified: old)
        try home.write("\(directory)/events.jsonl", "{}", modified: old)
        try home.write("\(directory)/session.db", "", modified: old)
        try home.write("\(directory)/files/Demo.dmg", "synthetic", modified: old)
        try home.write("\(directory)/files/screenshot.png", "synthetic", modified: old)
        try home.write("\(directory)/files/notes.pdf", "synthetic", modified: old)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path("\(directory)/files"))
        let roots = MaintenanceSettings.defaultArtifactRoots(home: home.home)
        let mergedAt = "2026-01-01T00:00:00Z"
        let runner = mergedRunner(sha: { "unused" }, pulls: { Fixture.pullRequests([(7, "closed", mergedAt, "abc", "feature-old")]) })
        let planner = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner))
        let plan = planner.plan()
        check(plan.artifacts.map { ($0.path as NSString).lastPathComponent } == ["Demo.dmg"],
              "takes only installers from an inactive merged session, never screenshots or documents: \(plan.artifacts.map(\.path)) \(plan.skipped)")
        check(plan.sessionCandidates.count == 1, "lists the whole session only for approval")
        let result = planner.apply(plan)
        check(result.trashed.count == 1 && FileManager.default.fileExists(atPath: home.path("\(directory)/events.jsonl"))
              && FileManager.default.fileExists(atPath: home.path("\(directory)/files/screenshot.png")),
              "keeps session history and screenshots: \(result.kept) \(result.errors)")

        try home.write("\(directory)/files/Later.dmg", "synthetic")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: home.path("\(directory)/files"))
        let later = MergedArtifactPlanner(roots: roots, environment: environment(home: home, runner: runner)).plan()
        check(later.artifacts.isEmpty && later.skipped.contains { $0.reason.contains("after PR #7 merged") },
              "an installer newer than the merge lacks provenance")
    }

    private mutating func checkStores() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let log = MaintenanceAuditLog(url: home.home.appendingPathComponent("logs/audit.jsonl"), maximumBytes: 200, rotatedCopies: 2)
        struct Entry: Encodable { let value: String }
        for index in 0..<20 { try log.append(Entry(value: String(repeating: "x", count: 40) + "\(index)")) }
        let fm = FileManager.default
        check(fm.fileExists(atPath: log.url.path) && fm.fileExists(atPath: log.rotatedURL(1).path) && fm.fileExists(atPath: log.rotatedURL(2).path)
              && !fm.fileExists(atPath: log.rotatedURL(3).path), "rotates the audit log and keeps at most two older copies")
        let sizes = [log.url, log.rotatedURL(1), log.rotatedURL(2)].compactMap { (try? fm.attributesOfItem(atPath: $0.path)[.size]) as? Int }
        check(sizes.allSatisfy { $0 <= 200 }, "each audit log file stays within the size limit")
        let lines = (try? String(contentsOf: log.url, encoding: .utf8))?.split(separator: "\n") ?? []
        check(lines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "writes one JSON object per line")

        let suite = "MaintenanceCoreChecks-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fail("creates isolated defaults"); return }
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = MaintenanceHistoryStore(defaults: defaults)
        let now = Date()
        history.append(MaintenanceRunSummary(date: now.addingTimeInterval(-90_000), task: "old", mode: "apply", trashedCount: 1, trashedBytes: 1, protectedCount: 0, errorCount: 0), now: now)
        history.append(MaintenanceRunSummary(date: now.addingTimeInterval(-60), task: "recent", mode: "apply", trashedCount: 2, trashedBytes: 2, protectedCount: 0, errorCount: 0), now: now)
        check(history.load(now: now).map(\.task) == ["recent"], "keeps only the last 24 hours of run summaries")
        let settingsStore = MaintenanceSettingsStore(defaults: defaults, home: home.home)
        var settings = settingsStore.load().settings
        check(settings.artifactRoots == MaintenanceSettings.defaultArtifactRoots(home: home.home) && !settings.scheduleEnabled
              && !settings.trashScheduleEnabled && settings.nextTrashEmpty == nil,
              "defaults to the session-state and worktree roots with both schedules off")
        settings.artifactRoots.append(home.path("src"))
        try settingsStore.save(settings)
        check(settingsStore.load().settings.artifactRoots.count == 3, "persists added roots")
        let legacy = #"{"artifactRoots":["/a"],"repositoryRoots":[],"scheduleEnabled":true,"scheduleIntervalHours":6,"archiveIdleHours":24,"buildIdleDays":14}"#
        defaults.set(Data(legacy.utf8), forKey: "maintenance.settings")
        let upgraded = settingsStore.load()
        check(upgraded.warning == nil && upgraded.settings.scheduleIntervalHours == 6 && !upgraded.settings.trashScheduleEnabled
              && upgraded.settings.trashScheduleIntervalDays == 7, "settings saved before automatic emptying keep their values with it off")

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var trash = MaintenanceSettings(artifactRoots: [], repositoryRoots: [], trashScheduleEnabled: true,
                                        trashScheduleIntervalDays: 7, trashScheduleAnchor: start)
        check(!trash.isTrashEmptyDue(now: start.addingTimeInterval(6 * 86_400)) && trash.isTrashEmptyDue(now: start.addingTimeInterval(7 * 86_400)),
              "automatic emptying is due one interval after it started")
        trash.trashScheduleEnabled = false
        check(!trash.isTrashEmptyDue(now: start.addingTimeInterval(30 * 86_400)), "automatic emptying never runs while off")
        let clockStore = MaintenanceSettingsStore(defaults: defaults, home: home.home, now: { start })
        try clockStore.save(MaintenanceSettings(artifactRoots: [], repositoryRoots: [], trashScheduleEnabled: true,
                                                trashScheduleIntervalDays: 5, trashScheduleAnchor: nil))
        let restored = clockStore.load().settings
        check(restored.trashScheduleAnchor == start && restored.trashScheduleIntervalDays == 7 && !restored.isTrashEmptyDue(now: start),
              "a missing start begins a new interval instead of emptying at once, and unknown intervals reset to weekly")
        let relaunched = MaintenanceSettingsStore(defaults: defaults, home: home.home, now: { start.addingTimeInterval(3 * 86_400) }).load().settings
        check(relaunched.trashScheduleAnchor == start, "the repaired start is saved, so relaunching does not postpone automatic emptying")
        try clockStore.save(MaintenanceSettings(artifactRoots: [], repositoryRoots: [], trashScheduleEnabled: true,
                                                trashScheduleIntervalDays: 1, trashScheduleAnchor: start.addingTimeInterval(86_400 * 40)))
        check(clockStore.load().settings.trashScheduleAnchor == start, "a start in the future after a clock change restarts the interval now")

        defaults.set(Data("bad".utf8), forKey: "maintenance.settings")
        check(settingsStore.load().warning != nil, "reports unreadable saved settings")
    }

    // MARK: Skill steps

    private mutating func checkSkillSteps() throws {
        let home = try SyntheticHome()
        defer { home.remove() }
        let main = try home.makeRepository()
        let worktree = try home.addWorktree("session-b", branch: "feature-b", main: main)
        try home.write("workspace/copilot-worktrees/demo/session-b/release.tar.gz")
        try home.write("workspace/copilot-worktrees/loose.zip")
        try home.write("src/demo/fixtures.zip")
        try home.git(["add", "-f", "fixtures.zip"], in: main)
        try home.git(["commit", "-q", "-m", "Synthetic fixture"], in: main)
        try home.write("src/demo/node_modules/pkg/index.js")
        let future = Date().addingTimeInterval(40 * 86_400)
        let trashCount = Box(3)
        let runner = ScriptedRunner { command in
            switch command.executable {
            case "/usr/sbin/lsof": return ScriptedRunner.ok(Fixture.idleLsof)
            case "/usr/bin/hdiutil": return ScriptedRunner.ok(Fixture.hdiutilInfo([]))
            case "/bin/ps": return ScriptedRunner.ok("/usr/bin/synthetic\n/opt/homebrew/bin/go\n")
            case "/usr/bin/osascript":
                if command.arguments.last?.contains("empty trash") == true { trashCount.value = 0; return ScriptedRunner.ok() }
                return ScriptedRunner.ok("\(trashCount.value)\n")
            default: return nil
            }
        }
        var environment = MaintenanceStepEnvironment(runner: runner, home: home.home, now: { future }, isProcessAlive: { _ in false },
                                                     trash: { url in try FileManager.default.removeItem(at: url) })
        let roots = MaintenanceSettings.defaultArtifactRoots(home: home.home)
        let archives = ArchiveSweeper.scan(roots: roots, minimumIdleHours: 24, environment: environment)
        check(Set(archives.candidates.map { ($0.path as NSString).lastPathComponent }) == ["release.tar.gz", "loose.zip"],
              "finds idle untracked archives in worktrees and loose in the root: \(archives.candidates.map(\.path)) \(archives.kept)")
        let recent = ArchiveSweeper.scan(roots: roots, minimumIdleHours: 24,
                                         environment: MaintenanceStepEnvironment(runner: runner, home: home.home, isProcessAlive: { _ in false }))
        check(recent.candidates.isEmpty, "recently touched archives are kept")
        let moved = environment.trash(archives.candidates) { ArchiveSweeper.recheck($0, environment: environment) }
        check(moved.trashed.count == 2 && FileManager.default.fileExists(atPath: worktree + "/.git"), "trashes the archives and nothing else: \(moved.kept)")

        let builds = IdleBuildOutputFinder.scan(repositoryRoots: [home.path("src")], idleDays: 14, environment: environment)
        check(builds.candidates.map { ($0.path as NSString).lastPathComponent } == ["node_modules"], "finds ignored build output in idle clean checkouts: \(builds.kept)")
        try home.write("src/demo/scratch.txt")
        let dirtyBuilds = IdleBuildOutputFinder.scan(repositoryRoots: [home.path("src")], idleDays: 14, environment: environment)
        check(dirtyBuilds.candidates.isEmpty && dirtyBuilds.kept.contains { $0.reason.contains("uncommitted") }, "skips dirty checkouts")
        let stale = environment.trash(builds.candidates)
        check(stale.trashed.isEmpty && stale.kept.first?.reason.contains("changes") == true, "rechecks the checkout before trashing build output: \(stale)")
        try FileManager.default.createSymbolicLink(atPath: home.path("linked-library"), withDestinationPath: home.path("Library"))
        let linkedRoot = IdleBuildOutputFinder.scan(repositoryRoots: [home.path("linked-library")], idleDays: 14, environment: environment)
        check(linkedRoot.candidates.isEmpty && linkedRoot.kept.contains { $0.reason.contains("Library") },
              "revalidates roots at scan time, so a root linked into ~/Library is refused")

        environment.now = { Date() }
        try home.write("Library/Caches/go-build/a", String(repeating: "x", count: 5_000))
        try home.write(".npm/_cacache/b", String(repeating: "x", count: 5_000))
        let caches = ToolCacheManager.status(environment: environment)
        check(caches.first { $0.cache.id == "go-build" }?.blocker?.contains("go") == true, "keeps a cache while its tool runs or is missing")
        check(caches.first { $0.cache.id == "npm" }.map { $0.sizeBytes > 0 } == true, "measures cache sizes")

        check((try? TrashBin.itemCount(runner: runner)) == 3 && (try? TrashBin.empty(runner: runner, pause: { _ in })) == 0,
              "empties the Trash through Finder and confirms the count")
        check(TrashBin.automationMessage("execution error: Not authorized to send Apple events to Finder. (-1743)").contains("Automation"),
              "explains a denied Finder automation permission")

        try home.write("Downloads/Demo.dmg")
        try home.write("Downloads/keep.zip")
        try home.write("Desktop/Old.dmg")
        try home.makeApp("Applications/Demo.app", identifier: "com.example.demo", version: "2.0", build: "3")
        try home.makeApp("mounts/demo/Demo.app", identifier: "com.example.demo", version: "1.5", build: "1")
        try home.makeApp("mounts/old/Old.app", identifier: "com.example.old", version: "1.0", build: "1")
        let dmgRunner = ScriptedRunner { command in
            switch command.executable {
            case "/usr/sbin/lsof": return ScriptedRunner.ok(Fixture.idleLsof)
            case "/usr/bin/hdiutil":
                switch command.arguments.first {
                case "info": return ScriptedRunner.ok(Fixture.hdiutilInfo([]))
                case "isencrypted": return ScriptedRunner.ok(Self.plist(["encrypted": false]))
                case "imageinfo": return ScriptedRunner.ok(Self.plist(["Properties": ["Software License Agreement": false]]))
                case "attach":
                    let mount = command.arguments.last?.hasSuffix("Demo.dmg") == true ? home.path("mounts/demo") : home.path("mounts/old")
                    return ScriptedRunner.ok(Self.plist(["system-entities": [["dev-entry": "/dev/disk60"], ["dev-entry": "/dev/disk60s1", "mount-point": mount]]]))
                default: return ScriptedRunner.ok()
                }
            default: return nil
            }
        }
        let dmgs = InstalledDiskImageFinder.scan(environment: MaintenanceStepEnvironment(runner: dmgRunner, home: home.home),
                                                 applicationRoots: [home.home.appendingPathComponent("Applications")])
        check(dmgs.candidates.map { ($0.path as NSString).lastPathComponent } == ["Demo.dmg"],
              "trashes only DMGs whose apps are installed at the same or a newer version: \(dmgs.kept)")
        check(dmgs.kept.contains { $0.path.hasSuffix("Old.dmg") }, "keeps DMGs for apps that are not installed")
        check(dmgRunner.commands.filter { $0.arguments.first == "attach" }.allSatisfy { $0.arguments.contains("-readonly") && $0.arguments.contains("-nobrowse") }
              && dmgRunner.commands.filter { $0.arguments.first == "detach" }.count == 2
              && !dmgRunner.commands.contains { $0.arguments.contains { $0.hasSuffix("keep.zip") } },
              "attaches images read-only and hidden, always detaches them, and never touches other Downloads files")
        let keep = home.path("Downloads/keep.zip")
        if let identity = FileIdentity.read(keep) {
            let downloads = environment.trash([TrashCandidate(path: keep, detail: "", sizeBytes: 0, identity: identity)])
            check(downloads.trashed.isEmpty && FileManager.default.fileExists(atPath: keep), "refuses to trash anything but a DMG in Downloads")
        }
    }

    static func plist(_ value: Any) -> String {
        String(decoding: (try? PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)) ?? Data(), as: UTF8.self)
    }

    private mutating func check(_ condition: Bool, _ name: String) {
        if !condition { fail(name) }
    }

    private mutating func fail(_ message: String) {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

var runner = CheckRunner()
exit(runner.run())
