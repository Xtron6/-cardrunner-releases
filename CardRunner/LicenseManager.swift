import Foundation
import Security
import Combine

// MARK: - LicenseManager

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    // MARK: - Status

    enum Status: Equatable {
        case checking                   // launch, not yet determined
        case licensed                   // active and recently validated
        case grace(daysLeft: Int)       // offline but within grace window
        case unlicensed                 // never had a key
        case revoked                    // had a key but server rejected it (migration / refund)
    }

    @Published private(set) var status: Status = .checking
    @Published private(set) var isDeactivating: Bool = false
    @Published private(set) var justActivated: Bool = false   // fires once after a successful activation
    /// Email address the license is registered to, as returned by Lemon Squeezy meta.customer_email.
    @Published private(set) var customerEmail: String? = nil

    var isLicensed: Bool {
        switch status {
        case .licensed, .grace: return true
        default: return false
        }
    }

    /// True when the gate should show the "key revoked / needs replacing" variant.
    var isRevoked: Bool { status == .revoked }

    // MARK: - Constants

    private let service          = "com.xaviergallo.cardrunner"
    private let keyAccount       = "license_key"
    private let instanceAccount  = "license_instance_id"
    private let lastValidatedUD  = "pref_licenseLastValidated"
    private let customerEmailUD  = "pref_licenseCustomerEmail"
    private let graceDays        = 14   // allow offline use for 14 days (shoots, travel, no wifi)
    private let revalidateAfter  = 7    // recheck LS at most once every 7 days; skip network otherwise
    private let apiBase          = "https://api.lemonsqueezy.com/v1/licenses"

    // ── Product-ID guard ──────────────────────────────────────────────────────
    // List every Lemon Squeezy product ID whose keys should unlock CardRunner.
    // Find the ID in your LS dashboard URL: lemonsqueezy.com/dashboard/products/XXXXX
    //
    // Empty set  → guard disabled (any LS key works) — use while setting up
    // One ID     → only that product's keys accepted
    // Two IDs    → both accepted (beta/test product + real product)
    //
    // Current setup:
    //   992730 = real product, 992752 = beta/test product
    private let allowedProductIDs: Set<Int> = [992730, 992752]

    private init() {
        // ── Optimistic precheck (synchronous, runs before any view renders) ──
        // If a key + instance ID are already in the keychain, immediately treat
        // the user as licensed. checkOnLaunch() still does a silent background
        // network validation but will only downgrade to .revoked on an
        // authoritative response (200+valid:false or 404 not-found). This
        // eliminates the half-second license-gate flash on every launch.
        if keychainRead(keyAccount) != nil && keychainRead(instanceAccount) != nil {
            status = .licensed
        }
        // Restore cached email (written after every successful validate/activate)
        customerEmail = UserDefaults.standard.string(forKey: customerEmailUD)
    }

    // MARK: - Launch check

    /// Call once in ContentView.onAppear. Makes no network call if recently validated.
    func checkOnLaunch() async {
        guard let key        = keychainRead(keyAccount),
              let instanceId = keychainRead(instanceAccount) else {
            status = .unlicensed; return
        }

        // Still fresh — trust cached result without a network round-trip.
        // With revalidateAfter = 7, most launches skip the network entirely.
        if let last = lastValidatedDate(), daysSince(last) < revalidateAfter {
            status = .licensed; return
        }

        await revalidate(key: key, instanceId: instanceId)
    }

    // MARK: - Activate

    /// Returns nil on success, or a user-facing error string on failure.
    func activate(key: String) async -> String? {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleaned.isEmpty else { return "Please enter a license key." }

        let macName  = Host.current().localizedName ?? "Mac"
        let body     = encode(["license_key": cleaned,
                               "instance_name": "CardRunner \u{2013} \(macName)"])

        guard let (data, http) = try? await request("POST", path: "activate", body: body) else {
            return "Network error. Check your connection and try again."
        }

        // Surface transient server errors before touching the keychain.
        switch http.statusCode {
        case 200...299: break   // OK — fall through to JSON parsing
        case 429:
            return "Too many requests — please wait a moment and try again."
        case 500...599:
            return "Lemon Squeezy server error (\(http.statusCode)). Please try again shortly."
        default:
            break   // fall through; JSON body may contain a usable error message
        }

        guard let json = parse(data) else {
            return "Unexpected server response. Please try again."
        }

        if let activated = json["activated"] as? Bool, activated,
           let inst = json["instance"] as? [String: Any],
           let instId = inst["id"] as? String {

            // Product-ID guard — reject keys that don't belong to an allowed product
            if !allowedProductIDs.isEmpty,
               let meta = json["meta"] as? [String: Any],
               let pid  = meta["product_id"] as? Int,
               !allowedProductIDs.contains(pid) {
                return "This key isn't for CardRunner. Please use the key from your CardRunner purchase."
            }

            // Write to keychain — surface failure rather than silently proceeding
            // and then re-prompting for activation on the next launch.
            guard keychainWrite(keyAccount, value: cleaned),
                  keychainWrite(instanceAccount, value: instId) else {
                return "Failed to save license to keychain. Please try again or restart the app."
            }
            saveValidatedNow()
            if let meta  = json["meta"] as? [String: Any],
               let email = meta["customer_email"] as? String, !email.isEmpty {
                customerEmail = email
                UserDefaults.standard.set(email, forKey: customerEmailUD)
            }
            justActivated = true   // triggers welcome animation in ContentView
            status = .licensed
            return nil   // success
        }

        return extractError(json) ?? "Invalid license key. Please check and try again."
    }

    // MARK: - Deactivate

    /// Removes the license from this Mac and clears local storage.
    /// Returns nil on clean success, or a warning string if the server-side seat
    /// couldn't be freed (offline / server error) — so the user knows to manage
    /// their activations via the Lemon Squeezy portal if they need the seat back.
    func deactivate() async -> String? {
        isDeactivating = true
        defer { isDeactivating = false }

        guard let key    = keychainRead(keyAccount),
              let instId = keychainRead(instanceAccount) else {
            clearKeychain()
            status = .unlicensed
            return nil
        }

        let body = encode(["license_key": key, "instance_id": instId])
        let apiSucceeded: Bool
        if let (_, http) = try? await request("DELETE", path: "deactivate", body: body) {
            apiSucceeded = (200...299).contains(http.statusCode)
        } else {
            apiSucceeded = false   // network error — couldn't reach LS
        }

        // Always clear locally — the user explicitly chose to deactivate.
        clearKeychain()
        status = .unlicensed

        // If the API call failed, warn that the server-side instance may still be
        // consuming an activation seat. The user can clean it up via LS portal.
        if !apiSucceeded {
            return "Deactivated on this Mac. Your Lemon Squeezy instance may still show as active — visit lemonsqueezy.com to remove it if you need to free a seat."
        }
        return nil
    }

    func clearJustActivated() { justActivated = false }

    // MARK: - Masked key for display

    func maskedKey() -> String {
        guard let key = keychainRead(keyAccount) else { return "" }
        let parts = key.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return String(repeating: "•", count: 8) + key.suffix(4) }
        let hidden = Array(repeating: "••••", count: parts.count - 1).joined(separator: "-")
        return "\(hidden)-\(parts.last!)"
    }

    // MARK: - Private: re-validate

    private func revalidate(key: String, instanceId: String) async {
        let body = encode(["license_key": key, "instance_id": instanceId])

        guard let (data, http) = try? await request("POST", path: "validate", body: body) else {
            // Network failure (timeout, no connection, DNS error) — keep key, enter grace.
            // Never wipe the key on a network error.
            applyGrace(); return
        }

        switch http.statusCode {

        case 200:
            guard let json = parse(data) else {
                // 200 but unparseable body (captive portal HTML, schema change) — grace.
                applyGrace(); return
            }
            guard let valid = json["valid"] as? Bool else {
                // 200 + valid JSON but no "valid" field (unexpected LS schema drift) — grace.
                applyGrace(); return
            }
            if valid {
                // Product-ID guard — if key doesn't belong to an allowed product, revoke
                if !allowedProductIDs.isEmpty,
                   let meta = json["meta"] as? [String: Any],
                   let pid  = meta["product_id"] as? Int,
                   !allowedProductIDs.contains(pid) {
                    clearKeychain()
                    status = .revoked
                    return
                }
                // Refresh cached customer email from the latest validation response
                if let meta  = json["meta"] as? [String: Any],
                   let email = meta["customer_email"] as? String, !email.isEmpty {
                    customerEmail = email
                    UserDefaults.standard.set(email, forKey: customerEmailUD)
                }
                saveValidatedNow()
                status = .licensed

            } else {
                // 200 + valid:false — the ONLY authoritative rejection.
                // Key was refunded, disabled, or belongs to a migrated/deleted store.
                // This is the sole path that wipes the key and locks the app.
                clearKeychain()
                status = .revoked
            }

        case 404:
            // LS "license_key not found" — authoritative: key doesn't exist in LS.
            clearKeychain()
            status = .revoked

        default:
            // 408 timeout, 429 rate-limit, 500–599 server errors, redirects,
            // or anything unexpected → transient / ambiguous.
            // Keep the key intact and enter grace. Never wipe on doubt.
            applyGrace()
        }
    }

    private func applyGrace() {
        guard let last = lastValidatedDate() else {
            // Key exists but we've never recorded a successful validation date
            // (e.g. offline on first launch, or migrated from an older build).
            // Grant a full grace window rather than locking out immediately.
            status = .grace(daysLeft: graceDays)
            return
        }
        let left = max(0, graceDays - daysSince(last))
        status = left > 0 ? .grace(daysLeft: left) : .unlicensed
    }

    // MARK: - Private: helpers

    /// Days elapsed since `date`, clamped to 0 if the system clock appears set backward.
    /// A backward clock skew or timezone glitch must never expire grace early (L4).
    private func daysSince(_ date: Date) -> Int {
        let now = Date()
        guard now > date else { return 0 }   // clock went backward — treat as 0 days elapsed
        return Calendar.current.dateComponents([.day], from: date, to: now).day ?? 999
    }

    private func lastValidatedDate() -> Date? {
        UserDefaults.standard.object(forKey: lastValidatedUD) as? Date
    }

    private func saveValidatedNow() {
        UserDefaults.standard.set(Date(), forKey: lastValidatedUD)
    }

    private func extractError(_ json: [String: Any]) -> String? {
        if let e = json["error"] as? String, !e.isEmpty { return e }
        if let arr = json["errors"] as? [[String: Any]],
           let msg = arr.first?["detail"] as? String { return msg }
        return nil
    }

    private func encode(_ params: [String: String]) -> Data {
        params.map { "\($0.key.pctEncoded)=\($0.value.pctEncoded)" }
              .joined(separator: "&")
              .data(using: .utf8) ?? Data()
    }

    private func parse(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Performs a Lemon Squeezy API call. Returns `(Data, HTTPURLResponse)` on success.
    /// Uses a 10 s timeout — fails fast on a flaky shoot network rather than
    /// hanging for the default 60 s and blocking the launch check.
    private func request(_ method: String, path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(apiBase)/\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 10   // fail fast on flaky networks (was 60 s default)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    // MARK: - Keychain

    /// Writes `value` to the keychain. Returns `true` on success.
    /// The return value must be checked before treating the write as durable —
    /// a silent failure here causes the next launch to see no key and trigger
    /// a re-activation flow, burning a Lemon Squeezy activation seat (L3b).
    @discardableResult
    private func keychainWrite(_ account: String, value: String) -> Bool {
        let q: [String: Any] = [kSecClass as String:           kSecClassGenericPassword,
                                kSecAttrService as String:     service,
                                kSecAttrAccount as String:     account,
                                kSecValueData as String:       value.data(using: .utf8) ?? Data(),
                                kSecAttrAccessible as String:  kSecAttrAccessibleAfterFirstUnlock]
        SecItemDelete(q as CFDictionary)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    private func keychainRead(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String:       kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String:  true,
                                kSecMatchLimit as String:  kSecMatchLimitOne]
        var out: AnyObject?
        SecItemCopyMatching(q as CFDictionary, &out)
        guard let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func clearKeychain() {
        for acct in [keyAccount, instanceAccount] {
            let q: [String: Any] = [kSecClass as String:       kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: acct]
            SecItemDelete(q as CFDictionary)
        }
        UserDefaults.standard.removeObject(forKey: lastValidatedUD)
        UserDefaults.standard.removeObject(forKey: customerEmailUD)
        customerEmail = nil
    }
}

// MARK: - String helper

private extension String {
    var pctEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}
