import Foundation
import StudyAICore

// estudia-mcp: servidor MCP por stdio para ChatGPT (app de Mac) o Claude Desktop.
// Lee la copia de la biblioteca que deja EstudIA; no escribe nada ni usa la red.
setvbuf(stdout, nil, _IOLBF, 0)
let server = MCPServer { LibraryExport.load() }
while let line = readLine() {
    if let out = server.handle(line) { print(out) }
}
