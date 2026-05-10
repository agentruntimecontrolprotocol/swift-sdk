import ARCP

@main
struct Sample02ToolInvokeProgress {
    static func main() async {
        print("Sample 02 — tool.invoke with progress (wire \(ARCPVersion.wire))")
        print("Implementation lands in Phase 3.")
    }
}
