namespace QFLM.Application.Licensing.Administration;

public enum AdministrativeMutationStatus { Success, NotFound, InvalidState, MachineFingerprintRequired }

public sealed record AdministrativeMutationResult
{
    public AdministrativeMutationStatus Status { get; init; }
    public string Message { get; init; } = string.Empty;
    public static AdministrativeMutationResult Ok(string message) => new() { Status = AdministrativeMutationStatus.Success, Message = message };
    public static AdministrativeMutationResult Fail(AdministrativeMutationStatus status, string message) => new() { Status = status, Message = message };
}

public interface IAdministrativeLicensingService
{
    Task<AdministrativeMutationResult> SuspendLicenseAsync(Guid licenseId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> ResumeLicenseAsync(Guid licenseId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> RevokeLicenseAsync(Guid licenseId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> SuspendInstallationAsync(Guid installationId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> ResumeInstallationAsync(Guid installationId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> RevokeInstallationAsync(Guid installationId, CancellationToken ct = default);
    Task<AdministrativeMutationResult> RebindInstallationAsync(Guid installationId, string newMachineFingerprint, CancellationToken ct = default);
}