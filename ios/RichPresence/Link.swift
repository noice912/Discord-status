import Foundation
import Security

/// One Discord application linked to the person's account = one card on their status.
/// RichPresence uses two: games on "RichPresence Mobile", music on "RichPresence Music".
@MainActor
final class Link: ObservableObject {
    let label: String
    let bridge: DiscordBridge
    @Published var name: String?
    @Published var connected = false
    @Published var linking = false
    var lastSent: String?
    var sentAt = Date.distantPast
    var onReady: (() -> Void)?

    private let prefix: String
    private let say: (String) -> Void
    // signing in again after the connection was lost: one wait at a time, each longer than the last
    private var retry: Timer?
    private var retryDelay: TimeInterval = 10
    private var readyAt = Date.distantPast
    private var refreshTried = Date.distantPast
    // a refresh token works once, so a second sign-in waits while one is under way (given up on after a minute)
    private var signInSent = Date.distantPast
    private var keychainFailed: Set<String> = []

    /// `prefix` keeps each link's saved sign-in apart ("" is the original game link, so it keeps working).
    init(label: String, appId: UInt64, prefix: String, say: @escaping (String) -> Void) {
        self.label = label
        self.prefix = prefix
        self.say = say
        bridge = DiscordBridge(appId: appId)
        name = UserDefaults.standard.string(forKey: prefix + "user")
        bridge.onLog = { [weak self] m in self?.say("\(label): \(m)") }
        bridge.onTokens = { [weak self] access, refresh, expiresIn in
            guard let self else { return }
            self.signInSent = .distantPast
            self.save(access, "access")
            self.save(refresh, "refresh")
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(expiresIn)), forKey: prefix + "expires_at")
            if self.linking { self.say("\(label): Discord account linked.") }
            self.linking = false
        }
        bridge.onReady = { [weak self] display in
            guard let self else { return }
            self.connected = true
            self.readyAt = Date()
            self.name = display
            UserDefaults.standard.set(display, forKey: prefix + "user")
            self.say("\(label): signed in as \(display)")
            self.lastSent = nil
            self.onReady?()
        }
        bridge.onDisconnected = { [weak self] reason in
            guard let self else { return }
            // start again from a short wait only after a connection that lasted
            if self.connected && Date().timeIntervalSince(self.readyAt) > 60 { self.retryDelay = 10 }
            self.connected = false
            if !reason.isEmpty { self.say("\(label): disconnected (\(reason))") }
            self.retryLater()
        }
        bridge.onAuthFailed = { [weak self] _ in
            guard let self else { return }
            // the reason is already in the log; a failed or cancelled link frees the button again
            self.linking = false
            self.signInSent = .distantPast
            if !self.connected { self.retryLater() }
        }
    }

    var hasSignIn: Bool { Keychain.get(prefix + "refresh") != nil }

    func signInSaved() {
        guard let refresh = Keychain.get(prefix + "refresh") else { return }
        guard Date().timeIntervalSince(signInSent) > 60 else { return }
        let expires = UserDefaults.standard.object(forKey: prefix + "expires_at") as? Date ?? .distantPast
        if let access = Keychain.get(prefix + "access"), expires.timeIntervalSinceNow > 86_400 {
            bridge.useAccessToken(access)
        } else {
            signInSent = Date()
            bridge.refresh(withToken: refresh)
        }
    }

    /// Signs in again with the saved sign-in after a wait: 10 seconds at first, doubling up to 30 minutes
    /// while it keeps failing. Only one wait runs at a time, and nothing happens when nothing is saved.
    private func retryLater() {
        guard retry == nil, hasSignIn else { return }
        let wait = retryDelay
        retryDelay = min(retryDelay * 2, 1800)
        retry = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.retry = nil
                if !self.connected && !self.linking { self.signInSaved() }
            }
        }
    }

    private func cancelRetry() {
        retry?.invalidate()
        retry = nil
        retryDelay = 10
    }

    /// Called every few seconds while the app runs: gets a new token shortly before the current one
    /// runs out (at most one try every 10 minutes).
    func refreshIfExpiring() {
        guard connected, Date().timeIntervalSince(refreshTried) > 600,
              Date().timeIntervalSince(signInSent) > 60,
              let expires = UserDefaults.standard.object(forKey: prefix + "expires_at") as? Date,
              expires.timeIntervalSinceNow < 300,
              let refresh = Keychain.get(prefix + "refresh") else { return }
        refreshTried = Date()
        signInSent = Date()
        bridge.refresh(withToken: refresh)
    }

    private func save(_ value: String?, _ key: String) {
        let status = Keychain.set(value, for: prefix + key)
        if status != errSecSuccess && keychainFailed.insert(key).inserted {
            say("\(label): couldn't save the sign-in on this iPhone (error \(status)). You may have to link again later.")
        }
    }

    func link() {
        cancelRetry()
        linking = true
        say("\(label): opening Discord to link your account...")
        bridge.authorize()
    }

    func unlink() {
        cancelRetry()
        save(nil, "access")
        save(nil, "refresh")
        UserDefaults.standard.removeObject(forKey: prefix + "user")
        bridge.disconnect()
        name = nil
        connected = false
        lastSent = nil
        say("\(label): unlinked.")
    }

    /// Sends when the card changed (or every 30 s to keep it fresh). Returns whether it sent.
    @discardableResult
    func send(_ sig: String, force: Bool, _ update: (DiscordBridge) -> Void) -> Bool {
        guard connected else { return false }
        if !force && sig == lastSent && Date().timeIntervalSince(sentAt) < 30 { return false }
        lastSent = sig
        sentAt = Date()
        update(bridge)
        return true
    }

    func clear() {
        guard connected, lastSent != nil else { return }
        bridge.clear()
        lastSent = nil
    }
}
