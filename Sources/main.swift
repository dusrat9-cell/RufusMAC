import Foundation

// The same binary is both the GUI and the privileged engine: the GUI re-launches
// itself through `do shell script … with administrator privileges` so that disk
// writes happen as root while the UI stays unprivileged.

let arguments = CommandLine.arguments

func usage() {
    print("""
    Rufus para macOS

    uso:
      RufusMac                        abre la interfaz
      RufusMac --list                 lista los discos
      RufusMac --info <iso>           analiza una ISO
      RufusMac --selftest             verifica el splitter de WIM
      RufusMac --engine <job> <log>   ejecuta un trabajo (uso interno, como root)
    """)
}

if let index = arguments.firstIndex(of: "--engine") {
    exit(CLI.runEngine(Array(arguments[(index + 1)...])))
}
if arguments.contains("--selftest") {
    exit(CLI.selfTest())
}
if arguments.contains("--list") {
    CLI.listDisks()
    exit(0)
}
if let index = arguments.firstIndex(of: "--model-test"), index + 1 < arguments.count {
    exit(CLI.modelTest(iso: arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--info"), index + 1 < arguments.count {
    exit(CLI.info(arguments[index + 1]))
}
if arguments.contains("--help") || arguments.contains("-h") {
    usage()
    exit(0)
}

RufusMacApp.main()
