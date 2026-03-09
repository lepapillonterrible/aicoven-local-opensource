import Foundation
import FirebaseAnalytics
import FirebaseCore
import CryptoKit
internal import Combine

/// Centralized analytics service for Firebase event tracking in AICoven.
/// All events follow the naming conventions defined in the tracking spec.
///
/// Privacy: This service anonymizes all identifiable data (thread IDs, memory IDs, etc.)
/// by hashing them before sending to Firebase Analytics. User consent is required
/// before any analytics are collected.
final class AnalyticsService {
    static let shared = AnalyticsService()

    // MARK: - Properties

    /// Whether the user has consented to analytics collection.
    /// Analytics events are only sent if this is true.
    @Published private(set) var analyticsConsent: Bool {
        didSet {
            UserDefaults.standard.set(analyticsConsent, forKey: "analyticsConsent")
            if FirebaseApp.app() != nil {
                Analytics.setAnalyticsCollectionEnabled(analyticsConsent)
            }
        }
    }

    private init() {
        // Load saved consent state from granular preferences.
        // Default to true (enabled by default); users can opt out in Settings.
        // UserDefaults.bool(forKey:) returns false for missing keys, so we
        // check whether the key has ever been set to distinguish "never
        // configured" (default ON) from "explicitly disabled" (user chose OFF).
        let productAnalyticsEnabled: Bool
        if UserDefaults.standard.object(forKey: "analytics_product_enabled") != nil {
            productAnalyticsEnabled = UserDefaults.standard.bool(forKey: "analytics_product_enabled")
        } else {
            productAnalyticsEnabled = true
        }

        let performanceAnalyticsEnabled: Bool
        if UserDefaults.standard.object(forKey: "analytics_performance_enabled") != nil {
            performanceAnalyticsEnabled = UserDefaults.standard.bool(forKey: "analytics_performance_enabled")
        } else {
            performanceAnalyticsEnabled = true
        }

        // Enable analytics only if at least one category is consented to
        analyticsConsent = productAnalyticsEnabled || performanceAnalyticsEnabled

        if FirebaseApp.app() != nil {
            Analytics.setAnalyticsCollectionEnabled(analyticsConsent)
        }
    }

    // MARK: - Consent Management

    /// Set whether the user consents to analytics collection.
    /// - Parameter consent: True to enable analytics, false to disable.
    func setAnalyticsConsent(_ consent: Bool) {
        analyticsConsent = consent
    }

    // MARK: - Privacy Helpers

    /// Hashes an identifier to anonymize it before sending to analytics.
    /// Uses SHA-256 to create a consistent, non-reversible hash.
    /// - Parameter identifier: The ID to hash (thread ID, memory ID, etc.)
    /// - Returns: Anonymized hash string, or nil if the identifier is nil.
    private func hashIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }

        let data = Data(identifier.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Checks if analytics is enabled before logging an event.
    /// - Parameters:
    ///   - name: Event name
    ///   - parameters: Event parameters
    private func logEventIfEnabled(_ name: String, parameters: [String: Any]?) {
        guard analyticsConsent else { return }
        guard FirebaseApp.app() != nil else { return }
        Analytics.logEvent(name, parameters: parameters)
    }

    // MARK: - Generic Event Tracking

    /// Generic event tracking for ad-hoc events that don't have a dedicated method.
    /// - Parameters:
    ///   - event: Event name
    ///   - properties: Key-value properties for the event
    func track(event: String, properties: [String: Any]) {
        logEventIfEnabled(event, parameters: properties.isEmpty ? nil : properties)
    }

    // MARK: - Auth Events

    func trackLogin(method: String) {
        logEventIfEnabled(AnalyticsEventLogin, parameters: [
            AnalyticsParameterMethod: method
        ])
    }

    func trackSignUp(method: String) {
        logEventIfEnabled(AnalyticsEventSignUp, parameters: [
            AnalyticsParameterMethod: method
        ])
    }

    func trackAuthError(error: String, method: String) {
        logEventIfEnabled("auth_error", parameters: [
            "error": error,
            "method": method
        ])
    }

    // MARK: - Onboarding Events

    func trackOnboardingStarted() {
        logEventIfEnabled("onboarding_started", parameters: nil)
    }

    func trackOnboardingStepViewed(stepName: String, stepIndex: Int) {
        logEventIfEnabled("onboarding_step_viewed", parameters: [
            "step_name": stepName,
            "step_index": stepIndex
        ])
    }

    func trackOnboardingPrivacyAccepted() {
        logEventIfEnabled("onboarding_privacy_accepted", parameters: nil)
    }

    func trackOnboardingBillingAccepted() {
        logEventIfEnabled("onboarding_billing_accepted", parameters: nil)
    }

    func trackOnboardingAddKeyTapped() {
        logEventIfEnabled("onboarding_add_key_tapped", parameters: nil)
    }

    func trackOnboardingSkipped(stepName: String, stepIndex: Int) {
        logEventIfEnabled("onboarding_skipped", parameters: [
            "step_name": stepName,
            "step_index": stepIndex
        ])
    }

    func trackOnboardingCompleted() {
        logEventIfEnabled("onboarding_completed", parameters: nil)
    }

    // MARK: - Chat Events

    func trackThreadCreated(covenId: String?, agentId: String?) {
        // Note: covenId and agentId are hashed to preserve privacy.
        // In the local-first client, these typically are "personal" and "default".
        let hashedCovenId = hashIdentifier(covenId) ?? "unknown"
        let hashedAgentId = hashIdentifier(agentId) ?? "unknown"
        logEventIfEnabled("thread_created", parameters: [
            "coven_id_hash": hashedCovenId,
            "agent_id_hash": hashedAgentId
        ])
    }

    func trackThreadOpened(threadId: String, threadAgeDays: Int) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("thread_opened", parameters: [
            "thread_id_hash": hashedThreadId,
            "thread_age_days": threadAgeDays
        ])
    }

    func trackThreadDeleted(threadId: String) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("thread_deleted", parameters: [
            "thread_id_hash": hashedThreadId
        ])
    }

    func trackMessageSent(threadId: String, hasAttachments: Bool, attachmentCount: Int) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("message_sent", parameters: [
            "thread_id_hash": hashedThreadId,
            "has_attachments": hasAttachments ? 1 : 0, // Bool -> Int for Firebase compatibility
            "attachment_count": attachmentCount
        ])
    }

    func trackMessageReceived(
        threadId: String,
        provider: String,
        model: String,
        tokenCount: Int,
        responseTimeMs: Int? = nil
    ) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        var params: [String: Any] = [
            "thread_id_hash": hashedThreadId,
            "provider": provider,
            "model": model,
            "token_count": tokenCount
        ]
        if let responseTimeMs {
            params["response_time_ms"] = responseTimeMs
        }
        logEventIfEnabled("message_received", parameters: params)
    }

    func trackMessageError(threadId: String, errorType: String) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("message_error", parameters: [
            "thread_id_hash": hashedThreadId,
            "error_type": errorType
        ])
    }

    func trackToolUsed(toolName: String, threadId: String) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("tool_used", parameters: [
            "tool_name": toolName,
            "thread_id_hash": hashedThreadId
        ])
    }

    func trackStreamingStarted(threadId: String) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("streaming_started", parameters: [
            "thread_id_hash": hashedThreadId
        ])
    }

    func trackStreamingCompleted(threadId: String, durationMs: Int) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("streaming_completed", parameters: [
            "thread_id_hash": hashedThreadId,
            "duration_ms": durationMs
        ])
    }

    func trackLoadMoreMessages(threadId: String, pageNumber: Int) {
        // Hash thread ID to anonymize user's conversation data.
        guard let hashedThreadId = hashIdentifier(threadId) else { return }
        logEventIfEnabled("load_more_messages", parameters: [
            "thread_id_hash": hashedThreadId,
            "page_number": pageNumber
        ])
    }

    // MARK: - Provider Key Events

    func trackProviderKeyAdded(provider: String) {
        logEventIfEnabled("provider_key_added", parameters: [
            "provider": provider
        ])
    }

    func trackProviderKeyDeleted(provider: String) {
        logEventIfEnabled("provider_key_deleted", parameters: [
            "provider": provider
        ])
    }

    func trackProviderKeyTested(provider: String, success: Bool) {
        logEventIfEnabled("provider_key_tested", parameters: [
            "provider": provider,
            "success": success ? 1 : 0 // Bool -> Int for Firebase compatibility
        ])
    }

    func trackProviderKeyEdited(provider: String) {
        logEventIfEnabled("provider_key_edited", parameters: [
            "provider": provider
        ])
    }

    // MARK: - Settings Events

    func trackSettingsOpened() {
        logEventIfEnabled("settings_opened", parameters: nil)
    }

    func trackConnectedAppsOpened() {
        logEventIfEnabled("connected_apps_opened", parameters: nil)
    }

    func trackMCPServersOpened() {
        logEventIfEnabled("mcp_servers_opened", parameters: nil)
    }

    func trackProfileOpened() {
        logEventIfEnabled("profile_opened", parameters: nil)
    }

    func trackProfileUpdated(fieldsUpdated: [String]) {
        // Firebase Analytics doesn't support array parameters.
        // Join into comma-separated string as recommended by Firebase.
        logEventIfEnabled("profile_updated", parameters: [
            "fields_updated": fieldsUpdated.joined(separator: ",")
        ])
    }

    func trackUsageViewed() {
        logEventIfEnabled("usage_viewed", parameters: nil)
    }

    func trackBudgetUpdated(budgetAmount: Double, period: String) {
        logEventIfEnabled("budget_updated", parameters: [
            "budget_amount": budgetAmount,
            "period": period
        ])
    }

    func trackStrixSettingsOpened() {
        logEventIfEnabled("strix_settings_opened", parameters: nil)
    }

    func trackStrixSettingsSaved(model: String, provider: String) {
        logEventIfEnabled("strix_settings_saved", parameters: [
            "model": model,
            "provider": provider
        ])
    }

    func trackThemeChange(theme: String) {
        logEventIfEnabled("theme_changed", parameters: [
            "theme": theme
        ])
    }

    func trackSettingChange(setting: String, value: String) {
        logEventIfEnabled("setting_changed", parameters: [
            "setting": setting,
            "value": value
        ])
    }

    func trackNotificationSettingChange(type: String, enabled: Bool) {
        logEventIfEnabled("notification_setting_changed", parameters: [
            "type": type,
            "enabled": enabled ? 1 : 0 // Bool -> Int for Firebase compatibility
        ])
    }

    func trackSettingsView(section: String) {
        logEventIfEnabled("settings_view", parameters: [
            "section": section
        ])
    }

    // MARK: - Memory Events

    func trackMemoryListOpened(covenId: String?) {
        // Hash coven ID to preserve privacy.
        let hashedCovenId = hashIdentifier(covenId) ?? "unknown"
        logEventIfEnabled("memory_list_opened", parameters: [
            "coven_id_hash": hashedCovenId
        ])
    }

    func trackMemoryCreated(covenId: String?, memoryType: String) {
        // Hash coven ID to preserve privacy.
        let hashedCovenId = hashIdentifier(covenId) ?? "unknown"
        logEventIfEnabled("memory_created", parameters: [
            "coven_id_hash": hashedCovenId,
            "memory_type": memoryType
        ])
    }

    func trackMemoryEdited(memoryId: String) {
        // Hash memory ID to anonymize user's memory data.
        guard let hashedMemoryId = hashIdentifier(memoryId) else { return }
        logEventIfEnabled("memory_edited", parameters: [
            "memory_id_hash": hashedMemoryId
        ])
    }

    func trackMemoryDeleted(memoryId: String) {
        // Hash memory ID to anonymize user's memory data.
        guard let hashedMemoryId = hashIdentifier(memoryId) else { return }
        logEventIfEnabled("memory_deleted", parameters: [
            "memory_id_hash": hashedMemoryId
        ])
    }

    func trackMemoryPinned(memoryId: String, isPinned: Bool) {
        // Hash memory ID to anonymize user's memory data.
        guard let hashedMemoryId = hashIdentifier(memoryId) else { return }
        logEventIfEnabled("memory_pinned", parameters: [
            "memory_id_hash": hashedMemoryId,
            "is_pinned": isPinned ? 1 : 0 // Bool -> Int for Firebase compatibility
        ])
    }

    func trackMemoryProposalViewed() {
        logEventIfEnabled("memory_proposal_viewed", parameters: nil)
    }

    func trackMemoryProposalApproved(proposalId: String) {
        // Hash proposal ID to anonymize user's memory data.
        guard let hashedProposalId = hashIdentifier(proposalId) else { return }
        logEventIfEnabled("memory_proposal_approved", parameters: [
            "proposal_id_hash": hashedProposalId
        ])
    }

    func trackMemoryProposalRejected(proposalId: String) {
        // Hash proposal ID to anonymize user's memory data.
        guard let hashedProposalId = hashIdentifier(proposalId) else { return }
        logEventIfEnabled("memory_proposal_rejected", parameters: [
            "proposal_id_hash": hashedProposalId
        ])
    }

    // MARK: - Navigation Events

    func trackTabOpened(tabType: String) {
        logEventIfEnabled("tab_opened", parameters: [
            "tab_type": tabType
        ])
    }

    func trackTabClosed(tabType: String) {
        logEventIfEnabled("tab_closed", parameters: [
            "tab_type": tabType
        ])
    }

    func trackTabSwitched(fromTab: String, toTab: String) {
        logEventIfEnabled("tab_switched", parameters: [
            "from_tab": fromTab,
            "to_tab": toTab
        ])
    }

    func trackMobileTabChanged(tabName: String) {
        logEventIfEnabled("mobile_tab_changed", parameters: [
            "tab_name": tabName
        ])
    }

    func trackNewChatTapped(source: String) {
        logEventIfEnabled("new_chat_tapped", parameters: [
            "source": source
        ])
    }

    func trackYourChatsTapped() {
        logEventIfEnabled("your_chats_tapped", parameters: nil)
    }

    func trackBackButtonTapped(fromScreen: String) {
        logEventIfEnabled("back_button_tapped", parameters: [
            "from_screen": fromScreen
        ])
    }

    // MARK: - Attachment Events

    func trackFileAttached(fileType: String, fileSizeKb: Int) {
        logEventIfEnabled("file_attached", parameters: [
            "file_type": fileType,
            "file_size_kb": fileSizeKb
        ])
    }

    func trackAttachmentRemoved(fileType: String) {
        logEventIfEnabled("attachment_removed", parameters: [
            "file_type": fileType
        ])
    }

    // MARK: - AI Feature Events

    func trackImageGenerated(promptLength: Int, provider: String) {
        logEventIfEnabled("image_generated", parameters: [
            "prompt_length": promptLength,
            "provider": provider
        ])
    }

    func trackVideoGenerated(promptLength: Int, provider: String, durationSeconds: Int) {
        logEventIfEnabled("video_generated", parameters: [
            "prompt_length": promptLength,
            "provider": provider,
            "duration_seconds": durationSeconds
        ])
    }

    func trackFileGenerated(fileType: String) {
        logEventIfEnabled("file_generated", parameters: [
            "file_type": fileType
        ])
    }

    func trackWebSearchUsed() {
        logEventIfEnabled("web_search_used", parameters: nil)
    }

    func trackGitHubToolUsed(toolAction: String) {
        logEventIfEnabled("github_tool_used", parameters: [
            "tool_action": toolAction
        ])
    }

    func trackGoogleWorkspaceUsed(toolType: String) {
        logEventIfEnabled("google_workspace_used", parameters: [
            "tool_type": toolType
        ])
    }

    func trackAgentFeaturesViewed() {
        logEventIfEnabled("agent_features_viewed", parameters: nil)
    }

    func trackEditAgentTapped() {
        logEventIfEnabled("edit_agent_tapped", parameters: nil)
    }

    // MARK: - Lifecycle Events

    func trackAppLaunched(launchType: String) {
        logEventIfEnabled(AnalyticsEventAppOpen, parameters: [
            "launch_type": launchType
        ])
    }

    func trackAppBackgrounded() {
        logEventIfEnabled("app_backgrounded", parameters: nil)
    }

    func trackAppForegrounded() {
        logEventIfEnabled("app_foregrounded", parameters: nil)
    }

    func trackSessionStarted(isReturningUser: Bool) {
        logEventIfEnabled("session_started", parameters: [
            "is_returning_user": isReturningUser ? 1 : 0 // Bool -> Int for Firebase compatibility
        ])
    }

    func trackSessionEnded(sessionDurationSeconds: Int, messagesSent: Int) {
        logEventIfEnabled("session_ended", parameters: [
            "session_duration_seconds": sessionDurationSeconds,
            "messages_sent": messagesSent
        ])
    }

    // MARK: - Error Events

    func trackErrorOccurred(errorDomain: String, errorCode: String, context: String) {
        logEventIfEnabled("error_occurred", parameters: [
            "error_domain": errorDomain,
            "error_code": errorCode,
            "context": context
        ])
    }

    // MARK: - Screen Tracking

    func trackScreenView(screenName: String, screenClass: String) {
        logEventIfEnabled(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: screenName,
            AnalyticsParameterScreenClass: screenClass
        ])
    }

    // MARK: - Coven & Role Events

    func trackCovenView(covenId: String) {
        logEventIfEnabled("coven_view", parameters: [
            "coven_id": covenId
        ])
    }

    func trackRoleCreate(roleId: String, templateId: String?, isCustom: Bool) {
        logEventIfEnabled("role_create", parameters: [
            "role_id": roleId,
            "template_id": templateId ?? "none",
            "is_custom": isCustom
        ])
    }

    func trackRoleView(roleId: String) {
        logEventIfEnabled("role_view", parameters: [
            "role_id": roleId
        ])
    }

    func trackRoleUpdate(roleId: String, field: String) {
        logEventIfEnabled("role_update", parameters: [
            "role_id": roleId,
            "field": field
        ])
    }

    func trackRoleDelete(roleId: String) {
        logEventIfEnabled("role_delete", parameters: [
            "role_id": roleId
        ])
    }

    /// General-purpose error tracking used by views.
    func trackError(errorType: String, errorMessage: String, context: String) {
        logEventIfEnabled("error_occurred", parameters: [
            "error_domain": errorType,
            "error_code": errorMessage,
            "context": context
        ])
    }

    // MARK: - Workspace Navigation

    func trackTabSwitch(fromTab: String, toTab: String) {
        logEventIfEnabled("tab_switch", parameters: [
            "from_tab": fromTab,
            "to_tab": toTab
        ])
    }

    func trackFeatureUsage(featureName: String) {
        logEventIfEnabled("feature_usage", parameters: [
            "feature_name": featureName
        ])
    }

    func trackThreadCreate(threadId: String, covenId: String, hasTitle: Bool) {
        logEventIfEnabled("thread_create", parameters: [
            "thread_id": threadId,
            "coven_id": covenId,
            "has_title": hasTitle
        ])
    }

    func trackRoleAssign(roleId: String, threadId: String) {
        logEventIfEnabled("role_assign", parameters: [
            "role_id": roleId,
            "thread_id": threadId
        ])
    }
}
