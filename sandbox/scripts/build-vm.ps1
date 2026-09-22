[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath,

    [Parameter(Mandatory = $true)]
    [string]$IsoChecksum,

    [ValidateSet("VirtualBox", "VMware")]
    [string]$Target = "VirtualBox",

    [Parameter(Mandatory = $true)]
    [string]$BackendUrl
)

$ErrorActionPreference = "Stop"
$sandboxRoot = Split-Path -Parent $PSScriptRoot
$vmDirectory = Join-Path $sandboxRoot "vm"

if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
    throw "Packer was not found in PATH. Install Packer first."
}
if (-not (Test-Path -LiteralPath $IsoPath -PathType Leaf)) {
    throw "ISO not found: $IsoPath"
}
if ($IsoChecksum -notmatch '^sha256:[0-9a-fA-F]{64}$') {
    throw "IsoChecksum must use the sha256:<64-digit-hex> format."
}

$builder = ""
$arguments = @("build")
if ($Target -eq "VirtualBox") {
    if (-not (Get-Command VBoxManage -ErrorAction SilentlyContinue)) {
        throw "VBoxManage was not found in PATH. Install VirtualBox or add its directory to PATH."
    }
    $builder = "virtualbox-iso.memento"
} else {
    $builder = "vmware-iso.memento"
}

$resolvedISO = (Resolve-Path -LiteralPath $IsoPath).Path
$arguments += "-only=$builder"
$arguments += "-var"; $arguments += "iso_url=$resolvedISO"
$arguments += "-var"; $arguments += "iso_checksum=$IsoChecksum"
$arguments += "-var"; $arguments += "backend_url=$BackendUrl"
$arguments += $vmDirectory

Write-Host "Building $Target image..."
& packer init $vmDirectory
if ($LASTEXITCODE -ne 0) { throw "packer init failed." }
& packer @arguments
if ($LASTEXITCODE -ne 0) { throw "Packer build failed." }

$outputDirectory = if ($Target -eq "VirtualBox") { "output-virtualbox" } else { "output-vmware" }
Write-Host "Complete. Artifact available at $(Join-Path $sandboxRoot $outputDirectory)"
