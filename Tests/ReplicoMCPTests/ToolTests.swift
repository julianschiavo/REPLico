@testable import ReplicoMCP
import ReplicoCore
import Foundation
import MCP
import Testing

struct ToolTests {
    @Test
    func argumentsRetainFoundationJSONDecodingStrategies() async throws {
        await #expect(throws: MCPError.self) {
            try await invoke(
                URLArgumentsTool(),
                request:
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"url","arguments":{"relative":"https://example.invalid/resource"}}}"#
            )
        }
    }

    @Test
    func emptySuccessfulEvaluationProducesAnEmptyMCPTextItem() {
        let result = EvaluationResult().makeMCPResult()
        #expect(result.isError == false)
        #expect(result.content == [.text(text: "", annotations: nil, _meta: nil)])
    }

    @Test
    func emptyJavaScriptReturnsAResultFailureWithoutStartingNode() async throws {
        let session = try makeSession()
        let tool = JavaScriptTool(session: session)
        for code in ["", " \n\t ", "\u{0085}"] {
            let result = try await tool.call(arguments: .init(code: code), context: ToolCallContext())
            #expect(result.isError == true)
            #expect(
                result.content == [
                    .text(
                        text: "js expects non-empty JavaScript source", annotations: nil, _meta: nil
                    )
                ])
        }
        await session.shutDown()
    }

    @Test
    func anExistentialToolDecodesItsConcreteArgumentsAndReceivesContext() async throws {
        let tool: any ReplicoMCP.Tool = MultiplyTool()
        let result = try await invoke(
            tool,
            request:
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"multiply","arguments":{"value":6,"factor":7}}}"#,
            context: ToolCallContext(
                metadata: ["label": .string("typed")],
                launchPolicy: .unavailable(.invalidConfiguration("Required policy."))
            )
        )
        #expect(result.content == [.text(text: "42:typed:true", annotations: nil, _meta: nil)])
        #expect(result.structuredContent == .object(["value": .int(42)]))
    }

    @Test
    func wireArgumentsDecodeTimeoutAndDefaults() throws {
        let supplied = try JSONDecoder()
            .decode(
                JavaScriptTool.Arguments.self,
                from: Data(
                    #"{"code":"1","title":"Evaluate","timeout_ms":123}"#.utf8
                ))
        #expect(supplied.code == "1")
        #expect(supplied.title == "Evaluate")
        #expect(supplied.timeoutMilliseconds == 123)
        let decoded = try JSONDecoder().decode(JavaScriptTool.Arguments.self, from: Data(#"{"code":"1"}"#.utf8))
        #expect(decoded.timeoutMilliseconds == nil)
        #expect(decoded.title == nil)
    }

    @Test
    func invalidArgumentsFailBeforeStartingTheSession() async throws {
        let session = try makeSession()
        let tool = JavaScriptTool(session: session)
        await #expect(throws: MCPError.self) {
            try await invoke(
                tool,
                request:
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"js","arguments":{"code":"1","timeout_ms":0}}}"#
            )
        }
        await #expect(throws: MCPError.self) {
            try await invoke(
                tool,
                request:
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"js","arguments":{"code":"1","title":null}}}"#
            )
        }
        await #expect(throws: MCPError.self) {
            try await invoke(
                tool,
                request:
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"js","arguments":{"code":"1","timeout_ms":1.5}}}"#
            )
        }
        await #expect(throws: MCPError.self) {
            try await invoke(
                tool,
                request:
                    #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"js","arguments":{"code":"1","unexpected":true}}}"#
            )
        }
        await session.shutDown()
    }

    @Test
    func resetAndModuleDirectoryToolsOwnTheirActionsWithoutStartingNode() async throws {
        let session = try makeSession()
        do {
            let reset = try await ResetTool(session: session)
                .call(
                    arguments: ResetTool.Arguments(),
                    context: ToolCallContext()
                )
            #expect(reset.content == [.text(text: "JavaScript kernel reset.", annotations: nil, _meta: nil)])
            let added = try await AddNodeModuleDirectoryTool(session: session)
                .call(
                    arguments: AddNodeModuleDirectoryTool.Arguments(path: "/tmp/example/node_modules"),
                    context: ToolCallContext()
                )
            #expect(added.content == [.text(text: "Node module directory added.", annotations: nil, _meta: nil)])
            await #expect(throws: REPLError.self) {
                try await AddNodeModuleDirectoryTool(session: session)
                    .call(
                        arguments: AddNodeModuleDirectoryTool.Arguments(path: "relative/node_modules"),
                        context: ToolCallContext()
                    )
            }
            await session.shutDown()
        } catch {
            await session.shutDown()
            throw error
        }
    }

    @Test
    func registryRejectsDuplicateNames() async throws {
        let session = try makeSession()
        #expect(throws: ToolRegistrationError.duplicateName("multiply")) {
            try ReplicoServer(session: session, tools: [MultiplyTool(), MultiplyTool()])
        }
        await session.shutDown()
    }

    private func makeSession() throws -> REPLSession {
        try REPLSession(
            configuration: REPLConfiguration(
                nodeExecutable: URL(filePath: "/usr/bin/false"),
                environment: [:]
            ))
    }

    private func invoke<T: ReplicoMCP.Tool>(
        _ tool: T,
        request: String,
        context: ToolCallContext = ToolCallContext()
    ) async throws -> CallTool.Result {
        let data = Data(request.utf8)
        let request = try JSONDecoder().decode(MCPToolCall.self, from: data, configuration: [RegisteredTool(tool)])
        return try await request.invocation.invoke(context: context)
    }
}
