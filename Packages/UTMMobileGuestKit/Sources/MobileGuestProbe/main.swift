import Foundation
import CMobileGuest
import UTMMobileGuestKit

if CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--host" {
    let report = VPhoneHostReport.inspect()
    print("Virtualization.framework: \(report.hasVirtualizationFramework)")
    print("Research descriptor: \(report.hasResearchDescriptor)")
    print(report.reason)
    exit(0)
}
guard CommandLine.arguments.count >= 2 else {
    fputs("usage: utm-mobile-guest-probe ENGINE [--require-interpreter] | --host\n", stderr)
    exit(64)
}
if let error = utm_ltm_load(CommandLine.arguments[1], CommandLine.arguments.contains("--require-interpreter")) {
    fputs(String(cString: error) + "\n", stderr)
    exit(1)
}
var boards: [String] = []
var i: Int32 = 0
while let info = utm_ltm_machine(i) {
    boards.append(String(cString: info.pointee.board))
    i += 1
}
print(boards.joined(separator: "\n"))
