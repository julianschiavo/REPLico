struct Calculator: Sendable {
    func add(_ first: Double, _ second: Double) -> Double {
        first + second
    }

    func subtract(_ first: Double, _ second: Double) -> Double {
        first - second
    }

    func multiply(_ first: Double, _ second: Double) -> Double {
        first * second
    }

    func divide(_ first: Double, _ second: Double) throws -> Double {
        guard second != 0 else {
            throw MathError.divisionByZero
        }
        return first / second
    }
}
