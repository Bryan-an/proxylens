import Darwin
import Foundation
import ProxyLensPlatform
import SwiftUI

let arguments = CommandLine.arguments
if arguments.count == 4, arguments[1] == ScriptWorkerCommand.argument {
    let inputURL = URL(fileURLWithPath: arguments[2], isDirectory: false)
    let outputURL = URL(fileURLWithPath: arguments[3], isDirectory: false)
    exit(ScriptWorkerCommand.run(inputURL: inputURL, outputURL: outputURL))
}

ProxyLensApp.main()
