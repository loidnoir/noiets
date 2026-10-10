import AppKit
import Darwin

/// Ghostty's WindowServer blur path. Undocumented/private API: dynamically
/// resolved so missing symbols or rejected calls can fall back to AppKit.
@MainActor
public final class WindowBackgroundBlur {
    private typealias Connection = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias SetRadius = @convention(c) (UnsafeMutableRawPointer, UInt, Int32) -> Int32
    private struct API {
        let connection: Connection
        let setRadius: SetRadius
    }

    private static let api: API? = {
        func resolve(in handle: UnsafeMutableRawPointer?) -> API? {
            guard let connection = dlsym(handle, "CGSDefaultConnectionForThread"),
                  let radius = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
            return API(connection: unsafeBitCast(connection, to: Connection.self),
                       setRadius: unsafeBitCast(radius, to: SetRadius.self))
        }
        if let api = resolve(in: UnsafeMutableRawPointer(bitPattern: -2)) { return api } // RTLD_DEFAULT
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        if let api = resolve(in: library) {
            // Keep the image loaded for the lifetime of these function pointers.
            return api
        }
        dlclose(library)
        return nil
    }()

    private let setRadius: (Int, Int) -> Bool
    private var applied: [Int: Int] = [:]

    public init() {
        setRadius = { number, radius in
            guard let api = Self.api, let connection = api.connection() else { return false }
            return api.setRadius(connection, UInt(number), Int32(radius)) == 0
        }
    }

    /// Injection seam: test lifecycle/error handling without invoking private API.
    init(setRadius: @escaping (Int, Int) -> Bool) { self.setRadius = setRadius }

    @discardableResult
    public func apply(radius: Int, to window: NSWindow) -> Bool {
        let radius = min(max(radius, 0), EditorBackdropSettings.maximumBlurRadius)
        let number = window.windowNumber
        guard number > 0 else { return false }
        if radius == 0, applied[number] == nil { return true }
        if applied[number] == radius { return true }
        guard setRadius(number, radius) else { return false }
        if radius == 0 { applied.removeValue(forKey: number) }
        else { applied[number] = radius }
        return true
    }

    @discardableResult
    public func clear(from window: NSWindow) -> Bool { apply(radius: 0, to: window) }
}
