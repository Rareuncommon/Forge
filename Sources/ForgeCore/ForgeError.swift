import Foundation

/// A command the user or an agent can execute to fix a problem. Suggested fixes are
/// real, executable commands — not prose (SPEC §5.4).
public struct SuggestedFix: Codable, Sendable, Hashable {
    public var description: String
    public var command: String
    public var params: JSONValue

    public init(description: String, command: String, params: JSONValue = .object([:])) {
        self.description = description
        self.command = command
        self.params = params
    }
}

/// Stable machine-readable error codes. Never renumber or rename: agents key on these.
public enum ErrorCode: String, Codable, Sendable, CaseIterable {
    case invalidParams = "invalid_params"
    case unknownCommand = "unknown_command"
    case unknownEntity = "unknown_entity"
    case invalidUnit = "invalid_unit"
    case preconditionFailed = "precondition_failed"
    case kernelFailure = "kernel_failure"
    case booleanFailed = "boolean_failed"
    case emptyResult = "empty_result"
    case ioError = "io_error"
    case nothingToUndo = "nothing_to_undo"
    case nothingToRedo = "nothing_to_redo"
    case transactionActive = "transaction_active"
    case noTransaction = "no_transaction"
    case unsupported = "unsupported"
    case notImplemented = "not_implemented"
    case internalError = "internal_error"
}

/// The single structured error type used across Forge (SPEC §5.4).
public struct ForgeError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
    public var code: ErrorCode
    public var message: String
    /// Offending entity identifiers (bodies, faces, features...).
    public var entities: [String]
    public var suggestions: [SuggestedFix]
    /// Extra structured context (e.g. which parameter failed validation).
    public var details: JSONValue?

    public init(
        _ code: ErrorCode, _ message: String, entities: [String] = [], suggestions: [SuggestedFix] = [],
        details: JSONValue? = nil
    ) {
        self.code = code
        self.message = message
        self.entities = entities
        self.suggestions = suggestions
        self.details = details
    }

    public var description: String {
        var s = "[\(code.rawValue)] \(message)"
        if !entities.isEmpty { s += " (entities: \(entities.joined(separator: ", ")))" }
        return s
    }

    /// Wrap any error as a ForgeError, preserving ForgeErrors unchanged.
    public static func wrap(_ error: any Error) -> ForgeError {
        if let f = error as? ForgeError { return f }
        if let d = error as? DecodingError { return ForgeError(.invalidParams, describe(d)) }
        return ForgeError(.internalError, String(describing: error))
    }

    private static func describe(_ e: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            let p = ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "params" : p
        }
        switch e {
        case .keyNotFound(let key, let ctx):
            let parent = path(ctx)
            return "missing required parameter '\(parent == "params" ? key.stringValue : parent + "." + key.stringValue)'"
        case .typeMismatch(let type, let ctx):
            return "parameter '\(path(ctx))' has the wrong type (expected \(type)): \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "parameter '\(path(ctx))' is null (expected \(type))"
        case .dataCorrupted(let ctx):
            return "parameter '\(path(ctx))' is invalid: \(ctx.debugDescription)"
        @unknown default:
            return String(describing: e)
        }
    }
}
