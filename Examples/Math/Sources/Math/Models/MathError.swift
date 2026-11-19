import Foundation

enum MathError: Error, LocalizedError {
    case divisionByZero

    var errorDescription: String? {
        switch self {
        case .divisionByZero:
            return "Cannot divide by zero."
        }
    }
}
