import Foundation
import NIOCore

/// Delivers complete frames in receive order on the connection’s event loop.
final class StandardIOReceiver: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation

    private let server: ReplicoServer?
    private let transport: StandardIOTransport

    init(
        continuation: AsyncThrowingStream<Data, any Error>.Continuation,
        server: ReplicoServer?, transport: StandardIOTransport
    ) {
        self.server = server
        self.transport = transport
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = Data(unwrapInboundIn(data).readableBytesView)
        if let server, server.assumeIsolated({ $0.admitFromStandardIO(frame, transport: transport) }) {
            return
        }
        continuation.yield(frame)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case ChannelEvent.inputClosed:
            continuation.finish()
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        continuation.finish(throwing: error)
        context.close(mode: .input, promise: nil)
    }
}
