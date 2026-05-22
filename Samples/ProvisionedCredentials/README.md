# Provisioned Credentials

Demonstrates lease-bound credential provisioning. The runtime uses an
`InMemoryCredentialProvisioner` test plug-in, attaches a bearer
credential to `job.accepted`, and revokes it when the job completes.
The sample prints only the credential id; credential values are treated
as secrets.

```sh
swift run ProvisionedCredentials
```
