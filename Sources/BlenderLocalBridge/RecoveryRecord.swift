import Foundation
import Security

/// The recovery file as the app last wrote it, kept where a script cannot
/// write: the keychain.
///
/// RootView opens `autosave.blend` at launch as the app's own file, which the
/// vertex budget's gate lets Blender evaluate as it was saved
/// (`_blenderkit_gate.opening`). A script can write that file too (one Run
/// line with `bpy.data.libraries.write`, then the app killed before its next
/// autosave), and the review of fix round 3 (October 29) measured the same
/// design in the undo history: a heavy scene copied over the history's files
/// was opened by the next Undo at 160,000 vertices past a budget lowered to
/// 100,000. So the file's identity is kept as the app writes it — device,
/// inode, size, and the modification and status-change times, the last of
/// which only the system sets — and the launch opens it as saved only while
/// it is still so; a file that changed since is priced as a script's load.
/// With no record (the first launch of a build that keeps one) it opens as
/// before. A Python script reaches the keychain only through ctypes, which
/// is past the gate anyway (docs/blender-local.md, the gate's limits).
public enum RecoveryRecord {
    static let service = "BlenderLocal.recovery-file"
    static let account = "autosave.blend"

    public enum Verdict: Equatable, Sendable {
        /// As the app last wrote it.
        case asWritten
        /// Written, renamed over or touched since the app wrote it.
        case changed
        /// No record kept (the first launch with one, or no keychain).
        case unknown
    }

    /// The file's identity: device, inode, size, and modification and
    /// status-change times in nanoseconds.
    public static func identity(of path: String) -> [Int64]? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        func ns(_ t: timespec) -> Int64 { Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec) }
        return [Int64(info.st_dev), Int64(bitPattern: UInt64(info.st_ino)), Int64(info.st_size),
                ns(info.st_mtimespec), ns(info.st_ctimespec)]
    }

    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Keeps the identity of `path` as the app has just written it. Returns
    /// whether the keychain took it.
    @discardableResult
    public static func record(_ path: String) -> Bool {
        guard let identity = identity(of: path),
              let data = try? JSONEncoder().encode(identity) else { return false }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        #if DEBUG
        if status != errSecSuccess { print("[bk-recovery] keychain record failed: \(status)") }
        #endif
        return status == errSecSuccess
    }

    public static func verdict(_ path: String) -> Verdict {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let kept: [Int64]?
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let data = found as? Data {
            kept = try? JSONDecoder().decode([Int64].self, from: data)
        } else {
            kept = nil
        }
        return verdict(now: identity(of: path), kept: kept)
    }

    /// The file as it is `now` against what was `kept` when the app wrote it.
    public static func verdict(now: [Int64]?, kept: [Int64]?) -> Verdict {
        guard let kept else { return .unknown }
        return now == kept ? .asWritten : .changed
    }
}
