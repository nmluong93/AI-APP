// Sends a play or pause command to the app that macOS lists as now playing,
// the way the keyboard's media keys, AirPods and Control Center do. Used by
// run_macos.sh. Usage: mediactl play|pause
import Foundation

let commands = ["play": 0, "pause": 1]  // kMRPlay, kMRPause
guard CommandLine.arguments.count == 2, let command = commands[CommandLine.arguments[1]] else {
  FileHandle.standardError.write("usage: mediactl play|pause\n".data(using: .utf8)!)
  exit(2)
}
let url = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
guard let bundle = CFBundleCreate(kCFAllocatorDefault, url as CFURL),
  let pointer = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
else {
  FileHandle.standardError.write("MediaRemote is not available\n".data(using: .utf8)!)
  exit(1)
}
typealias SendCommand = @convention(c) (Int, CFDictionary?) -> Bool
let sent = unsafeBitCast(pointer, to: SendCommand.self)(command, nil)
// The command is delivered asynchronously; give it a moment before exiting.
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
exit(sent ? 0 : 1)
