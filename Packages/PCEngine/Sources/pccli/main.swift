// Port of photocraft-cli (apps/photocraft-cli/src/main.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// The raw argument bytes go to `CLI.run(raw:)`, so an argument that is not UTF-8 is a usage error
// naming it instead of being silently repaired (photocraft `run_os`, #1108).

import Darwin
import Foundation
import PCAutomation

var raw: [[UInt8]] = []
for i in 1..<Int(CommandLine.argc) {
    guard let p = CommandLine.unsafeArgv[i] else { continue }
    raw.append(Array(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: strlen(p))))
}
// A peer that closes stdout (a pipe to `head`) must not kill the process.
signal(SIGPIPE, SIG_IGN)
let code = await CLI.run(raw: raw)
exit(code)
