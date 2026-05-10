import Foundation

/// Client-side human-input handler. RFC §12.
///
/// The client is configured with a handler implementation that knows how to
/// surface a request to a real human (or, in tests, an automated responder).
public protocol HumanInputHandler: Sendable {
    /// Resolve a `human.input.request`. Throw `ARCPError.cancelled` to send
    /// `human.input.cancelled` back to the runtime.
    func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload

    /// Resolve a `human.choice.request`.
    func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
}

/// Default no-op handler that always responds with `default` for input
/// requests and the first option for choice requests. Used when the
/// application doesn't register a real handler.
public struct DefaultHumanInputHandler: HumanInputHandler {
    public init() {}

    public func handle(
        _ request: HumanInputRequestPayload, jobId: JobId?
    ) async throws
        -> HumanInputResponsePayload
    {
        guard let value = request.default else {
            throw ARCPError.unimplemented(
                section: "§12.1",
                detail: "DefaultHumanInputHandler requires a `default` value"
            )
        }
        return HumanInputResponsePayload(value: value, respondedBy: "default")
    }

    public func handle(
        _ request: HumanChoiceRequestPayload, jobId: JobId?
    ) async throws
        -> HumanChoiceResponsePayload
    {
        guard let first = request.options.first else {
            throw ARCPError.invalidArgument(field: "options", detail: "no options provided")
        }
        return HumanChoiceResponsePayload(choiceId: first.id, respondedBy: "default")
    }
}
