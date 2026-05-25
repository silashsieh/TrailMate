import Foundation

enum PythonBundle {
    private static let pyMajorMinor = "3.13"

    static var rootURL: URL {
        Bundle.main.resourceURL!.appendingPathComponent("PythonResources", isDirectory: true)
    }

    static var pythonHome: URL {
        rootURL.appendingPathComponent("python", isDirectory: true)
    }

    static var pythonLibs: URL {
        rootURL.appendingPathComponent("python-libs", isDirectory: true)
    }

    static var interpreter: URL {
        pythonHome.appendingPathComponent("bin/python\(pyMajorMinor)")
    }

    static func script(_ name: String) -> URL {
        rootURL.appendingPathComponent("\(name).py")
    }

    static var tunnelWrapperScript: URL {
        rootURL.appendingPathComponent("tm_tunnel.sh")
    }

    static var environment: [String: String] {
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
