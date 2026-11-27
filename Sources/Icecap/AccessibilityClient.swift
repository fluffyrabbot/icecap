import AppKit
import ApplicationServices
import IcecapCore
import os

/// A menu bar icon together with the Accessibility element that controls it.
struct AccessibleItem: @unchecked Sendable {
    var item: MenuBarItem
    let element: AXUIElement
}

/// The owner of a running process, captured on the main actor for use elsewhere.
private struct ProcessOwner: Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    let name: String
}

/// Carries an `AXUIElement` across actor boundaries without concurrent mutation.
private struct SendableElement: @unchecked Sendable {
    let element: AXUIElement
}

/// Reads and presses other applications' menu bar icons through the Accessibility API.
enum AccessibilityClient {
    /// How long one Accessibility request may take before the application or element is skipped.
    static let requestTimeout: Float = 0.25

    /// Dedicated concurrent queue so blocking Mach Accessibility IPC never starves Swift's
    /// cooperative concurrency thread pool.
    private static let queryQueue = DispatchQueue(
        label: "com.memorysynchub.icecap.accessibility",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let maxConcurrentQueries = 16

    private enum AttributeSlot {
        case value(CFTypeRef)
        case unavailable
        case failed
    }

    private struct ScanState: @unchecked Sendable {
        var nextIndex = 0
        var results: [[AccessibleItem]]
        var isCancelled = false
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Asks the system to show its prompt for granting the Accessibility permission.
    static func requestTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Every menu bar icon of every non-prohibited running application, including this one,
    /// or of the given process alone. Running applications are snapshotted on the main actor,
    /// then queried on `queryQueue` so no main-actor executor assertion runs on worker threads.
    nonisolated static func items(ofProcess processIdentifier: Int32? = nil, includeDescriptions: Bool = true) async -> [AccessibleItem] {
        let owners = await processOwners(ofProcess: processIdentifier)
        return await scanItems(of: owners, includeDescriptions: includeDescriptions)
    }

    @MainActor
    private static func processOwners(ofProcess processIdentifier: Int32?) -> [ProcessOwner] {
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            if let processIdentifier {
                return application.processIdentifier == processIdentifier
            }
            return application.activationPolicy != .prohibited
        }
        return applications.map { application in
            ProcessOwner(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                name: application.localizedName ?? application.bundleIdentifier ?? "Unknown"
            )
        }
    }

    nonisolated private static func scanItems(of owners: [ProcessOwner], includeDescriptions: Bool) async -> [AccessibleItem] {
        guard !owners.isEmpty else { return [] }
        if owners.count == 1 {
            let owner = owners[0]
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queryQueue.async {
                        guard !cancelled.withLock({ $0 }) else {
                            continuation.resume(returning: [])
                            return
                        }
                        continuation.resume(returning: readItems(of: owner, includeDescriptions: includeDescriptions))
                    }
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }

        let state = OSAllocatedUnfairLock(
            initialState: ScanState(results: Array(repeating: [], count: owners.count))
        )
        let group = DispatchGroup()
        let workerCount = min(owners.count, maxConcurrentQueries)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                for _ in 0..<workerCount {
                    group.enter()
                    queryQueue.async {
                        defer { group.leave() }
                        while true {
                            let index: Int? = state.withLock { current in
                                guard !current.isCancelled, current.nextIndex < owners.count else { return nil }
                                let assigned = current.nextIndex
                                current.nextIndex += 1
                                return assigned
                            }
                            guard let index else { return }
                            let ownerItems = readItems(of: owners[index], includeDescriptions: includeDescriptions)
                            state.withLock { current in
                                if !current.isCancelled {
                                    current.results[index] = ownerItems
                                }
                            }
                        }
                    }
                }
                group.notify(queue: queryQueue) {
                    let collected = state.withLock { current in
                        current.isCancelled ? [] : current.results.flatMap { $0 }
                    }
                    continuation.resume(returning: collected)
                }
            }
        } onCancel: {
            state.withLock { $0.isCancelled = true }
        }
    }

    /// The frames of the given application's menu titles, the Apple menu included, as laid
    /// out on the display whose menu bar is active: none for an application that has no
    /// menu bar, and nil when the menu bar or any menu title could not be read reliably.
    nonisolated static func frontMenuTitleFrames(ofProcess processIdentifier: Int32) async -> [CGRect]? {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queryQueue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let application = AXUIElementCreateApplication(processIdentifier)
                    setTimeout(application)
                    var bar: CFTypeRef?
                    switch AXUIElementCopyAttributeValue(application, kAXMenuBarAttribute as CFString, &bar) {
                    case .success: break
                    case .noValue, .attributeUnsupported:
                        continuation.resume(returning: [])
                        return
                    default:
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let barElement = bar as! AXUIElement
                    setTimeout(barElement)
                    var children: CFTypeRef?
                    switch AXUIElementCopyAttributeValue(barElement, kAXChildrenAttribute as CFString, &children) {
                    case .success: break
                    case .noValue, .attributeUnsupported:
                        continuation.resume(returning: [])
                        return
                    default:
                        continuation.resume(returning: nil)
                        return
                    }
                    guard let elements = children as? [AXUIElement] else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let attributes = [kAXPositionAttribute, kAXSizeAttribute]
                    var frames: [CGRect] = []
                    frames.reserveCapacity(elements.count)
                    for element in elements {
                        guard !cancelled.withLock({ $0 }) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        guard let slots = multipleAttributeValues(of: element, attributes: attributes) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        switch (slots[0], slots[1]) {
                        case (.failed, _), (_, .failed):
                            continuation.resume(returning: nil)
                            return
                        case (.unavailable, _), (_, .unavailable):
                            continue
                        case (.value(let positionRaw), .value(let sizeRaw)):
                            guard let frame = cgRect(positionRaw: positionRaw, sizeRaw: sizeRaw) else {
                                continue
                            }
                            frames.append(frame)
                        }
                    }
                    continuation.resume(returning: frames)
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Presses the icon as a click would, off the main actor. Some owners open their menu
    /// yet report that the action could not complete, so that result is treated as success.
    @discardableResult
    nonisolated static func press(_ element: AXUIElement) async -> Bool {
        let wrapped = SendableElement(element: element)
        return await withCheckedContinuation { continuation in
            queryQueue.async {
                setTimeout(wrapped.element)
                let result = AXUIElementPerformAction(wrapped.element, kAXPressAction as CFString)
                continuation.resume(returning: result == .success || result == .cannotComplete)
            }
        }
    }

    nonisolated private static func setTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, requestTimeout)
    }

    nonisolated private static func readItems(of owner: ProcessOwner, includeDescriptions: Bool) -> [AccessibleItem] {
        let application = AXUIElementCreateApplication(owner.processIdentifier)
        setTimeout(application)
        var bar: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, "AXExtrasMenuBar" as CFString, &bar) == .success,
            let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        let barElement = bar as! AXUIElement
        setTimeout(barElement)
        var children: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(barElement, kAXChildrenAttribute as CFString, &children) == .success,
            let elements = children as? [AXUIElement]
        else { return [] }
        let attributes = includeDescriptions
            ? [kAXPositionAttribute, kAXSizeAttribute, kAXDescriptionAttribute]
            : [kAXPositionAttribute, kAXSizeAttribute]
        return elements.enumerated().compactMap { index, element in
            guard
                let slots = multipleAttributeValues(of: element, attributes: attributes),
                case .value(let positionRaw) = slots[0],
                case .value(let sizeRaw) = slots[1],
                let frame = cgRect(positionRaw: positionRaw, sizeRaw: sizeRaw)
            else { return nil }
            var descriptionText: String?
            if includeDescriptions, case .value(let descriptionRaw) = slots[2] {
                descriptionText = descriptionRaw as? String
            }
            let item = MenuBarItem(
                processIdentifier: owner.processIdentifier,
                bundleIdentifier: owner.bundleIdentifier,
                applicationName: owner.name,
                accessibilityDescription: descriptionText,
                index: index,
                frame: frame
            )
            return AccessibleItem(item: item, element: element)
        }
    }

    nonisolated private static func multipleAttributeValues(
        of element: AXUIElement,
        attributes: [String]
    ) -> [AttributeSlot]? {
        setTimeout(element)
        var rawValues: CFArray?
        switch AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &rawValues) {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            return Array(repeating: .unavailable, count: attributes.count)
        default:
            return nil
        }
        guard let rawValues else {
            return nil
        }
        let array = rawValues as [AnyObject]
        guard array.count == attributes.count else {
            return nil
        }
        return array.map { raw in
            if CFGetTypeID(raw) == CFNullGetTypeID() {
                return .unavailable
            }
            if CFGetTypeID(raw) == AXValueGetTypeID() {
                let value = raw as! AXValue
                if AXValueGetType(value) == .axError {
                    var errorCode = AXError.success
                    guard AXValueGetValue(value, .axError, &errorCode) else { return .failed }
                    switch errorCode {
                    case .noValue, .attributeUnsupported:
                        return .unavailable
                    default:
                        return .failed
                    }
                }
            }
            return .value(raw)
        }
    }

    nonisolated private static func cgRect(positionRaw: CFTypeRef, sizeRaw: CFTypeRef) -> CGRect? {
        guard
            CFGetTypeID(positionRaw) == AXValueGetTypeID(),
            CFGetTypeID(sizeRaw) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard
            AXValueGetValue(positionRaw as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }
}
