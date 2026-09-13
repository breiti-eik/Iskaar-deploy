[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Environment,

    [Parameter()]
    [string]$Deploy = 'false',

    [Parameter()]
    [string]$Monitoring = 'false',

    [Parameter()]
    [Alias('ImageTag', 'Image-Tag')]
    [string]$Tag,

    [Parameter()]
    [switch]$SkipSmoke,

    [Parameter()]
    [Alias('BUILD_TIMEOUT', 'Build-Timeout')]
    [int]$BuildTimeout = 300,

    [Parameter()]
    [Alias('MINIKUBE_START_TIMEOUT', 'Minikube-Start-Timeout')]
    [int]$MinikubeStartTimeout = 180,

    [Parameter()]
    [Alias('ROLLOUT_TIMEOUT', 'Rollout-Timeout')]
    [int]$RolloutTimeout = 120,

    [Parameter()]
    [Alias('CERTIFICATE_TIMEOUT', 'Certificate-Timeout')]
    [int]$CertificateTimeout = 120,

    [Parameter()]
    [Alias('ACCESS_TIMEOUT', 'Access-Timeout')]
    [int]$AccessTimeout = 60,

    [Parameter()]
    [Alias('SMOKE_TIMEOUT', 'Smoke-Timeout')]
    [int]$SmokeTimeout = 60
)

Set-StrictMode -Version 2.0

function Fail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [int]$ExitCode = 2
    )

    Write-Error $Message
    exit $ExitCode
}

function Assert-ExactBoolean {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value
    )

    if ($Value -cne 'true' -and $Value -cne 'false') {
        Fail "Invalid -$Name value '$Value'. Expected exactly 'true' or 'false'."
    }
}

function Assert-PositiveTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [int]$Value
    )

    if ($Value -le 0) {
        Fail "Invalid -$Name value '$Value'. The timeout must be a positive integer."
    }
}

function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WindowsPath
    )

    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -match '^(?<drive>[A-Za-z]):[\\/](?<path>.*)$') {
        $drive = $Matches['drive'].ToLowerInvariant()
        $path = $Matches['path'] -replace '\\', '/'
        return "/mnt/$drive/$path"
    }

    return $fullPath -replace '\\', '/'
}

function Test-WslBashShim {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = $Path.Replace('/', '\\')
    return $normalizedPath -match '(?i)\\(Windows\\System32|WindowsApps)\\bash\.exe$'
}

$allowedEnvironments = @('dev', 'stage', 'prod')
if ($allowedEnvironments -cnotcontains $Environment) {
    Fail "Invalid -Environment value '$Environment'. Expected exactly one of: dev, stage, prod."
}

Assert-ExactBoolean -Name 'Deploy' -Value $Deploy
Assert-ExactBoolean -Name 'Monitoring' -Value $Monitoring
Assert-PositiveTimeout -Name 'BuildTimeout' -Value $BuildTimeout
Assert-PositiveTimeout -Name 'MinikubeStartTimeout' -Value $MinikubeStartTimeout
Assert-PositiveTimeout -Name 'RolloutTimeout' -Value $RolloutTimeout
Assert-PositiveTimeout -Name 'CertificateTimeout' -Value $CertificateTimeout
Assert-PositiveTimeout -Name 'AccessTimeout' -Value $AccessTimeout
Assert-PositiveTimeout -Name 'SmokeTimeout' -Value $SmokeTimeout

$deployScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'deploy.sh'
if (-not (Test-Path -LiteralPath $deployScriptPath -PathType Leaf)) {
    Fail "The Bash entrypoint was not found at '$deployScriptPath'."
}

$runnerPath = $null
$runnerKind = $null
foreach ($candidate in @('bash.exe', 'wsl.exe')) {
    $command = Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        $runnerPath = $command.Path
        $runnerKind = $candidate
        break
    }
}

if ($null -eq $runnerPath) {
    Fail 'No Bash-compatible runner is available. Install Git for Windows so bash.exe is on PATH, or enable Windows Subsystem for Linux so wsl.exe is available.' 127
}

$arguments = @()
$usesWslPath = (
    ($runnerKind -ieq 'wsl.exe') -or
    (($runnerKind -ieq 'bash.exe') -and (Test-WslBashShim -Path $runnerPath))
)

if ($usesWslPath) {
    if ($runnerKind -ieq 'wsl.exe') {
        $arguments += 'bash'
    }
    $arguments += (ConvertTo-WslPath -WindowsPath $deployScriptPath)
}
else {
    $arguments += $deployScriptPath
}

$arguments += $Environment
$arguments += @('--deploy', $Deploy, '--monitoring', $Monitoring)

if ($null -ne $Tag) {
    $arguments += @('--tag', $Tag)
}

if ($SkipSmoke.IsPresent) {
    $arguments += '--skip-smoke'
}

$timeoutEnvironment = [ordered]@{
    BUILD_TIMEOUT          = $BuildTimeout
    MINIKUBE_START_TIMEOUT = $MinikubeStartTimeout
    ROLLOUT_TIMEOUT        = $RolloutTimeout
    CERTIFICATE_TIMEOUT    = $CertificateTimeout
    ACCESS_TIMEOUT         = $AccessTimeout
    SMOKE_TIMEOUT          = $SmokeTimeout
}

$previousEnvironment = @{}
foreach ($name in $timeoutEnvironment.Keys) {
    $previousEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
}

$childExitCode = 1
try {
    foreach ($name in $timeoutEnvironment.Keys) {
        [System.Environment]::SetEnvironmentVariable(
            $name,
            ([string]$timeoutEnvironment[$name]),
            'Process'
        )
    }

    & $runnerPath @arguments
    $childExitCode = $LASTEXITCODE
}
finally {
    foreach ($name in $timeoutEnvironment.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}

exit $childExitCode
