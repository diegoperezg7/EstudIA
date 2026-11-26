import AppKit
import CoreGraphics

/// Permiso de «Grabación de pantalla y audio del sistema». Nunca se pide el micrófono.
enum ScreenAudioPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Muestra el diálogo del sistema la primera vez. macOS solo aplica el permiso tras reiniciar la app.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
