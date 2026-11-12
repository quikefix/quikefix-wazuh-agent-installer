namespace QFLM.Application.Licensing.Models;

public enum EffectiveLicenseState { Active, Grace, Restricted, Expired, Suspended, Revoked }
public enum LicenseResultCode { Success, InvalidRequest, InvalidLicense, ProductMismatch, LicenseInactive, LicenseSuspended, LicenseRevoked, LicenseExpired, SubscriptionInactive, InstallationLimitReached, InstallationNotFound, InstallationDisabled, MachineMismatch, SequenceRejected }

public sealed record EntitlementDto { public required string FeatureCode { get; init; } public bool Enabled { get; init; } public int? LimitValue { get; init; } }
public sealed record ActivationRequest { public required string LicenseKey { get; init; } public required string ProductCode { get; init; } public required string InstallationId { get; init; } public required string MachineFingerprint { get; init; } }
public sealed record ValidationRequest { public required string LicenseKey { get; init; } public required string ProductCode { get; init; } public required string InstallationId { get; init; } public required string MachineFingerprint { get; init; } }
public sealed record HeartbeatRequest { public required string LicenseKey { get; init; } public required string ProductCode { get; init; } public required string InstallationId { get; init; } public required string MachineFingerprint { get; init; } public long Sequence { get; init; } }
public sealed record DeactivationRequest { public required string LicenseKey { get; init; } public required string ProductCode { get; init; } public required string InstallationId { get; init; } public required string MachineFingerprint { get; init; } }

public sealed record ActivationResult { public required string LicenseId { get; init; } public required string InstallationId { get; init; } public required string ProductCode { get; init; } public EffectiveLicenseState EffectiveState { get; init; } public DateTime? ValidUntilUtc { get; init; } public DateTime? GraceEndsAtUtc { get; init; } public IReadOnlyCollection<EntitlementDto> Entitlements { get; init; } = []; }
public sealed record ValidationResult { public required string LicenseId { get; init; } public required string InstallationId { get; init; } public required string ProductCode { get; init; } public EffectiveLicenseState EffectiveState { get; init; } public bool AllowWriteOperations { get; init; } public DateTime? ValidUntilUtc { get; init; } public DateTime? GraceEndsAtUtc { get; init; } public IReadOnlyCollection<EntitlementDto> Entitlements { get; init; } = []; }
public sealed record HeartbeatResult { public required string InstallationId { get; init; } public long Sequence { get; init; } public DateTime ServerTimeUtc { get; init; } }
public sealed record DeactivationResult { public required string InstallationId { get; init; } public required string ProductCode { get; init; } public bool Deactivated { get; init; } }

public sealed record LicensingResponse<T> {
    public bool Success { get; init; }
    public LicenseResultCode Code { get; init; }
    public required string Message { get; init; }
    public T? Data { get; init; }
    public static LicensingResponse<T> Ok(T data, string message = "Success.") => new() { Success = true, Code = LicenseResultCode.Success, Message = message, Data = data };
    public static LicensingResponse<T> Fail(LicenseResultCode code, string message) => new() { Success = false, Code = code, Message = message };
}