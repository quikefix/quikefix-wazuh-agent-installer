#requires -version 5.1
<#
QuikeFix Wazuh Agent Universal Installer - Windows
Repository: quikefix/quikefix-wazuh-agent-installer
#>

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# ============================================================
# CONFIGURATION
# ============================================================

$WazuhManager = if ($env:WAZUH_MANAGER) {
    $env:WAZUH_MANAGER
} else {
    "wazuh-agent.quikefix.info"
}

$WazuhAgentName = if ($env:WAZUH_AGENT_NAME) {
    $env:WAZUH_AGENT_NAME
} else {
    $env:COMPUTERNAME
}

$RegistrationServer = if ($env:WAZUH_REGISTRATION_SERVER) {
    $env:WAZUH_REGISTRATION_SERVER
} else {
    $WazuhManager
}

$ConnectionWait = 60
$ConnectionInterval = 5

$LogDirectory = Join-Path $env:ProgramData "QuikeFix\Wazuh"
$LogFile = Join-Path $LogDirectory "install.log"

$AgentDirectory64 = "${env:ProgramFiles(x86)}\ossec-agent"
$AgentDirectory32 = "$env:ProgramFiles\ossec-agent"

$ServiceName = "WazuhSvc"

$MsiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-4.14.8-1.msi"
$MsiFile = Join-Path $env:TEMP "quikefix-wazuh-agent.msi"

$InstallMethod = "None"
$ConnectionState = "NO"
$ManagerIP = "Unknown"

# ============================================================
# OUTPUT
# ============================================================

New-Item -ItemType Directory -Path $LogDirectory -Force |
    Out-Null

function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    Write-Host $Message -ForegroundColor $Color

    $PlainMessage = $Message -replace '\x1b\[[0-9;]*m', ''

    Add-Content -Path $LogFile -Value $PlainMessage
}

function Write-Pass {
    param([string]$Message)
    Write-Log "[PASS] $Message" "Green"
}

function Write-InfoQF {
    param([string]$Message)
    Write-Log "[INFO] $Message" "Cyan"
}

function Write-WarnQF {
    param([string]$Message)
    Write-Log "[WARN] $Message" "Yellow"
}

function Write-Fail {
    param([string]$Message)
    Write-Log "[FAIL] $Message" "Red"
}

# ============================================================
# HEADER
# ============================================================

Write-Log ""
Write-Log "============================================================"
Write-Log " QUIKEFIX WAZUH AGENT INSTALLER - WINDOWS"
Write-Log "============================================================"
Write-Log "Started      : $(Get-Date)"
Write-Log "Computer     : $env:COMPUTERNAME"
Write-Log "Agent Name   : $WazuhAgentName"
Write-Log "Manager      : $WazuhManager"
Write-Log "============================================================"

# ============================================================
# ADMINISTRATOR CHECK
# ============================================================

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)

$IsAdmin = $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdmin) {

    Write-Fail "Administrator privileges are required."
    Write-Fail "Open PowerShell as Administrator and run again."

    exit 1
}

Write-Pass "Administrator privileges confirmed."

# ============================================================
# OPERATING SYSTEM
# ============================================================

try {

    $OS = Get-CimInstance Win32_OperatingSystem

    $OSName = $OS.Caption
    $OSVersion = $OS.Version
    $OSArchitecture = $OS.OSArchitecture

    Write-InfoQF "Operating system: $OSName"
    Write-InfoQF "Version: $OSVersion"
    Write-InfoQF "Architecture: $OSArchitecture"

}
catch {

    Write-Fail "Unable to determine Windows operating system."
    exit 1
}

# ============================================================
# TLS
# ============================================================

try {

    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor
        [Net.SecurityProtocolType]::Tls12

}
catch {
    # Continue. Modern PowerShell normally negotiates TLS correctly.
}

# ============================================================
# DNS TEST
# ============================================================

Write-InfoQF "Testing manager DNS..."

try {

    $Resolved = Resolve-DnsName `
        -Name $WazuhManager `
        -Type A `
        -ErrorAction Stop |
        Select-Object -First 1

    $ManagerIP = $Resolved.IPAddress

    Write-Pass "$WazuhManager resolves to $ManagerIP"

}
catch {

    Write-Fail "DNS resolution failed for $WazuhManager"
    exit 1
}

# ============================================================
# TCP PORT TEST
# ============================================================

function Test-QFTcpPort {

    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $Client = New-Object System.Net.Sockets.TcpClient

    try {

        $Async = $Client.BeginConnect(
            $ComputerName,
            $Port,
            $null,
            $null
        )

        $Connected = $Async.AsyncWaitHandle.WaitOne(
            $TimeoutMilliseconds,
            $false
        )

        if (-not $Connected) {
            return $false
        }

        $Client.EndConnect($Async)

        return $true

    }
    catch {

        return $false

    }
    finally {

        $Client.Close()

    }
}

$Port1514 = Test-QFTcpPort `
    -ComputerName $WazuhManager `
    -Port 1514

if ($Port1514) {
    Write-Pass "TCP 1514 reachable."
}
else {
    Write-Fail "TCP 1514 is unreachable."
    Write-Fail "Agent communication cannot continue."
    exit 1
}

$Port1515 = Test-QFTcpPort `
    -ComputerName $RegistrationServer `
    -Port 1515

if ($Port1515) {
    Write-Pass "TCP 1515 reachable."
}
else {
    Write-WarnQF "TCP 1515 enrollment port is unreachable."
    Write-WarnQF "An already-enrolled agent may still connect."
}

# ============================================================
# FIND EXISTING INSTALLATION
# ============================================================

$ExistingService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

$AgentDirectory = $null

if (Test-Path $AgentDirectory64) {

    $AgentDirectory = $AgentDirectory64

}
elseif (Test-Path $AgentDirectory32) {

    $AgentDirectory = $AgentDirectory32

}

if ($ExistingService) {

    Write-Pass "Existing Wazuh agent service detected."
    $InstallMethod = "Existing installation"

}
else {

    Write-InfoQF "Wazuh agent is not currently installed."

}

# ============================================================
# DOWNLOAD WAZUH MSI
# ============================================================

function Download-WazuhInstaller {

    Write-InfoQF "Downloading official Wazuh Windows agent..."

    try {

        if (Test-Path $MsiFile) {
            Remove-Item $MsiFile -Force
        }

        Invoke-WebRequest `
            -Uri $MsiUrl `
            -OutFile $MsiFile `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $MsiFile)) {
            throw "Installer file was not created."
        }

        $Size = (Get-Item $MsiFile).Length

        if ($Size -lt 1MB) {
            throw "Downloaded installer is unexpectedly small."
        }

        Write-Pass "Wazuh MSI downloaded."

        return $true

    }
    catch {

        Write-WarnQF "MSI download failed: $($_.Exception.Message)"
        return $false

    }
}

# ============================================================
# VERIFY MSI SIGNATURE
# ============================================================

function Test-WazuhInstallerSignature {

    if (-not (Test-Path $MsiFile)) {
        return $false
    }

    try {

        $Signature = Get-AuthenticodeSignature $MsiFile

        if ($Signature.Status -ne "Valid") {

            Write-WarnQF "MSI signature status: $($Signature.Status)"
            return $false

        }

        Write-Pass "MSI Authenticode signature is valid."

        return $true

    }
    catch {

        Write-WarnQF "Unable to verify MSI signature."
        return $false

    }
}

# ============================================================
# INSTALL PLAN A
# ============================================================

function Install-WazuhPlanA {

    Write-InfoQF "PLAN A: Installing official Wazuh MSI."

    if (-not (Download-WazuhInstaller)) {
        return $false
    }

    if (-not (Test-WazuhInstallerSignature)) {

        Write-Fail "Official MSI signature verification failed."
        return $false

    }

    $Arguments = @(
        "/i"
        "`"$MsiFile`""
        "/qn"
        "/norestart"
        "WAZUH_MANAGER=`"$WazuhManager`""
        "WAZUH_REGISTRATION_SERVER=`"$RegistrationServer`""
        "WAZUH_AGENT_NAME=`"$WazuhAgentName`""
    )

    if ($env:WAZUH_REGISTRATION_PASSWORD) {

        $Arguments +=
            "WAZUH_REGISTRATION_PASSWORD=`"$($env:WAZUH_REGISTRATION_PASSWORD)`""

        Write-InfoQF "Enrollment password supplied through environment."

    }

    try {

        $Process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru

        if ($Process.ExitCode -in @(0, 3010)) {

            $script:InstallMethod = "Plan A - Official MSI"

            Write-Pass "Wazuh MSI installation completed."

            return $true

        }

        Write-WarnQF "PLAN A returned MSI exit code $($Process.ExitCode)"

        return $false

    }
    catch {

        Write-WarnQF "PLAN A failed: $($_.Exception.Message)"

        return $false

    }
}

# ============================================================
# INSTALL PLAN B
# RETRY MSI
# ============================================================

function Install-WazuhPlanB {

    Write-InfoQF "PLAN B: Retrying Wazuh MSI installation."

    Start-Sleep -Seconds 3

    if (-not (Test-Path $MsiFile)) {

        if (-not (Download-WazuhInstaller)) {
            return $false
        }

    }

    if (-not (Test-WazuhInstallerSignature)) {
        return $false
    }

    $Arguments = @(
        "/i"
        "`"$MsiFile`""
        "/qn"
        "/norestart"
        "WAZUH_MANAGER=`"$WazuhManager`""
        "WAZUH_REGISTRATION_SERVER=`"$RegistrationServer`""
        "WAZUH_AGENT_NAME=`"$WazuhAgentName`""
    )

    if ($env:WAZUH_REGISTRATION_PASSWORD) {

        $Arguments +=
            "WAZUH_REGISTRATION_PASSWORD=`"$($env:WAZUH_REGISTRATION_PASSWORD)`""

    }

    try {

        $Process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru

        if ($Process.ExitCode -in @(0, 3010)) {

            $script:InstallMethod =
                "Plan B - MSI retry"

            Write-Pass "Wazuh MSI retry completed."

            return $true

        }

        Write-WarnQF "PLAN B returned MSI exit code $($Process.ExitCode)"

        return $false

    }
    catch {

        Write-WarnQF "PLAN B failed: $($_.Exception.Message)"

        return $false

    }
}

# ============================================================
# INSTALL IF NEEDED
# ============================================================

if (-not $ExistingService) {

    $Installed = Install-WazuhPlanA

    if (-not $Installed) {

        $Installed = Install-WazuhPlanB

    }

    if (-not $Installed) {

        Write-Fail "All Windows installation plans failed."
        Write-Fail "Review $LogFile"

        exit 1

    }

}
else {

    $InstallMethod = "Existing installation"

}

# ============================================================
# REFRESH INSTALLATION INFORMATION
# ============================================================

Start-Sleep -Seconds 2

$ExistingService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if (-not $ExistingService) {

    Write-Fail "WazuhSvc was not found after installation."
    exit 1

}

if (Test-Path $AgentDirectory64) {

    $AgentDirectory = $AgentDirectory64

}
elseif (Test-Path $AgentDirectory32) {

    $AgentDirectory = $AgentDirectory32

}
else {

    Write-Fail "Wazuh installation directory was not found."
    exit 1

}

Write-Pass "Wazuh agent installation verified."

$OssecConf = Join-Path $AgentDirectory "ossec.conf"
$OssecLog = Join-Path $AgentDirectory "ossec.log"

# ============================================================
# VERIFY / REPAIR MANAGER CONFIGURATION
# ============================================================

if (-not (Test-Path $OssecConf)) {

    Write-Fail "Wazuh configuration file was not found:"
    Write-Fail $OssecConf

    exit 1

}

Write-InfoQF "Checking Wazuh manager configuration."

try {

    [xml]$ConfigXML = Get-Content `
        -Path $OssecConf `
        -Raw `
        -ErrorAction Stop

    $ServerNode = @(
        $ConfigXML.ossec_config.client.server
    ) | Select-Object -First 1

    if (-not $ServerNode) {

        throw "No client/server configuration found."

    }

    $CurrentManager = [string]$ServerNode.address

    if ($CurrentManager -ne $WazuhManager) {

        Write-WarnQF "Current manager is: $CurrentManager"
        Write-InfoQF "Changing manager to $WazuhManager"

        $Backup = "$OssecConf.quikefix-backup-$(
            Get-Date -Format 'yyyyMMdd-HHmmss'
        )"

        Copy-Item `
            -Path $OssecConf `
            -Destination $Backup `
            -Force

        $ServerNode.address = $WazuhManager

        $ConfigXML.Save($OssecConf)

    }

}
catch {

    Write-Fail "Unable to verify or repair ossec.conf."
    Write-Fail $_.Exception.Message

    exit 1

}

try {

    [xml]$VerifyXML = Get-Content `
        -Path $OssecConf `
        -Raw

    $ConfiguredManager = [string](
        @($VerifyXML.ossec_config.client.server)[0].address
    )

    if ($ConfiguredManager -ne $WazuhManager) {

        throw "Configured manager is $ConfiguredManager"

    }

    Write-Pass "Manager configuration verified."

}
catch {

    Write-Fail "Manager configuration verification failed."
    exit 1

}

# ============================================================
# START / RESTART AGENT
# ============================================================

Write-InfoQF "Starting Wazuh agent."

try {

    Set-Service `
        -Name $ServiceName `
        -StartupType Automatic

    $CurrentService = Get-Service `
        -Name $ServiceName

    if ($CurrentService.Status -eq "Running") {

        Restart-Service `
            -Name $ServiceName `
            -Force

    }
    else {

        Start-Service `
            -Name $ServiceName

    }

}
catch {

    Write-WarnQF "Initial Wazuh service start failed."

    Start-Sleep -Seconds 3

    try {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop

    }
    catch {

        Write-Fail "Wazuh agent service failed to start."
        Write-Fail $_.Exception.Message

        exit 1

    }

}

# ============================================================
# SERVICE VERIFICATION
# ============================================================

Start-Sleep -Seconds 3

$Service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if (
    $Service -and
    $Service.Status -eq "Running"
) {

    $ServiceState = "running"

    Write-Pass "Wazuh agent service is RUNNING."

}
else {

    $ServiceState = if ($Service) {
        $Service.Status.ToString()
    } else {
        "NotFound"
    }

    Write-Fail "Wazuh agent service state: $ServiceState"

    exit 1

}

# ============================================================
# CONNECTION VERIFICATION
# ============================================================

$ConnectionState = "NO"
$Elapsed = 0

Write-InfoQF `
    "Waiting for Wazuh manager connection (up to ${ConnectionWait}s)..."

while ($Elapsed -lt $ConnectionWait) {

    # Primary verification:
    # actual established TCP session to manager port 1514.
    try {

        $Established = Get-NetTCPConnection `
            -RemotePort 1514 `
            -State Established `
            -ErrorAction SilentlyContinue

        if ($Established) {

            $ConnectionState = "YES"

            Write-Pass `
                "Agent has an established TCP connection to port 1514."

            break

        }

    }
    catch {
        # Fall back to Wazuh log verification below.
    }

    # Secondary verification through the Wazuh agent log.
    if (Test-Path $OssecLog) {

        try {

            $RecentLog = Get-Content `
                -Path $OssecLog `
                -Tail 150 `
                -ErrorAction SilentlyContinue

            if (
                $RecentLog -match
                "Connected to the server|Connected to server|Server responded|Agent is now online"
            ) {

                $ConnectionState = "YES"

                Write-Pass `
                    "Agent successfully connected to Wazuh manager."

                break

            }

            if (
                $RecentLog -match
                "Invalid server address|Authentication error|Invalid password|Duplicate agent name"
            ) {

                Write-WarnQF `
                    "Wazuh reported an enrollment or authentication error."

                break

            }

        }
        catch {
            # Continue waiting.
        }

    }

    Start-Sleep -Seconds $ConnectionInterval

    $Elapsed += $ConnectionInterval

    Write-InfoQF `
        "Waiting for manager connection... $Elapsed/$ConnectionWait seconds"

}

# ============================================================
# FINAL SERVICE CHECK
# ============================================================

$Service = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if (
    $Service -and
    $Service.Status -eq "Running"
) {
    $ServiceState = "running"
}
else {
    $ServiceState = if ($Service) {
        $Service.Status.ToString()
    } else {
        "NotFound"
    }
}

# ============================================================
# CLEANUP
# ============================================================

if (Test-Path $MsiFile) {

    Remove-Item `
        -Path $MsiFile `
        -Force `
        -ErrorAction SilentlyContinue

}

# ============================================================
# SUMMARY
# ============================================================

Write-Log ""
Write-Log "============================================================"
Write-Log " QUIKEFIX WAZUH INSTALLATION RESULT"
Write-Log "============================================================"
Write-Log "OS             : $OSName"
Write-Log "Architecture   : $OSArchitecture"
Write-Log "Agent Name     : $WazuhAgentName"
Write-Log "Manager        : $WazuhManager"
Write-Log "Manager IP     : $ManagerIP"
Write-Log "Install Method : $InstallMethod"
Write-Log "Service        : $ServiceState"
Write-Log "Connection     : $ConnectionState"
Write-Log "Log            : $LogFile"
Write-Log "============================================================"

if (
    $ServiceState -eq "running" -and
    $ConnectionState -eq "YES"
) {

    Write-Log "RESULT: SUCCESS" "Green"
    exit 0

}
else {

    Write-Fail `
        "Wazuh installation did not pass final connection verification."

    Write-Fail "Review:"
    Write-Fail "  $LogFile"
    Write-Fail "  $OssecLog"

    Write-Log "RESULT: FAILED" "Red"

    exit 1

}
