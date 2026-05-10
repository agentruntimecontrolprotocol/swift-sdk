import ARCP

@main
struct Sample01MinimalSession {
    static func main() async {
        print("Sample 01 — minimal session (wire \(ARCPVersion.wire), sdk \(ARCPVersion.sdk))")
        print("Implementation lands in Phase 2.")
    }
}
