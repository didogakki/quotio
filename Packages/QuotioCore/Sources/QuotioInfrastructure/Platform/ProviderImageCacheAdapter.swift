import AppKit

@MainActor
public final class ProviderImageCacheAdapter {
    private let cache = NSCache<NSString, NSImage>()
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private nonisolated(unsafe) var activityObservers: [NSObjectProtocol] = []

    public init() {
        cache.countLimit = 50
        cache.totalCostLimit = 10 * 1_024 * 1_024
        installMemoryHandlers()
    }

    deinit {
        memoryPressureSource?.cancel()
        for observer in activityObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    public func image(named name: String, size: CGFloat? = nil) -> NSImage? {
        // Asset catalog images can ship separate Any/Dark appearance variants (e.g.
        // Grok's logomark). Redrawing below bakes in whichever variant was active at
        // draw time, so the cache key — and the draw itself — must be pinned to the
        // *current* effective appearance or a later appearance switch would keep
        // serving the stale bitmap.
        let appearanceSuffix = isDarkAppearance ? "dark" : "light"
        let key = size.map { "\(name)_\(Int($0))_\(appearanceSuffix)" } ?? "\(name)_\(appearanceSuffix)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let original = NSImage(named: name) else { return nil }

        let image: NSImage
        if let size, size < min(original.size.width, original.size.height) {
            let targetSize = NSSize(width: size, height: size)
            let resized = NSImage(size: targetSize)
            currentAppearance.performAsCurrentDrawingAppearance {
                resized.lockFocus()
                original.draw(
                    in: NSRect(origin: .zero, size: targetSize),
                    from: NSRect(origin: .zero, size: original.size),
                    operation: .copy,
                    fraction: 1
                )
                resized.unlockFocus()
            }
            image = resized
        } else {
            image = original
        }

        let cost = Int(image.size.width) * Int(image.size.height) * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
        return image
    }

    private var currentAppearance: NSAppearance {
        NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
    }

    private var isDarkAppearance: Bool {
        currentAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    public func clear() {
        cache.removeAllObjects()
    }

    private func installMemoryHandlers() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        let cache = cache
        source.setEventHandler {
            cache.removeAllObjects()
        }
        memoryPressureSource = source
        source.resume()

        activityObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cache.countLimit = 20 }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cache.countLimit = 50 }
            },
        ]
    }
}
