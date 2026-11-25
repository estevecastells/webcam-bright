// Checks GitHub for new releases and installs them in place: download, verify
// signature and checksum (WebcamBrightKit/Updater.swift), swap the app bundle, relaunch.
//
// Installing quits the app, and quitting hands the camera back to its own auto
// exposure, so it never happens during a call: an automatic update waits until
// the call ends, and the Update button stays disabled until then.

import AppKit
import Foundation
import Observation
import WebcamBrightKit

@MainActor
@Observable
public final class Updates {
    public enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: URL)
        case installing(String)
        case failed(String)
    }

    public private(set) var state: State = .idle
    private var pending: Release?
    private var loop: Task<Void, Never>?
    private var waiter: Task<Void, Never>?
    /// True during a call, which an app restart would interrupt.
    var isBusy: @MainActor () -> Bool = { false }

    private static let autoInstallKey = "autoInstallUpdates"

    var autoInstall: Bool {
        get { UserDefaults.standard.object(forKey: Self.autoInstallKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoInstallKey)
            if newValue, pending != nil { installWhenIdle() }
        }
    }

    static let checkEvery: Duration = .seconds(6 * 3600)

    public static var currentVersion: Version {
        Version(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? Version("0")!
    }

    public init() {}

    /// Check shortly after launch, then periodically.
    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Updates.checkEvery)
            }
        }
    }

    func check(userInitiated: Bool) async {
        if case .installing = state { return }
        if userInitiated { state = .checking }
        do {
            if let release = try await UpdateCheck.newer(than: Self.currentVersion) {
                pending = release
                state = .available(version: release.version?.description ?? release.tagName, notes: release.htmlUrl)
                if autoInstall && !userInitiated { installWhenIdle() }
            } else {
                pending = nil
                // Only confirm "up to date" when asked, and only briefly.
                state = userInitiated ? .upToDate : .idle
                if userInitiated {
                    try? await Task.sleep(for: .seconds(4))
                    if state == .upToDate { state = .idle }
                }
            }
        } catch {
            // Background checks fail quietly (offline, rate limit); only show errors the user asked for.
            if userInitiated {
                state = .failed("Couldn't check for updates: \(error.localizedDescription)")
            }
        }
    }

    /// Install as soon as nothing would be interrupted.
    private func installWhenIdle() {
        guard waiter == nil else { return }
        waiter = Task { [weak self] in
            while let self, !Task.isCancelled, self.pending != nil, self.autoInstall {
                if !self.isBusy() {
                    await self.install()
                    break
                }
                try? await Task.sleep(for: .seconds(30))
            }
            self?.waiter = nil
        }
    }

    func install() async {
        guard let release = pending, !isBusy() else { return }
        if case .installing = state { return }
        do {
            let staged = try await Self.download(release) { step in self.state = .installing(step) }
            defer { try? FileManager.default.removeItem(at: staged.work) }
            // Something may have started while downloading; try again once it's done.
            if isBusy() {
                state = .available(version: release.version?.description ?? release.tagName, notes: release.htmlUrl)
                if autoInstall { installWhenIdle() }
                return
            }
            _ = try FileManager.default.replaceItemAt(Bundle.main.bundleURL, withItemAt: staged.app)
            Self.relaunch()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Download and verify the release next to the running app; nothing is replaced yet.
    private static func download(
        _ release: Release, progress: @escaping @MainActor (String) -> Void
    ) async throws -> (work: URL, app: URL) {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            throw UpdateError.invalidBundle("not running from an app bundle")
        }
        let fm = FileManager.default
        // On the same volume as the app, so the final swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
        do {
            progress("Downloading…")
            func fetch(_ name: String) async throws -> URL {
                guard let url = release.asset(name) else { throw UpdateError.missingAsset(name) }
                let (tmp, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw UpdateError.missingAsset("\(name) (HTTP \(http.statusCode))")
                }
                let dest = work.appendingPathComponent(name)
                try fm.moveItem(at: tmp, to: dest)
                return dest
            }
            let sums = try await fetch("SHA256SUMS")
            let sig = try await fetch("SHA256SUMS.sig")
            let zip = try await fetch(UpdateConfig.appAsset)

            progress("Verifying…")
            let verifier = try ReleaseVerifier(publicKeysBase64: UpdateConfig.publicKeys)
            let entries = try verifier.verifiedSums(sums: Data(contentsOf: sums), signature: Data(contentsOf: sig))
            try ReleaseVerifier.check(zip, named: UpdateConfig.appAsset, in: entries)

            progress("Installing…")
            let unpacked = work.appendingPathComponent("unpacked")
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError.invalidBundle("no app in the download") }
            guard let info = Bundle(url: newApp)?.infoDictionary,
                info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
            else { throw UpdateError.invalidBundle("unexpected bundle identifier") }
            guard let v = (info["CFBundleShortVersionString"] as? String).flatMap(Version.init), v == release.version
            else { throw UpdateError.invalidBundle("version doesn't match the release") }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            return (work, newApp)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let name = (tool as NSString).lastPathComponent
            throw UpdateError.invalidBundle("\(name) failed")
        }
    }

    /// Start the new copy once this process has exited, then quit.
    private static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApplication.shared.terminate(nil)
    }
}
