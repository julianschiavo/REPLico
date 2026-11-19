# Runtime optimizations

The specialized Swift types are package scoped in `ReplicoOptimizations`. Their API comments show the corresponding Foundation or SwiftNIO call sites. The release comparison covers the full MCP round trip. [Measurements](Performance.md)

| Path | What saves work | What the caller observes |
| --- | --- | --- |
| MCP input | Validate an entire JSON frame once. Reuse decoded arguments only for an exact byte match on eligible JavaScript requests. | Each request has its own ID, authority and evaluation. Foundation decodes other layouts. |
| Worker input | Send startup configuration once. Repeated source can refer to one of eight byte-exact slots in the current worker. | Every cell runs with the current bindings and request metadata. |
| Evaluation | V8 handles bindings and top-level await. Large ordinary scripts can compile directly in the workspace and run through a private inspector context. | Retained closures report their original cell URL. Helper output stays associated with its evaluation. |
| Pipe I/O | The session and MCP dispatcher share an event loop. Bounded readers scan incoming bytes for line breaks. A small write can go straight to an available nonblocking pipe. | Frames stay ordered through backpressure, cancellation and shutdown. |
| Worker output | The worker joins buffered writes once. Similar large strings can use byte deltas. Negotiated image frames carry validated bytes directly. | Swift checks execution identity, limits, UTF-8 and image signatures before returning content. |
| MCP output | The writer copies plain UTF-8 runs in bulk. After the same large text storage appears twice, the connection can reuse its encoded body with a freshly encoded request ID. | The client receives the complete text or Base64 image on every call. Other SDK response shapes use Foundation. |

Source slots and text deltas belong to one worker generation. The response encoder retains at most one eligible text value of up to 2 MiB and an encoded buffer of up to 4 MiB. A different result or a closed connection clears that entry.
