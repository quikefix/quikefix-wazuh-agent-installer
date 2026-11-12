using Microsoft.EntityFrameworkCore;
using QFLM.Application.Licensing.Administration;
using QFLM.Application.Licensing.Security;
using QFLM.Domain.Installations;
using QFLM.Domain.Licenses;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Licensing.Administration;

public sealed class EfAdministrativeLicensingService(QflmDbContext db) : IAdministrativeLicensingService
{
    public async Task<AdministrativeMutationResult> SuspendLicenseAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Licenses.SingleOrDefaultAsync(v => v.Id == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "License not found.");
        if (x.Status == LicenseStatus.Revoked) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.InvalidState, "Revoked license is terminal.");
        x.Status = LicenseStatus.Suspended; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("License suspended.");
    }

    public async Task<AdministrativeMutationResult> ResumeLicenseAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Licenses.SingleOrDefaultAsync(v => v.Id == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "License not found.");
        if (x.Status == LicenseStatus.Revoked) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.InvalidState, "Revoked license is terminal.");
        x.Status = LicenseStatus.Active; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("License resumed.");
    }

    public async Task<AdministrativeMutationResult> RevokeLicenseAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Licenses.SingleOrDefaultAsync(v => v.Id == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "License not found.");
        x.Status = LicenseStatus.Revoked; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("License revoked.");
    }

    public async Task<AdministrativeMutationResult> SuspendInstallationAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Installations.SingleOrDefaultAsync(v => v.InstallationIdentifier == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "Installation not found.");
        if (x.Status == InstallationStatus.Revoked) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.InvalidState, "Revoked installation is terminal.");
        x.Status = InstallationStatus.Suspended; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("Installation suspended.");
    }

    public async Task<AdministrativeMutationResult> ResumeInstallationAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Installations.SingleOrDefaultAsync(v => v.InstallationIdentifier == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "Installation not found.");
        if (x.Status == InstallationStatus.Revoked) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.InvalidState, "Revoked installation is terminal.");
        x.Status = InstallationStatus.Active; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("Installation resumed.");
    }

    public async Task<AdministrativeMutationResult> RevokeInstallationAsync(Guid id, CancellationToken ct = default)
    {
        var x = await db.Installations.SingleOrDefaultAsync(v => v.InstallationIdentifier == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "Installation not found.");
        x.Status = InstallationStatus.Revoked; x.UpdatedAtUtc = DateTime.UtcNow; await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("Installation revoked.");
    }

    public async Task<AdministrativeMutationResult> RebindInstallationAsync(Guid id, string fingerprint, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(fingerprint))
            return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.MachineFingerprintRequired, "Machine fingerprint required.");

        var x = await db.Installations.SingleOrDefaultAsync(v => v.InstallationIdentifier == id, ct);
        if (x is null) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.NotFound, "Installation not found.");
        if (x.Status == InstallationStatus.Revoked) return AdministrativeMutationResult.Fail(AdministrativeMutationStatus.InvalidState, "Revoked installation is terminal.");

        x.MachineFingerprintHash = MachineFingerprintHasher.Hash(fingerprint);
        x.InstallationPublicKey = null;
        x.LastHeartbeatSequence = 0;
        x.HighestLeaseSequence = 0;
        x.LastSeenAtUtc = null;
        x.UpdatedAtUtc = DateTime.UtcNow;
        await db.SaveChangesAsync(ct);
        return AdministrativeMutationResult.Ok("Installation rebound.");
    }
}