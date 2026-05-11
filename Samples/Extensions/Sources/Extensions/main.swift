// SDR domain via custom `arcpx.sdr.*.v1` extension messages.
//
// Tune to 145.500 MHz (2 m FM calling), capture 5 s of IQ at
// 2.048 MS/s, NBFM-demodulate to 48 kHz PCM. Exercises §21 naming,
// capability advertisement, and unknown-message handling.

import ARCP
import Foundation

let extTune = "arcpx.sdr.tune.v1"
let extGain = "arcpx.sdr.gain.v1"
let extCapture = "arcpx.sdr.capture.v1"
let extDemodulate = "arcpx.sdr.demodulate.v1"
let allExtensions = [extTune, extGain, extCapture, extDemodulate]

func request(
    _ client: ARCPClient, type: String, payload: JSONValue, extensions: [String: JSONValue]? = nil
) async throws -> Envelope {
    let env = Envelope(
        sessionId: client.info.sessionId,
        extensions: extensions,
        payload: .unknown(typeName: type, payload: payload)
    )
    try await client.send(env)
    for await reply in client.unhandled where reply.correlationId == env.id {
        return reply
    }
    throw ARCPError.aborted(reason: "no reply for \(type)")
}

@main
struct ExtensionsExample {
    static func main() async throws {
        let client: ARCPClient = await .placeholder
        let advertised = Set(client.info.negotiatedCapabilities.extensions)
        // If the runtime didn't advertise our required extension set, refuse
        // the session — RFC §7 / §21.2.
        if !Set(allExtensions).isSubset(of: advertised) {
            throw ARCPError.unimplemented(
                section: "21.2", detail: "runtime missing SDR extensions: \(advertised)"
            )
        }

        let handle = String(UUID().uuidString.prefix(8))
        _ = try await request(
            client, type: extTune,
            payload: .object([
                "center_freq_hz": .number(145_500_000),
                "sample_rate_hz": .number(2_048_000),
                "ppm_correction": .number(1),
            ]))
        _ = try await request(
            client, type: extGain,
            payload: .object([
                "stages": .array([
                    .object([
                        "name": .string("TUNER"), "value_db": .number(28),
                    ])
                ])
            ]))

        // Capture returns an artifact.ref; the IQ buffer never travels inline.
        let cap = try await request(
            client, type: extCapture,
            payload: .object([
                "seconds": .number(5),
                "capture_handle": .string(handle),
                "decimate": .number(1),
            ]))
        let iqArtifact: String
        if case .unknown(_, let p) = cap.payload, case .object(let o) = p,
            case .string(let id) = o["artifact_id"] ?? .null
        {
            iqArtifact = id
        } else {
            iqArtifact = ""
        }
        print("captured IQ → \(iqArtifact)")

        let audio = try await request(
            client, type: extDemodulate,
            payload: .object([
                "iq_artifact_id": .string(iqArtifact),
                "mode": .string("NBFM"),
                "audio_rate_hz": .number(48_000),
            ]))
        print("demod  PCM → \(audio.payload.typeName)")

        // §21.3 demonstration: unadvertised extension marked optional.
        // Runtime SHOULD ack (silent drop) rather than nack.
        let optional = try await request(
            client, type: "arcpx.sdr.experimental_doppler.v1",
            payload: .object(["velocity_mps": .number(7.4)]),
            extensions: ["optional": .bool(true)]
        )
        print("optional unknown → \(optional.payload.typeName)")

        await client.close()
    }
}
