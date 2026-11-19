export function describeError(error, fallbackKind = "runtime") {
    try {
        const message = error instanceof Error || typeof error?.message === "string"
            ? error.message
            : String(error)
        return {
            message,
            kind: typeof error?.kind === "string" ? error.kind : fallbackKind,
        }
    } catch {
        return { message: "The thrown value could not be inspected", kind: fallbackKind }
    }
}

export class WorkerError extends Error {
    constructor(message, kind = "runtime") {
        super(message)
        this.name = "WorkerError"
        this.kind = kind
    }
}
