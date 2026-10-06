#requires -version 5.1
<#
QuikeFix Wazuh Agent Universal Installer - Windows
Secure Private Edition
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

# ============================================================
# PRIVATE ENROLLMENT CONFIGURATION
# ============================================================

$WazuhEnrollmentPassword = if ($env:WAZUH_REGISTRATION_PASSWORD) {
    $env:WAZUH_REGISTRATION_PASSWORD
} else {
    "FcD09z0XRQKt0ucDMRvMhdFuqyEuwXG75HDFD+nBqyc="
}

# ============================================================
# INSTALLER SETTINGS
# ============================================================

$WazuhVersion = "4.14.8-1"
$MsiUrl = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$WazuhVersion.msi"
$MsiFile = Join-Path $env:TEMP "quikefix-wazuh-agent.msi"

$ServiceName = "WazuhSvc"

$AgentDirectory64 = "${env:ProgramFiles(x86)}\ossec-agent"
$AgentDirectory32 = "$env:ProgramFiles\ossec-agent"

$ConnectionWait = 60
$ConnectionInterval = 5

$LogDirectory = Join-Path $env:ProgramData "QuikeFix\Wazuh"
$LogFile = Join-Path $LogDirectory "install.log"

$InstallMethod = "None"
$ConnectionState = "NO"
$ServiceState = "unknown"
$ManagerIP = "Unknown"

# ============================================================
# SELF-ELEVATION
# ============================================================

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()

$CurrentPrincipal = New-Object `
    Security.Principal.WindowsPrincipal($CurrentIdentity)

$IsAdministrator = $CurrentPrincipal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)

if (-not $IsAdministrator) {

    Write-Host ""
    Write-Host "Administrator privileges are required."
    Write-Host "Requesting Windows UAC elevation..."
    Write-Host ""

    if (-not $PSCommandPath) {
        Write-Host "Unable to self-elevate because the script is not running from a file." `
            -ForegroundColor Red
        Write-Host "Run PowerShell as Administrator and execute the installer again."
        exit 1
    }

    try {

        $ElevatedArguments = @(
            "-NoProfile"
            "-ExecutionPolicy"
            "Bypass"
            "-File"
            "`"$PSCommandPath`""
        )

        $Process = Start-Process `
            -FilePath "powershell.exe" `
            -ArgumentList $ElevatedArguments `
            -Verb RunAs `
            -Wait `
            -PassThru

        exit $Process.ExitCode

    }
    catch {

        Write-Host "Administrator elevation was cancelled or failed." `
            -ForegroundColor Red
        exit 1

    }
}

# ============================================================
# LOGGING
# ============================================================

New-Item `
    -ItemType Directory `
    -Path $LogDirectory `
    -Force |
    Out-Null

function Write-QFLog {

    param(
        [string]$Level,
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::White
    )

    $Line = "[$Level] $Message"

    Write-Host $Line -ForegroundColor $Color

    try {
        Add-Content `
            -Path $LogFile `
            -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Line"
    }
    catch {
        # Logging failure must not terminate installation.
    }
}

function Write-InfoQF {
    param([string]$Message)
    Write-QFLog "INFO" $Message Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-QFLog "PASS" $Message Green
}

function Write-WarnQF {
    param([string]$Message)
    Write-QFLog "WARN" $Message Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-QFLog "FAIL" $Message Red
}

# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " QUIKEFIX WAZUH AGENT INSTALLER - WINDOWS"
Write-Host "============================================================"
Write-Host "Started      : $(Get-Date)"
Write-Host "Computer     : $env:COMPUTERNAME"
Write-Host "Agent Name   : $WazuhAgentName"
Write-Host "Manager      : $WazuhManager"
Write-Host "============================================================"

Write-Pass "Administrator privileges confirmed."

# ============================================================
# PASSWORD CHECK
# ============================================================

if (
    [string]::IsNullOrWhiteSpace($WazuhEnrollmentPassword) -or
    $WazuhEnrollmentPassword -eq "PUT-YOUR-PRIVATE-PASSWORD-HERE"
) {

    Write-Fail "Private Wazuh enrollment password has not been configured."
    exit 1
}

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
}

# ============================================================
# DNS
# ============================================================

Write-InfoQF "Testing manager DNS..."

try {

    $ResolvedAddresses = @(
        Resolve-DnsName `
            -Name $WazuhManager `
            -Type A `
            -ErrorAction Stop |
        Where-Object {
            $_.IPAddress
        }
    )

    if ($ResolvedAddresses.Count -eq 0) {
        throw "No IPv4 address returned."
    }

    $ManagerIP = $ResolvedAddresses[0].IPAddress

    Write-Pass "$WazuhManager resolves to $ManagerIP"

}
catch {

    Write-Fail "DNS resolution failed for $WazuhManager"
    exit 1
}

# ============================================================
# TCP TEST
# ============================================================

function Test-QFTcpPort {

    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMilliseconds = 5000
    )

    $Client = New-Object System.Net.Sockets.TcpClient

    try {

        $AsyncResult = $Client.BeginConnect(
            $ComputerName,
            $Port,
            $null,
            $null
        )

        $Connected = $AsyncResult.AsyncWaitHandle.WaitOne(
            $TimeoutMilliseconds,
            $false
        )

        if (-not $Connected) {
            return $false
        }

        $Client.EndConnect($AsyncResult)

        return $true

    }
    catch {
        return $false
    }
    finally {
        $Client.Close()
    }
}

if (
    Test-QFTcpPort `
        -ComputerName $WazuhManager `
        -Port 1514
) {

    Write-Pass "TCP 1514 reachable."

}
else {

    Write-Fail "TCP 1514 is unreachable."
    Write-Fail "Agent communication cannot continue."
    exit 1
}

$Port1515Reachable = Test-QFTcpPort `
    -ComputerName $RegistrationServer `
    -Port 1515

if ($Port1515Reachable) {

    Write-Pass "TCP 1515 reachable."

}
else {

    Write-WarnQF "TCP 1515 enrollment port is unreachable."

}

# ============================================================
# FIND WAZUH INSTALLATION
# ============================================================

function Get-QFAgentDirectory {

    if (Test-Path $AgentDirectory64) {
        return $AgentDirectory64
    }

    if (Test-Path $AgentDirectory32) {
        return $AgentDirectory32
    }

    return $null
}

$ExistingService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

$AgentDirectory = Get-QFAgentDirectory

if ($ExistingService) {

    Write-Pass "Existing Wazuh agent service detected."
    $InstallMethod = "Existing installation"

}
else {

    Write-InfoQF "Wazuh agent is not currently installed."

}

# ============================================================
# DETERMINE WHETHER EXISTING AGENT IS ENROLLED
# ============================================================

$ExistingEnrollment = $false

if ($AgentDirectory) {

    $ExistingClientKeys = Join-Path $AgentDirectory "client.keys"

    if (
        (Test-Path $ExistingClientKeys) -and
        ((Get-Item $ExistingClientKeys).Length -gt 0)
    ) {

        $ExistingEnrollment = $true
        Write-Pass "Existing Wazuh enrollment key detected."

    }
}

if (
    -not $ExistingEnrollment -and
    -not $Port1515Reachable
) {

    Write-Fail "This machine is not enrolled and TCP 1515 is required."
    exit 1
}

# ============================================================
# DOWNLOAD MSI
# ============================================================

function Get-QFWazuhInstaller {

    Write-InfoQF "Downloading official Wazuh Windows agent..."

    try {

        Remove-Item `
            -Path $MsiFile `
            -Force `
            -ErrorAction SilentlyContinue

        Invoke-WebRequest `
            -Uri $MsiUrl `
            -OutFile $MsiFile `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $MsiFile)) {
            throw "Installer was not downloaded."
        }

        $Size = (Get-Item $MsiFile).Length

        if ($Size -lt 1MB) {
            throw "Downloaded MSI is unexpectedly small."
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

function Test-QFWazuhSignature {

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
# MSI INSTALL
# ============================================================

function Install-QFWazuhMSI {

    param(
        [string]$MethodName
    )

    if (-not (Test-Path $MsiFile)) {

        if (-not (Get-QFWazuhInstaller)) {
            return $false
        }
    }

    if (-not (Test-QFWazuhSignature)) {
        return $false
    }

    #
    # Password is supplied directly to msiexec and is never
    # written to the QuikeFix installation log.
    #
    $Arguments = @(
        "/i"
        "`"$MsiFile`""
        "/qn"
        "/norestart"
        "WAZUH_MANAGER=`"$WazuhManager`""
        "WAZUH_REGISTRATION_SERVER=`"$RegistrationServer`""
        "WAZUH_AGENT_NAME=`"$WazuhAgentName`""
        "WAZUH_REGISTRATION_PASSWORD=`"$WazuhEnrollmentPassword`""
    )

    try {

        $Process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru

        if ($Process.ExitCode -in @(0, 3010)) {

            $script:InstallMethod = $MethodName

            Write-Pass "Wazuh MSI installation completed."

            return $true
        }

        Write-WarnQF "MSI returned exit code $($Process.ExitCode)"

        return $false

    }
    catch {

        Write-WarnQF "MSI installation failed: $($_.Exception.Message)"
        return $false

    }
}

# ============================================================
# FRESH INSTALLATION
# ============================================================

if (-not $ExistingService) {

    Write-InfoQF "PLAN A: Installing official Wazuh MSI."

    $Installed = Install-QFWazuhMSI `
        -MethodName "Plan A - Official MSI"

    if (-not $Installed) {

        Write-InfoQF "PLAN B: Retrying Wazuh MSI installation."

        Start-Sleep -Seconds 3

        Remove-Item `
            -Path $MsiFile `
            -Force `
            -ErrorAction SilentlyContinue

        $Installed = Install-QFWazuhMSI `
            -MethodName "Plan B - MSI retry"
    }

    if (-not $Installed) {

        Write-Fail "All Windows installation plans failed."
        Write-Fail "Review $LogFile"

        exit 1
    }
}

# ============================================================
# VERIFY INSTALLATION
# ============================================================

Start-Sleep -Seconds 2

$ExistingService = Get-Service `
    -Name $ServiceName `
    -ErrorAction SilentlyContinue

if (-not $ExistingService) {

    Write-Fail "WazuhSvc was not found after installation."
    exit 1
}

$AgentDirectory = Get-QFAgentDirectory

if (-not $AgentDirectory) {

    Write-Fail "Wazuh installation directory was not found."
    exit 1
}

Write-Pass "Wazuh agent installation verified."

$OssecConf = Join-Path $AgentDirectory "ossec.conf"
$OssecLog = Join-Path $AgentDirectory "ossec.log"
$ClientKeys = Join-Path $AgentDirectory "client.keys"

# ============================================================
# VERIFY / REPAIR MANAGER
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
# VERIFY SECURE ENROLLMENT
# ============================================================

if (
    (Test-Path $ClientKeys) -and
    ((Get-Item $ClientKeys).Length -gt 0)
) {

    Write-Pass "Wazuh enrollment key verified."

}
else {

    Write-Fail "No Wazuh enrollment key was created."
    Write-Fail "Secure enrollment did not complete."

    exit 1
}

# ============================================================
# RECORD CURRENT LOG POSITION
# ============================================================

$OssecLogStartLength = 0

if (Test-Path $OssecLog) {

    try {
        $OssecLogStartLength = (Get-Item $OssecLog).Length
    }
    catch {
        $OssecLogStartLength = 0
    }
}

# ============================================================
# START / RESTART SERVICE
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
            -Force `
            -ErrorAction Stop

    }
    else {

        Start-Service `
            -Name $ServiceName `
            -ErrorAction Stop

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
# SERVICE CHECK
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
# FRESH LOG READER
# ============================================================

function Get-QFNewWazuhLog {

    if (-not (Test-Path $OssecLog)) {
        return ""
    }

    try {

        $CurrentLength = (Get-Item $OssecLog).Length

        if ($CurrentLength -lt $OssecLogStartLength) {
            $script:OssecLogStartLength = 0
        }

        $Stream = New-Object System.IO.FileStream(
            $OssecLog,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )

        try {

            [void]$Stream.Seek(
                $script:OssecLogStartLength,
                [System.IO.SeekOrigin]::Begin
            )

            $Reader = New-Object System.IO.StreamReader($Stream)

            try {
                return $Reader.ReadToEnd()
            }
            finally {
                $Reader.Dispose()
            }

        }
        finally {
            $Stream.Dispose()
        }

    }
    catch {
        return ""
    }
}

# ============================================================
# CONNECTION VERIFICATION
# ============================================================

$ConnectionState = "NO"
$Elapsed = 0

Write-InfoQF `
    "Waiting for Wazuh manager connection (up to ${ConnectionWait}s)..."

while ($Elapsed -lt $ConnectionWait) {

    #
    # Primary check: new Wazuh log data generated after this restart.
    #
    $NewWazuhLog = Get-QFNewWazuhLog

    if (
        $NewWazuhLog -match
        "Connected to the server|Connected to server|Server responded|Agent is now online"
    ) {

        $ConnectionState = "YES"

        Write-Pass "Agent successfully connected to Wazuh manager."

        break
    }

    if (
        $NewWazuhLog -match
        "Invalid server address|Invalid password|Authentication error|Duplicate agent name|Unable to add agent"
    ) {

        Write-WarnQF `
            "Wazuh reported an authentication or enrollment error."

        break
    }

    #
    # Secondary check: established TCP 1514 session.
    #
    try {

        $EstablishedConnections = @(
            Get-NetTCPConnection `
                -RemotePort 1514 `
                -State Established `
                -ErrorAction SilentlyContinue
        )

        $MatchingConnection = $EstablishedConnections |
            Where-Object {
                $_.RemoteAddress -eq $ManagerIP
            } |
            Select-Object -First 1

        if ($MatchingConnection) {

            $ConnectionState = "YES"

            Write-Pass `
                "Agent has an established TCP connection to Wazuh manager."

            break
        }

    }
    catch {
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

Remove-Item `
    -Path $MsiFile `
    -Force `
    -ErrorAction SilentlyContinue

# ============================================================
# SUMMARY
# ============================================================

Write-Host ""
Write-Host "============================================================"
Write-Host " QUIKEFIX WAZUH INSTALLATION RESULT"
Write-Host "============================================================"
Write-Host "OS             : $OSName"
Write-Host "Architecture   : $OSArchitecture"
Write-Host "Agent Name     : $WazuhAgentName"
Write-Host "Manager        : $WazuhManager"
Write-Host "Manager IP     : $ManagerIP"
Write-Host "Install Method : $InstallMethod"
Write-Host "Service        : $ServiceState"
Write-Host "Connection     : $ConnectionState"
Write-Host "Log            : $LogFile"
Write-Host "============================================================"

if (
    $ServiceState -eq "running" -and
    $ConnectionState -eq "YES"
) {

    Write-Host "RESULT: SUCCESS" -ForegroundColor Green
    exit 0

}

Write-Fail `
    "Wazuh installation did not pass final connection verification."

Write-Fail "Review:"
Write-Fail "  $LogFile"
Write-Fail "  $OssecLog"

Write-Host "RESULT: FAILED" -ForegroundColor Red

exit 1
