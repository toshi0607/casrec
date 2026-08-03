import Foundation
import ScreenCaptureKit

/// Enumerates the displays and windows available to capture (DESIGN.md §5.2) and
/// resolves thumbnails for them. Stateless — every call re-queries ScreenCaptureKit.
///
/// Deliberately unisolated (no `@MainActor`): `CaptureSource` carries non-`Sendable`
/// SCK/CoreGraphics values, and every method here returns a freshly-built,
/// unaliased value out via `sending`, so callers on any actor (including the
/// nonisolated `CaptureService`, and the `@MainActor` UI that ultimately consumes
/// `observeSources()`) can receive it without a forced actor hop.
enum ShareableContentProvider {

    /// Width, in points, thumbnails are rendered at (§ task spec: "幅約320px").
    private static let thumbnailWidth: CGFloat = 320

    /// Displays and eligible windows, each with a best-effort thumbnail attached.
    /// Windows are listed before displays, matching the design's window-first
    /// picker order (DESIGN.md §7, D2: window capture is the primary mode).
    /// `sending`: callers (see `CaptureService.observeSources()`) yield this straight
    /// into an `AsyncStream` and keep no other reference to it.
    static func fetchSources() async throws -> sending [CaptureSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        let windowSources = content.windows
            .filter(isEligible)
            .map(windowSource(for:))
        let displaySources = content.displays.enumerated()
            .map { index, display in displaySource(for: display, displayNumber: index + 1) }

        return await attachingThumbnails(to: windowSources + displaySources)
    }

    /// The windows currently owned by this process, used to exclude CasRec's own UI
    /// from a full-display capture filter (DESIGN.md §5.2). `sending`: `CaptureService`
    /// (a nonisolated type — see its doc comment) calls this and immediately hands the
    /// result to `SCContentFilter(display:excludingWindows:)` without retaining it, so
    /// it's safe to move the non-Sendable `[SCWindow]` result out of this actor.
    static func ownApplicationWindows() async throws -> sending [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let ownWindows = content.windows.filter(isOwnApplicationWindow)
        return ownWindows
    }

    // MARK: - Eligibility (task spec: exclude self, tiny windows, non-normal layers)

    private static func isEligible(_ window: SCWindow) -> Bool {
        if isOwnApplicationWindow(window) {
            return false
        }
        if window.frame.width < 50 || window.frame.height < 50 {
            return false
        }
        // Best-effort: normal app windows report layer 0 (kCGNormalWindowLevelKey).
        // Panels, menus, and overlay windows sit at other layers; excluding them
        // trims most non-content chrome from the picker without an exhaustive list.
        if window.windowLayer != 0 {
            return false
        }
        return true
    }

    private static func isOwnApplicationWindow(_ window: SCWindow) -> Bool {
        window.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    // MARK: - CaptureSource construction

    private static func windowSource(for window: SCWindow) -> CaptureSource {
        let appName = window.owningApplication?.applicationName
        let title = (window.title?.isEmpty == false ? window.title : nil) ?? appName ?? "Untitled Window"
        return CaptureSource(
            id: "window-\(window.windowID)",
            kind: .window,
            title: title,
            appName: appName,
            frame: window.frame,
            scWindow: window,
            scDisplay: nil,
            thumbnail: nil
        )
    }

    private static func displaySource(for display: SCDisplay, displayNumber: Int) -> CaptureSource {
        CaptureSource(
            id: "display-\(display.displayID)",
            kind: .display,
            title: "Display \(displayNumber) (\(display.width)×\(display.height))",
            appName: nil,
            frame: display.frame,
            scWindow: nil,
            scDisplay: display,
            thumbnail: nil
        )
    }

    // MARK: - Thumbnails

    /// Fetches thumbnails sequentially (not parallelized): `CaptureSource` carries
    /// non-`Sendable` SCK/CoreGraphics types, so fanning this out across a
    /// `TaskGroup` would require unsafely widening their Sendability. At the ~2s
    /// poll interval and typical window counts this is fast enough; revisit if
    /// profiling shows otherwise.
    private static func attachingThumbnails(to sources: sending [CaptureSource]) async -> sending [CaptureSource] {
        var thumbnails: [CGImage?] = []
        thumbnails.reserveCapacity(sources.count)
        for source in sources {
            thumbnails.append(await thumbnail(for: source))
        }
        let withThumbnails = zip(sources, thumbnails).map { source, image in source.withThumbnail(image) }
        return withThumbnails
    }

    /// Captures a ~320pt-wide preview image for `source`. Returns `nil` on any
    /// failure (permission not yet granted, source gone, etc.) — thumbnailing is
    /// best-effort and must never fail source enumeration itself.
    private static func thumbnail(for source: CaptureSource) async -> CGImage? {
        let filter: SCContentFilter
        switch source.kind {
        case .window:
            guard let window = source.scWindow else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: window)
        case .display:
            guard let display = source.scDisplay else { return nil }
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let contentSize = filter.contentRect.size
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }

        let width = thumbnailWidth
        let height = max(2, (width * contentSize.height / contentSize.width).rounded())

        let configuration = SCStreamConfiguration()
        configuration.width = Int(width)
        configuration.height = Int(height)
        configuration.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }
}

extension CaptureSource {
    fileprivate func withThumbnail(_ image: CGImage?) -> CaptureSource {
        CaptureSource(
            id: id,
            kind: kind,
            title: title,
            appName: appName,
            frame: frame,
            scWindow: scWindow,
            scDisplay: scDisplay,
            thumbnail: image
        )
    }
}
