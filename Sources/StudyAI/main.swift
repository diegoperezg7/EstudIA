import Foundation

// Modos de autoprueba por línea de comandos (ver README). Sin argumentos arranca la app.
let args = CommandLine.arguments
if let i = args.firstIndex(where: { $0.hasPrefix("--selftest-") }) {
    let code = await SelfTest.run(mode: args[i], args: Array(args.dropFirst(i + 1)))
    exit(code)
}
StudyAIApp.main()
