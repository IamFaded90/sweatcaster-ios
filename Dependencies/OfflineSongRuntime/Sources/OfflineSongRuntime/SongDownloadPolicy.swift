import Foundation

/// A stale resume record can produce a successful but incomplete file, or an
/// expired URL. In those cases one fresh download can make progress. Preserve
/// the resume record for transient server errors so it can be tried later.
enum SongDownloadPolicy {
    static func restartAfterResume(status: Int?, received: Int64?, expected: Int64) -> Bool {
        guard expected > 0, let status else { return false }
        if [401, 403, 404, 410, 416].contains(status) { return true }
        return [200, 206].contains(status) && received != expected
    }
}
