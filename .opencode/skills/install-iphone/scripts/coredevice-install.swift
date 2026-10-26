// Private CoreDevice ABI fallback. See ../SKILL.md before using after an SDK update.
import Foundation
import Darwin

@_silgen_name("$s10CoreDevice0B7ManagerC6sharedACvgZ")
func sharedManager() -> AnyObject

final class Manager {
    @_silgen_name("$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF")
    func allDevices() -> [AnyObject]
    @_silgen_name("$s10CoreDevice0B7ManagerC11deviceNamedyAA06RemoteB0CSSKF")
    func deviceNamed(_ name: String) throws -> AnyObject
}

final class Device {
    @_silgen_name("$s10CoreDevice06RemoteB0C7connect11targetQueue17completionHandlerySo17OS_dispatch_queueCSg_ys6ResultOyyts5Error_pGctFTj")
    func connect(targetQueue: DispatchQueue?, completionHandler: @escaping (Result<Void, Error>) -> Void)
    @_silgen_name("$s10CoreDevice06RemoteB0C18installApplication8stagedAt12completingOn10completionSo10NSProgressC10Foundation3URLV_So17OS_dispatch_queueCSgys6ResultOyAA015AppInstallationQ0Vs5Error_pGctFTj")
    func install<T>(stagedAt: URL, completingOn: DispatchQueue?, completion: @escaping (Result<T, Error>) -> Void) -> Progress
}

@_silgen_name("swift_getTypeByMangledNameInContext")
func resolveType(_ name: UnsafeRawPointer, _ length: UInt, _ context: UnsafeRawPointer?, _ arguments: UnsafeRawPointer?) -> Any.Type?

func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}

// Discover offsets in the installed binary rather than depending on a particular build.
let framework = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
let sharedSymbol = "$s10CoreDevice0B7ManagerC6sharedACvgZ"
let process = Process()
let pipe = Pipe()
process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
process.arguments = [framework]
process.standardOutput = pipe
try process.run()
let symbols = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
process.waitUntilExit()
guard process.terminationStatus == 0 else { fail("Cannot inspect CoreDevice symbols") }

func offset(for symbol: String) -> Int {
    let matches = symbols.split(separator: "\n").filter { $0.hasSuffix(" " + symbol) }
    guard matches.count == 1,
          let address = matches[0].split(separator: " ").first,
          let offset = Int(address, radix: 16) else {
        fail("Expected one CoreDevice symbol: \(symbol). Reinspect the framework ABI.")
    }
    return offset
}

guard let handle = dlopen(framework, RTLD_NOW),
      let sharedAddress = dlsym(handle, sharedSymbol) else {
    fail("Cannot load CoreDevice shared manager")
}
let base = sharedAddress.advanced(by: -offset(for: "_" + sharedSymbol))
let reference = base.advanced(by: offset(for: "_symbolic _____ 10CoreDevice21AppInstallationResultV"))
guard [UInt8(1), UInt8(2)].contains(reference.load(as: UInt8.self)),
      let resultType = resolveType(reference, 5, nil, nil) else {
    fail("Cannot resolve installation-result metadata. Reinspect the framework ABI.")
}

if CommandLine.arguments.dropFirst().first == "--check" {
    print("CoreDevice symbols and installation-result metadata validated")
    exit(0)
}
guard CommandLine.arguments.count == 2,
      FileManager.default.fileExists(atPath: CommandLine.arguments[1] + "/Info.plist") else {
    fail("Usage: coredevice-install /absolute/path/to/fresh/OpenClient.app")
}
guard let target = ProcessInfo.processInfo.environment["OPENCLIENT_IPHONE_UDID"], !target.isEmpty else {
    fail("Set OPENCLIENT_IPHONE_UDID before installing")
}

let managerObject = sharedManager()
let manager = unsafeBitCast(managerObject, to: Manager.self)
let deadline = Date().addingTimeInterval(25)
while manager.allDevices().isEmpty && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
let deviceObject: AnyObject
do {
    deviceObject = try manager.deviceNamed(target)
} catch {
    fail("Cannot select configured iPhone: \(error.localizedDescription)")
}
let device = unsafeBitCast(deviceObject, to: Device.self)
print("Selected configured iPhone")
var installationProgress: Progress?

func install<T>(_: T.Type) {
    let app = URL(fileURLWithPath: CommandLine.arguments[1])
    installationProgress = device.install(stagedAt: app, completingOn: .main) { (result: Result<T, Error>) in
        switch result {
        case .success:
            print("INSTALL SUCCEEDED")
            exit(0)
        case .failure(let error):
            fail("INSTALL FAILED: \(error.localizedDescription)")
        }
    }
}

device.connect(targetQueue: .main) { result in
    switch result {
    case .success:
        print("CoreDevice connected")
        _openExistential(resultType, do: install)
    case .failure(let error):
        fail("CONNECT FAILED: \(error.localizedDescription)")
    }
}
dispatchMain()
