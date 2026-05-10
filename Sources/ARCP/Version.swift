/// Static protocol identity for ARCP — see RFC §6.1 (envelope `arcp` field).
public enum ARCPVersion {
    /// Wire-protocol version emitted in every envelope.
    public static let wire = "1.0"

    /// Human-readable SDK release version. Bump in lockstep with the package tag.
    public static let sdk = "0.1.0-dev"
}
