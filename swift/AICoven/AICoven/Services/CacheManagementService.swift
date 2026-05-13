import Foundation

struct CacheClearResult: Equatable {
    let removedItems: Int

    var userMessage: String {
        if removedItems == 0 {
            return "No cached files needed clearing."
        }
        return "Cleared local cache. Your chats, memories, and provider keys were not changed."
    }
}

/// Clears disposable local caches only. This intentionally does not remove
/// user-authored data, encrypted databases, provider credentials, memories, or
/// thread JSON stores.
enum CacheManagementService {
    @discardableResult
    static func clearLocalCaches() -> CacheClearResult {
        URLCache.shared.removeAllCachedResponses()
        let removedItems = PricingUpdateService.shared.clearCachedOverrides()
        AppErrorReporter.log(message: "Cleared disposable local caches", context: "CacheManagementService.clearLocalCaches")
        return CacheClearResult(removedItems: removedItems)
    }
}
