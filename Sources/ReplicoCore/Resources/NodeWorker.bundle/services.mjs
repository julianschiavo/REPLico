import { WorkerError } from "./errors.mjs"

export class ServiceBridge {
    #send
    #pending = new Map()

    constructor(send) {
        this.#send = send
    }

    invoke({ executionID, requestID, service, request }) {
        const pending = { executionID, ...Promise.withResolvers() }
        this.#pending.set(requestID, pending)
        this.#send({ event: "service", executionID, requestID, service, request }).catch(error => {
            this.#pending.delete(requestID)
            pending.reject(error)
        })
        return pending.promise
    }

    reply({ executionID, requestID, ok, value, error }) {
        const pending = this.#pending.get(requestID)
        if (pending === undefined || executionID !== undefined && executionID !== pending.executionID) {
            throw new WorkerError("Service reply has no active request", "stale_execution")
        }
        this.#pending.delete(requestID)
        if (ok === true) {
            pending.resolve(value)
        } else {
            const message = typeof error === "string" ? error : error?.message ?? "Service failed"
            pending.reject(new WorkerError(message, error?.kind ?? "service"))
        }
    }

}
