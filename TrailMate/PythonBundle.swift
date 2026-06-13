import Foundation

enum PythonBundle {
    nonisolated private static let pyMajorMinor = "3.13"

    nonisolated static var rootURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("PythonResources", isDirectory: true)
    }

    nonisolated static var pythonHome: URL {
        rootURL.appendingPathComponent("python", isDirectory: true)
    }

    nonisolated static var pythonLibs: URL {
        rootURL.appendingPathComponent("python-libs", isDirectory: true)
    }

    nonisolated static var interpreter: URL {
        pythonHome.appendingPathComponent("bin/python\(pyMajorMinor)")
    }

    nonisolated static func script(_ name: String) -> URL {
        rootURL.appendingPathComponent("\(name).py")
    }

    nonisolated static var tunnelWrapperScript: URL {
        rootURL.appendingPathComponent("tm_tunnel.sh")
    }

    nonisolated static var tunneldWrapperScript: URL {
        rootURL.appendingPathComponent("tm_tunneld.sh")
    }

    nonisolated static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONHOME"] = pythonHome.path
        env["PYTHONPATH"] = pythonLibs.path
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["TM_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        return env
    }
}
