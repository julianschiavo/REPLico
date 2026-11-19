import ArgumentParser

enum Operation: String, ExpressibleByArgument, Sendable {
    case add
    case sub
    case mult
    case div
}
