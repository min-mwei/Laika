import Foundation

public enum ToolErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidArguments = "INVALID_ARGUMENTS"
    case missingUrl = "MISSING_URL"
    case invalidUrl = "INVALID_URL"
    case noActiveTab = "NO_ACTIVE_TAB"
    case noTargetTab = "NO_TARGET_TAB"
    case noContext = "NO_CONTEXT"
    case unsupportedTool = "UNSUPPORTED_TOOL"
    case openTabFailed = "OPEN_TAB_FAILED"
    case navigationFailed = "NAVIGATION_FAILED"
    case backFailed = "BACK_FAILED"
    case forwardFailed = "FORWARD_FAILED"
    case refreshFailed = "REFRESH_FAILED"
    case notFound = "NOT_FOUND"
    case staleHandle = "STALE_HANDLE"
    case notInteractable = "NOT_INTERACTABLE"
    case disabled = "DISABLED"
    case blockedByOverlay = "BLOCKED_BY_OVERLAY"
    case searchUnavailable = "SEARCH_UNAVAILABLE"
    case searchFailed = "SEARCH_FAILED"
    case runtimeUnavailable = "RUNTIME_UNAVAILABLE"
}

public enum ObservationSignal: String, Codable, CaseIterable, Sendable {
    case paywallOrLogin = "paywall_or_login"
    case consentModal = "consent_modal"
    case captchaOrRobotCheck = "captcha_or_robot_check"
    case overlayBlocking = "overlay_blocking"
    case sparseText = "sparse_text"
    case nonTextContent = "non_text_content"
    case crossOriginIframe = "cross_origin_iframe"
    case closedShadowRoot = "closed_shadow_root"
    case virtualizedList = "virtualized_list"
    case infiniteScroll = "infinite_scroll"
    case pdfViewer = "pdf_viewer"
    case urlRedacted = "url_redacted"
    case ageGate = "age_gate"
    case geoBlock = "geo_block"
    case scriptRequired = "script_required"
}

public enum ObservationSignalNormalizer {
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty {
            return ""
        }
        switch trimmed {
        case "paywall", "auth_gate", "auth_fields":
            return ObservationSignal.paywallOrLogin.rawValue
        case "consent_overlay":
            return ObservationSignal.consentModal.rawValue
        case "overlay_or_dialog":
            return ObservationSignal.overlayBlocking.rawValue
        case "robot_check_text":
            return ObservationSignal.captchaOrRobotCheck.rawValue
        case "low_visible_text", "low_signal_text":
            return ObservationSignal.sparseText.rawValue
        default:
            return trimmed
        }
    }

    public static var accessLimitSignals: Set<String> {
        [
            ObservationSignal.paywallOrLogin.rawValue,
            ObservationSignal.consentModal.rawValue,
            ObservationSignal.captchaOrRobotCheck.rawValue,
            ObservationSignal.overlayBlocking.rawValue,
            ObservationSignal.ageGate.rawValue,
            ObservationSignal.geoBlock.rawValue,
            ObservationSignal.scriptRequired.rawValue
        ]
    }
}
