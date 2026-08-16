[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',

    [ValidateSet('x64')]
    [string] $Architecture = 'x64',

    [switch] $SkipRestore,
    [switch] $Run
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $repositoryRoot 'frontends\windows\LibChess.WinUI.vcxproj'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer was not found. Install the Desktop development with C++ workload first.'
}

$msbuild = & $vswhere `
    -latest `
    -version '[17.0,18.0)' `
    -products '*' `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find 'MSBuild\**\Bin\MSBuild.exe' |
    Select-Object -First 1

if (-not $msbuild) {
    $msbuild = & $vswhere `
        -latest `
        -products '*' `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -find 'MSBuild\**\Bin\MSBuild.exe' |
        Select-Object -First 1
}

if (-not $msbuild) {
    throw 'MSBuild with the native C++ tools was not found.'
}

if (-not $SkipRestore) {
    & $msbuild $project `
        '/t:Restore' `
        '/p:RestorePackagesConfig=true' `
        "/p:Configuration=$Configuration" `
        "/p:Platform=$Architecture" `
        '/nologo' `
        '/verbosity:minimal'
    if ($LASTEXITCODE -ne 0) {
        throw "NuGet restore failed with exit code $LASTEXITCODE."
    }
}

$cargoArguments = @('build', '--package', 'libchess-ffi')
if ($Configuration -eq 'Release') {
    $cargoArguments += '--release'
}

Push-Location $repositoryRoot
try {
    & cargo @cargoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "The Rust DLL build failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

& $msbuild $project `
    '/t:Build' `
    "/p:Configuration=$Configuration" `
    "/p:Platform=$Architecture" `
    '/nologo' `
    '/verbosity:minimal'
if ($LASTEXITCODE -ne 0) {
    throw "The WinUI build failed with exit code $LASTEXITCODE."
}

$rustProfile = if ($Configuration -eq 'Release') { 'release' } else { 'debug' }
$rustDll = Join-Path $repositoryRoot "target\$rustProfile\libchess_ffi.dll"
$outputDirectory = Join-Path $repositoryRoot "frontends\windows\$Architecture\$Configuration\LibChess.WinUI"
$outputDll = Join-Path $outputDirectory 'libchess_ffi.dll'
$executable = Join-Path $outputDirectory 'LibChess.WinUI.exe'

if (-not (Test-Path -LiteralPath $rustDll)) {
    throw "The expected Rust DLL was not produced at '$rustDll'."
}
Copy-Item -LiteralPath $rustDll -Destination $outputDll -Force

Write-Host "Built native Windows app: $executable"

if ($Run) {
    Start-Process -FilePath $executable
}
