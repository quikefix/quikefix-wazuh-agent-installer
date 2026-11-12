using Microsoft.EntityFrameworkCore;
using QFLM.Application.Licensing.Models;
using QFLM.Application.Licensing.Security;
using QFLM.Application.Licensing.Services;
using QFLM.Domain.Installations;
using QFLM.Domain.Licenses;
using QFLM.Infrastructure.Persistence;

namespace QFLM.Infrastructure.Licensing;

public sealed class EfLicensingService(QflmDbContext db) : ILicensingService
{
    public async Task<LicensingResponse<ActivationResult>> ActivateAsync(ActivationRequest r, CancellationToken ct = default)
    {
        if (!Guid.TryParse(r.InstallationId, out var iid))
            return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.InvalidRequest,"Installation ID is invalid.");

        var l = await FindLicense(r.LicenseKey,r.ProductCode,ct);
        if (l is null) return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.InvalidLicense,"License was not found for this product.");
        var f = Check(l); if (f is not null) return LicensingResponse<ActivationResult>.Fail(f.Value.code,f.Value.message);

        var fp = MachineFingerprintHasher.Hash(r.MachineFingerprint);
        var i = await db.Installations.SingleOrDefaultAsync(x=>x.InstallationIdentifier==iid,ct);

        if (i is null)
        {
            var active = await db.Installations.CountAsync(x=>x.LicenseId==l.Id && x.Status==InstallationStatus.Active,ct);
            var max = l.Subscription is null ? l.MaximumInstallations : Math.Min(l.MaximumInstallations,l.Subscription.MaximumInstallations);
            if (active >= Math.Max(1,max))
                return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.InstallationLimitReached,"Maximum installation count has been reached.");
            i = new Installation { LicenseId=l.Id, InstallationIdentifier=iid, MachineFingerprintHash=fp, Status=InstallationStatus.Active, ActivatedAtUtc=DateTime.UtcNow, LastSeenAtUtc=DateTime.UtcNow };
            db.Installations.Add(i);
        }
        else
        {
            if (i.LicenseId!=l.Id) return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.InvalidLicense,"Installation is registered to another license.");
            if (!string.Equals(i.MachineFingerprintHash,fp,StringComparison.OrdinalIgnoreCase)) return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.MachineMismatch,"Installation identity does not match this machine.");
            if (i.Status is InstallationStatus.Suspended or InstallationStatus.Revoked) return LicensingResponse<ActivationResult>.Fail(LicenseResultCode.InstallationDisabled,"Installation is disabled.");
            i.Status=InstallationStatus.Active; i.LastSeenAtUtc=DateTime.UtcNow; i.UpdatedAtUtc=DateTime.UtcNow;
        }

        await db.SaveChangesAsync(ct);
        return LicensingResponse<ActivationResult>.Ok(new ActivationResult {
            LicenseId=l.Id.ToString(), InstallationId=iid.ToString(), ProductCode=l.Product!.ProductCode,
            EffectiveState=Effective(l), ValidUntilUtc=l.ValidUntilUtc, GraceEndsAtUtc=GraceEnd(l),
            Entitlements=await LoadEntitlements(l.Id,ct)
        },"License activation succeeded.");
    }

    public async Task<LicensingResponse<ValidationResult>> ValidateAsync(ValidationRequest r, CancellationToken ct = default)
    {
        if (!Guid.TryParse(r.InstallationId,out var iid)) return LicensingResponse<ValidationResult>.Fail(LicenseResultCode.InvalidRequest,"Installation ID is invalid.");
        var l=await FindLicense(r.LicenseKey,r.ProductCode,ct);
        if(l is null) return LicensingResponse<ValidationResult>.Fail(LicenseResultCode.InvalidLicense,"License was not found for this product.");
        var f=Check(l); if(f is not null) return LicensingResponse<ValidationResult>.Fail(f.Value.code,f.Value.message);

        var i=await db.Installations.SingleOrDefaultAsync(x=>x.InstallationIdentifier==iid && x.LicenseId==l.Id,ct);
        if(i is null) return LicensingResponse<ValidationResult>.Fail(LicenseResultCode.InstallationNotFound,"Installation is not registered for this license.");
        if(i.Status!=InstallationStatus.Active) return LicensingResponse<ValidationResult>.Fail(LicenseResultCode.InstallationDisabled,"Installation is disabled.");
        if(!string.Equals(i.MachineFingerprintHash,MachineFingerprintHasher.Hash(r.MachineFingerprint),StringComparison.OrdinalIgnoreCase)) return LicensingResponse<ValidationResult>.Fail(LicenseResultCode.MachineMismatch,"Installation identity does not match this machine.");

        i.LastSeenAtUtc=DateTime.UtcNow; i.UpdatedAtUtc=DateTime.UtcNow; await db.SaveChangesAsync(ct);
        var state=Effective(l);
        return LicensingResponse<ValidationResult>.Ok(new ValidationResult {
            LicenseId=l.Id.ToString(),InstallationId=iid.ToString(),ProductCode=l.Product!.ProductCode,EffectiveState=state,
            AllowWriteOperations=state is EffectiveLicenseState.Active or EffectiveLicenseState.Grace,
            ValidUntilUtc=l.ValidUntilUtc,GraceEndsAtUtc=GraceEnd(l),Entitlements=await LoadEntitlements(l.Id,ct)
        },"License validation succeeded.");
    }

    public async Task<LicensingResponse<HeartbeatResult>> HeartbeatAsync(HeartbeatRequest r, CancellationToken ct = default)
    {
        var v=await ValidateAsync(new ValidationRequest{LicenseKey=r.LicenseKey,ProductCode=r.ProductCode,InstallationId=r.InstallationId,MachineFingerprint=r.MachineFingerprint},ct);
        if(!v.Success) return LicensingResponse<HeartbeatResult>.Fail(v.Code,v.Message);
        var iid=Guid.Parse(r.InstallationId);
        var i=await db.Installations.SingleAsync(x=>x.InstallationIdentifier==iid,ct);
        var next=r.Sequence>0?r.Sequence:i.LastHeartbeatSequence+1;
        if(next<=i.LastHeartbeatSequence) return LicensingResponse<HeartbeatResult>.Fail(LicenseResultCode.SequenceRejected,"Heartbeat sequence is stale.");
        i.LastHeartbeatSequence=next;i.LastSeenAtUtc=DateTime.UtcNow;i.UpdatedAtUtc=DateTime.UtcNow;await db.SaveChangesAsync(ct);
        return LicensingResponse<HeartbeatResult>.Ok(new HeartbeatResult{InstallationId=iid.ToString(),Sequence=next,ServerTimeUtc=DateTime.UtcNow},"Heartbeat accepted.");
    }

    public async Task<LicensingResponse<DeactivationResult>> DeactivateAsync(DeactivationRequest r, CancellationToken ct = default)
    {
        if(!Guid.TryParse(r.InstallationId,out var iid)) return LicensingResponse<DeactivationResult>.Fail(LicenseResultCode.InvalidRequest,"Installation ID is invalid.");
        var l=await FindLicense(r.LicenseKey,r.ProductCode,ct);
        if(l is null) return LicensingResponse<DeactivationResult>.Fail(LicenseResultCode.InvalidLicense,"License was not found for this product.");
        var i=await db.Installations.SingleOrDefaultAsync(x=>x.InstallationIdentifier==iid && x.LicenseId==l.Id,ct);
        if(i is null) return LicensingResponse<DeactivationResult>.Fail(LicenseResultCode.InstallationNotFound,"Installation was not found.");
        if(!string.Equals(i.MachineFingerprintHash,MachineFingerprintHasher.Hash(r.MachineFingerprint),StringComparison.OrdinalIgnoreCase)) return LicensingResponse<DeactivationResult>.Fail(LicenseResultCode.MachineMismatch,"Installation identity does not match this machine.");
        if(i.Status==InstallationStatus.Revoked) return LicensingResponse<DeactivationResult>.Fail(LicenseResultCode.InstallationDisabled,"Installation is revoked.");
        i.Status=InstallationStatus.Deactivated;i.LastSeenAtUtc=DateTime.UtcNow;i.UpdatedAtUtc=DateTime.UtcNow;await db.SaveChangesAsync(ct);
        return LicensingResponse<DeactivationResult>.Ok(new DeactivationResult{InstallationId=iid.ToString(),ProductCode=l.Product!.ProductCode,Deactivated=true},"Installation deactivated.");
    }

    private async Task<License?> FindLicense(string key,string product,CancellationToken ct) =>
        await db.Licenses.Include(x=>x.Product).Include(x=>x.Customer).Include(x=>x.Subscription)
            .SingleOrDefaultAsync(x=>x.ActivationKeyHash==ActivationKeyHasher.Hash(key) && x.Product!=null && x.Product.ProductCode==product,ct);

    private static (LicenseResultCode code,string message)? Check(License l)
    {
        var now=DateTime.UtcNow;
        if(l.Product is null || !l.Product.IsActive) return (LicenseResultCode.ProductMismatch,"Product is not active.");
        if(l.Customer is null || !l.Customer.IsActive) return (LicenseResultCode.LicenseInactive,"Customer is inactive.");
        if(l.Status==LicenseStatus.Suspended) return (LicenseResultCode.LicenseSuspended,"License is suspended.");
        if(l.Status==LicenseStatus.Revoked) return (LicenseResultCode.LicenseRevoked,"License is revoked.");
        if(l.Status!=LicenseStatus.Active && l.Status!=LicenseStatus.Grace) return (LicenseResultCode.LicenseInactive,"License is not active.");
        if(l.ValidFromUtc.HasValue && now<l.ValidFromUtc.Value) return (LicenseResultCode.LicenseInactive,"License is not active yet.");
        if(l.ValidUntilUtc.HasValue && now>l.ValidUntilUtc.Value.AddDays(l.GracePeriodDays)) return (LicenseResultCode.LicenseExpired,"License is expired.");
        if(l.Subscription is not null && (l.Subscription.Status!=QFLM.Domain.Subscriptions.SubscriptionStatus.Active || now<l.Subscription.StartsAtUtc || (l.Subscription.EndsAtUtc.HasValue && now>l.Subscription.EndsAtUtc.Value))) return (LicenseResultCode.SubscriptionInactive,"Subscription is not active.");
        return null;
    }

    private static EffectiveLicenseState Effective(License l) {
        var now=DateTime.UtcNow;
        if(l.Status==LicenseStatus.Revoked) return EffectiveLicenseState.Revoked;
        if(l.Status==LicenseStatus.Suspended) return EffectiveLicenseState.Suspended;
        if(l.ValidUntilUtc.HasValue && now>l.ValidUntilUtc.Value) return now<=l.ValidUntilUtc.Value.AddDays(l.GracePeriodDays)?EffectiveLicenseState.Grace:EffectiveLicenseState.Expired;
        return EffectiveLicenseState.Active;
    }

    private static DateTime? GraceEnd(License l)=>l.ValidUntilUtc?.AddDays(l.GracePeriodDays);

    private async Task<IReadOnlyCollection<EntitlementDto>> LoadEntitlements(Guid id,CancellationToken ct) =>
        await db.LicenseEntitlements.AsNoTracking().Where(x=>x.LicenseId==id).Include(x=>x.Feature)
            .Select(x=>new EntitlementDto{FeatureCode=x.Feature!.FeatureCode,Enabled=x.Enabled,LimitValue=x.LimitValue}).ToListAsync(ct);
}