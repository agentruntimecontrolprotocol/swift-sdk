import Foundation

public enum CredentialScheme: String, Sendable, Codable, Hashable {
    case bearer
}

public struct CredentialConstraints: Sendable, Codable, Hashable {
    public var costBudget: CostBudget?
    public var modelUse: ModelUse?
    public var expiresAt: Date?

    public init(costBudget: CostBudget? = nil, modelUse: ModelUse? = nil, expiresAt: Date? = nil) {
        self.costBudget = costBudget
        self.modelUse = modelUse
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case costBudget = "cost.budget"
        case modelUse = "model.use"
        case expiresAt = "expires_at"
    }
}

public struct ProvisionedCredential: Sendable, Codable, Hashable, CustomStringConvertible {
    public var id: String
    public var scheme: CredentialScheme
    public var value: String
    public var endpoint: String
    public var profile: String?
    public var constraints: CredentialConstraints?

    public init(
        id: String,
        scheme: CredentialScheme,
        value: String,
        endpoint: String,
        profile: String? = nil,
        constraints: CredentialConstraints? = nil
    ) throws {
        guard !value.isEmpty else {
            throw ARCPError.invalidArgument(field: "value", detail: "credential value must not be empty")
        }
        self.id = id
        self.scheme = scheme
        self.value = value
        self.endpoint = endpoint
        self.profile = profile
        self.constraints = constraints
    }

    public var description: String {
        "ProvisionedCredential(id: \(id), scheme: \(scheme.rawValue), value: <redacted>, endpoint: \(endpoint))"
    }

    enum CodingKeys: String, CodingKey {
        case id, scheme, value, endpoint, profile, constraints
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.scheme = try container.decode(CredentialScheme.self, forKey: .scheme)
        self.value = try container.decode(String.self, forKey: .value)
        self.endpoint = try container.decode(String.self, forKey: .endpoint)
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile)
        self.constraints = try container.decodeIfPresent(CredentialConstraints.self, forKey: .constraints)
        if value.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: .value,
                in: container,
                debugDescription: "credential value must not be empty"
            )
        }
    }
}
