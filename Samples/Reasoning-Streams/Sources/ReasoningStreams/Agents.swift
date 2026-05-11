// LLM stubs for primary + mirror, plus a small timeout helper.

import ARCP
import Foundation

func primaryStep(_ request: String, prior: JSONValue?) async -> String {
    fatalError("elided: primary LLM call returns the next thought")
}

func critiqueThought(_ content: String) async -> (String, String, String, Int) {
    fatalError("elided: critic LLM returns severity/summary/suggestion/tokens")
}

func withTimeout<T: Sendable>(seconds: Int, _ op: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await op() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result
    }
}

extension ARCPClient {
    static var placeholder: ARCPClient {
        get async { fatalError("elided: transport, identity, auth setup") }
    }
}
