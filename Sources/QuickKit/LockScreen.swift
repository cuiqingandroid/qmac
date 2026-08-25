import AppKit
import Carbon.HIToolbox

struct LockFailure: Error {
    let message: String
}

enum LockScreen {
    private static let cgSessionPath =
        "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"

    @discardableResult
    static func lock(using method: Settings.LockMethod) -> Result<String, LockFailure> {
        let order: [Settings.LockMethod]
        switch method {
        case .auto: order = [.cgsession, .keystroke, .sleep]
        default: order = [method]
        }

        var errors: [String] = []
        for candidate in order {
            switch attempt(candidate) {
            case .success: return .success(candidate.title)
            case .failure(let failure): errors.append("\(candidate.title)：\(failure.message)")
            }
        }
        return .failure(LockFailure(message: errors.joined(separator: "；")))
    }

    private static func attempt(_ method: Settings.LockMethod) -> Result<Void, LockFailure> {
        switch method {
        case .auto:
            return .failure(LockFailure(message: "内部错误"))
        case .cgsession:
            return run(cgSessionPath, ["-suspend"])
        case .sleep:
            return run("/usr/bin/pmset", ["displaysleepnow"])
        case .keystroke:
            guard Paster.hasAccessibilityPermission else { return .failure(LockFailure(message: "缺少辅助功能权限")) }
            postControlCommandQ()
            return .success(())
        }
    }

    private static func run(_ path: String, _ arguments: [String]) -> Result<Void, LockFailure> {
        guard FileManager.default.isExecutableFile(atPath: path) else { return .failure(LockFailure(message: "找不到 \(path)")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return .failure(LockFailure(message: message.isEmpty ? "退出码 \(process.terminationStatus)" : message))
            }
            return .success(())
        } catch {
            return .failure(LockFailure(message: error.localizedDescription))
        }
    }

    /// 模拟系统自带的 ⌃⌘Q
    private static func postControlCommandQ() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let flags: CGEventFlags = [.maskCommand, .maskControl]
        let keyCode = CGKeyCode(kVK_ANSI_Q)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
