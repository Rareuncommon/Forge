// Forge for Windows (docs/adr/0012-windows-app.md): the native Win32 / Direct3D shell
// (CForgeWin) around the shared app model (ForgeUI) and engine.

import Foundation

MainActor.assumeIsolated {
    let shell = WinShell()
    guard shell.start() else {
        FileHandle.standardError.write(Data("Forge could not create its window (Direct3D 11 is required).\n".utf8))
        exit(1)
    }
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count { shell.selfTest(screenshot: args[i + 1]) }
    shell.run()
}
