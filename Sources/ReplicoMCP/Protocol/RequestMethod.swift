enum RequestMethod: String {
    case initialize
    case ping
    case listTools = "tools/list"
    case callTool = "tools/call"
}
