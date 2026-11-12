using Microsoft.AspNetCore.Mvc;
using QFLM.Application.Licensing.Models;
using QFLM.Application.Licensing.Services;
namespace QFLM.Api.Controllers;
[ApiController]
[Route("api/v1")]
public sealed class LicensingController(ILicensingService licensing) : ControllerBase {
 [HttpPost("activate")] public async Task<ActionResult<LicensingResponse<ActivationResult>>> Activate([FromBody] ActivationRequest r,CancellationToken ct)=>Ok(await licensing.ActivateAsync(r,ct));
 [HttpPost("validate")] public async Task<ActionResult<LicensingResponse<ValidationResult>>> Validate([FromBody] ValidationRequest r,CancellationToken ct)=>Ok(await licensing.ValidateAsync(r,ct));
 [HttpPost("heartbeat")] public async Task<ActionResult<LicensingResponse<HeartbeatResult>>> Heartbeat([FromBody] HeartbeatRequest r,CancellationToken ct)=>Ok(await licensing.HeartbeatAsync(r,ct));
 [HttpPost("deactivate")] public async Task<ActionResult<LicensingResponse<DeactivationResult>>> Deactivate([FromBody] DeactivationRequest r,CancellationToken ct)=>Ok(await licensing.DeactivateAsync(r,ct));
}