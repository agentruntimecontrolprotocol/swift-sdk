import Foundation

/// `permission.request` payload. RFC §15.4.
public struct PermissionRequestPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var operation: String
    public var reason: String?
    public var requestedLeaseSeconds: Int

    public init(
        permission: String,
        resource: String,
        operation: String,
        reason: String? = nil,
        requestedLeaseSeconds: Int = 60
    ) {
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.reason = reason
        self.requestedLeaseSeconds = requestedLeaseSeconds
    }

    enum CodingKeys: String, CodingKey {
        case permission, resource, operation, reason
        case requestedLeaseSeconds = "requested_lease_seconds"
    }
}

/// `permission.grant` payload. RFC §15.4.
public struct PermissionGrantPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var operation: String
    public var leaseSeconds: Int

    public init(permission: String, resource: String, operation: String, leaseSeconds: Int) {
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.leaseSeconds = leaseSeconds
    }

    enum CodingKeys: String, CodingKey {
        case permission, resource, operation
        case leaseSeconds = "lease_seconds"
    }
}

/// `permission.deny` payload. RFC §15.4.
public struct PermissionDenyPayload: Sendable, Codable, Hashable {
    public var permission: String
    public var resource: String
    public var reason: String

    public init(permission: String, resource: String, reason: String) {
        self.permission = permission
        self.resource = resource
        self.reason = reason
    }
}

/// `lease.granted` payload. RFC §15.5.
public struct LeaseGrantedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var permission: String
    public var resource: String
    public var operation: String
    public var expiresAt: Date

    public init(
        leaseId: LeaseId,
        permission: String,
        resource: String,
        operation: String,
        expiresAt: Date
    ) {
        self.leaseId = leaseId
        self.permission = permission
        self.resource = resource
        self.operation = operation
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case permission, resource, operation
        case expiresAt = "expires_at"
    }
}

/// `lease.extended` payload. RFC §15.5.
public struct LeaseExtendedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var expiresAt: Date

    public init(leaseId: LeaseId, expiresAt: Date) {
        self.leaseId = leaseId
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case expiresAt = "expires_at"
    }
}

/// `lease.revoked` payload. RFC §15.5.
public struct LeaseRevokedPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var reason: String

    public init(leaseId: LeaseId, reason: String) {
        self.leaseId = leaseId
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case reason
    }
}

/// `lease.refresh` payload. RFC §15.5.
public struct LeaseRefreshPayload: Sendable, Codable, Hashable {
    public var leaseId: LeaseId
    public var requestedSeconds: Int

    public init(leaseId: LeaseId, requestedSeconds: Int) {
        self.leaseId = leaseId
        self.requestedSeconds = requestedSeconds
    }

    enum CodingKeys: String, CodingKey {
        case leaseId = "lease_id"
        case requestedSeconds = "requested_seconds"
    }
}
