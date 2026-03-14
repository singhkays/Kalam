import AppKit
import ApplicationServices

struct AccessibilityFocusedElementResolution {
    let element: AXUIElement
    let appName: String
    let strategy: String
}

struct AccessibilityFocusResolutionError: Error {
    let reason: String
}

enum AccessibilityFocusResolver {
    private static let descendantSearchDepth = 12
    private static let messagingTimeoutSeconds: Float = 0.75

    static func focusedElement() -> AXUIElement? {
        switch resolveFocusedElement() {
        case .success(let resolution):
            return resolution.element
        case .failure:
            return nil
        }
    }

    static func resolveFocusedElement(
        frontmostApp: NSRunningApplication? = NSWorkspace.shared.frontmostApplication
    ) -> Result<AccessibilityFocusedElementResolution, AccessibilityFocusResolutionError> {
        let appName = frontmostApp?.localizedName ?? "UnknownApp"
        let expectedPID = frontmostApp?.processIdentifier
        var diagnostics: [String] = []

        let systemWideElement = AXUIElementCreateSystemWide()
        if let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: systemWideElement,
            label: "System-wide focused element",
            diagnostics: &diagnostics
        ) {
            if let expectedPID, let resolvedPID = pid(of: focusedElement), resolvedPID != expectedPID {
                diagnostics.append(
                    "System-wide focused element belonged to pid \(resolvedPID), expected pid \(expectedPID)"
                )
            } else {
                return .success(
                    AccessibilityFocusedElementResolution(
                        element: focusedElement,
                        appName: appName,
                        strategy: "system-wide focused element"
                    )
                )
            }
        }

        guard let frontmostApp else {
            let detail = diagnostics.isEmpty
                ? "No frontmost application found."
                : diagnostics.joined(separator: "; ")
            return .failure(AccessibilityFocusResolutionError(reason: detail))
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(appElement, messagingTimeoutSeconds)

        if let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: appElement,
            label: "Frontmost app focused element",
            diagnostics: &diagnostics
        ) {
            return .success(
                AccessibilityFocusedElementResolution(
                    element: focusedElement,
                    appName: appName,
                    strategy: "frontmost app focused element"
                )
            )
        }

        if let windowElement = copyElementAttribute(
            kAXFocusedWindowAttribute as CFString,
            from: appElement,
            label: "Frontmost app focused window",
            diagnostics: &diagnostics
        ) {
            _ = AXUIElementSetMessagingTimeout(windowElement, messagingTimeoutSeconds)

            if let focusedElement = copyElementAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: windowElement,
                label: "Focused window focused element",
                diagnostics: &diagnostics
            ) {
                return .success(
                    AccessibilityFocusedElementResolution(
                        element: focusedElement,
                        appName: appName,
                        strategy: "focused window focused element"
                    )
                )
            }

            if let focusedDescendant = findFocusedDescendant(
                in: windowElement,
                depth: 0,
                maxDepth: descendantSearchDepth
            ) {
                return .success(
                    AccessibilityFocusedElementResolution(
                        element: focusedDescendant,
                        appName: appName,
                        strategy: "focused window descendant search"
                    )
                )
            }

            diagnostics.append("Focused window descendant search found no focused child")
        }

        let detail = diagnostics.isEmpty
            ? "No Accessibility focus path succeeded."
            : diagnostics.joined(separator: "; ")
        return .failure(
            AccessibilityFocusResolutionError(
                reason: "Could not resolve focused element for \(appName). \(detail)"
            )
        )
    }

    private static func copyElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement,
        label: String,
        diagnostics: inout [String]
    ) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success else {
            diagnostics.append("\(label) failed with \(error.debugName)")
            return nil
        }

        guard let value else {
            diagnostics.append("\(label) returned no value")
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            diagnostics.append("\(label) returned a non-element value")
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func findFocusedDescendant(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int
    ) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef as? Bool,
           focused {
            return element
        }

        guard depth < maxDepth else { return nil }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                _ = AXUIElementSetMessagingTimeout(child, messagingTimeoutSeconds)
                if let focusedElement = findFocusedDescendant(
                    in: child,
                    depth: depth + 1,
                    maxDepth: maxDepth
                ) {
                    return focusedElement
                }
            }
        }

        return nil
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }
}

extension AXError {
    var debugName: String {
        switch self {
        case .success:
            return "success (0)"
        case .failure:
            return "failure (-25200)"
        case .illegalArgument:
            return "illegalArgument (-25201)"
        case .invalidUIElement:
            return "invalidUIElement (-25202)"
        case .invalidUIElementObserver:
            return "invalidUIElementObserver (-25203)"
        case .cannotComplete:
            return "cannotComplete (-25204)"
        case .attributeUnsupported:
            return "attributeUnsupported (-25205)"
        case .actionUnsupported:
            return "actionUnsupported (-25206)"
        case .notificationUnsupported:
            return "notificationUnsupported (-25207)"
        case .notImplemented:
            return "notImplemented (-25208)"
        case .notificationAlreadyRegistered:
            return "notificationAlreadyRegistered (-25209)"
        case .notificationNotRegistered:
            return "notificationNotRegistered (-25210)"
        case .apiDisabled:
            return "apiDisabled (-25211)"
        case .noValue:
            return "noValue (-25212)"
        case .parameterizedAttributeUnsupported:
            return "parameterizedAttributeUnsupported (-25213)"
        case .notEnoughPrecision:
            return "notEnoughPrecision (-25214)"
        @unknown default:
            return "unknown (\(rawValue))"
        }
    }
}
