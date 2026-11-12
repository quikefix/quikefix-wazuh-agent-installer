using QFLM.Application.Licensing.Models;
namespace QFLM.Application.Licensing.Services;
public interface ILicensingService {
 Task<LicensingResponse<ActivationResult>> ActivateAsync(ActivationRequest request, CancellationToken ct = default);
 Task<LicensingResponse<ValidationResult>> ValidateAsync(ValidationRequest request, CancellationToken ct = default);
 Task<LicensingResponse<HeartbeatResult>> HeartbeatAsync(HeartbeatRequest request, CancellationToken ct = default);
 Task<LicensingResponse<DeactivationResult>> DeactivateAsync(DeactivationRequest request, CancellationToken ct = default);
}