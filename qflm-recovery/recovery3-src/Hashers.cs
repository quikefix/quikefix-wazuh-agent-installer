using System.Security.Cryptography;
using System.Text;
namespace QFLM.Application.Licensing.Security;
public static class ActivationKeyHasher { public static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value.Trim()))).ToLowerInvariant(); }
public static class MachineFingerprintHasher { public static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value.Trim()))).ToLowerInvariant(); }