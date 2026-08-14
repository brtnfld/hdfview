<#
.SYNOPSIS
    Move the bundled HDF core DLLs beside the launcher so they outrank PATH.

.DESCRIPTION
    Windows has no rpath, and a JNI wrapper's dependencies are resolved by
    module name even when the wrapper itself was loaded by absolute path.
    jpackage stages natives in <root>\app, which the loader never searches, so
    hdf5.dll would be found via PATH.

    The core DLLs move to <root>, the launcher's own directory, which is
    searched ahead of the system folder and PATH. The JNI wrappers (*_java.dll)
    stay in <root>\app for java.library.path, and app\plugin is untouched.

    Exits 0 when every format present in the bundle has its core DLLs at the
    root. Run after the app-image is created and before it is signed.

.PARAMETER AppImage
    Path to the jpackage app-image root, e.g. hdfview\target\dist\HDFView
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppImage
)

$ErrorActionPreference = 'Stop'

# Each JNI wrapper and the core libraries it depends on
$Formats = @(
    @{ Name = 'HDF5'; Wrapper = 'hdf5_java.dll'; Core = @('hdf5.dll') },
    @{ Name = 'HDF4'; Wrapper = 'hdf_java.dll';  Core = @('hdf.dll', 'mfhdf.dll') }
)

if (-not (Test-Path -LiteralPath $AppImage -PathType Container)) {
    Write-Error "App-image not found: $AppImage" -ErrorAction Continue
    exit 2
}

$root = (Resolve-Path -LiteralPath $AppImage).Path
$appDir = Join-Path $root 'app'

# jdk.jpackage ApplicationLayout: LAUNCHERS is "" and APP is "app" on Windows
if (-not (Test-Path -LiteralPath (Join-Path $root 'HDFView.exe'))) {
    Write-Error "Unexpected app-image layout: HDFView.exe not found in $root" -ErrorAction Continue
    exit 1
}
if (-not (Test-Path -LiteralPath $appDir -PathType Container)) {
    Write-Error "Unexpected app-image layout: $appDir not found" -ErrorAction Continue
    exit 1
}

# Non-recursive: app\plugin must not be touched
$dlls = @(Get-ChildItem -LiteralPath $appDir -Filter '*.dll' -File)
if ($dlls.Count -eq 0) {
    Write-Error "No DLLs found in $appDir - native libraries were not staged" -ErrorAction Continue
    exit 1
}

# Which formats made it into this bundle
$present = @($Formats | Where-Object { $dlls.Name -contains $_.Wrapper })
foreach ($format in $Formats) {
    if ($present -notcontains $format) {
        Write-Host "  warning: $($format.Name) is not in this bundle ($($format.Wrapper) absent)"
    }
}

$moved = 0
$kept = 0
foreach ($dll in $dlls) {
    if ($dll.Name -like '*_java.dll') {
        # Must stay resolvable through java.library.path
        $kept++
        continue
    }
    Move-Item -LiteralPath $dll.FullName -Destination $root -Force
    Write-Host "  moved $($dll.Name)"
    $moved++
}

Write-Host "Relocated $moved core DLLs to the app-image root; kept $kept JNI wrapper(s) in app\"

# --- Verification -----------------------------------------------------------
$failures = @()

foreach ($format in $present) {
    if (-not (Test-Path -LiteralPath (Join-Path $appDir $format.Wrapper))) {
        $failures += "$($format.Wrapper) is no longer in app\ - java.library.path will not find it"
    }
    foreach ($core in $format.Core) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $core))) {
            $failures += "$($format.Name): $core is not at the app-image root"
        }
    }
}

$strays = @(Get-ChildItem -LiteralPath $appDir -Filter '*.dll' -File |
            Where-Object { $_.Name -notlike '*_java.dll' })
if ($strays.Count -gt 0) {
    $failures += "core DLLs still in app\: $($strays.Name -join ', ')"
}

if (-not (Test-Path -LiteralPath (Join-Path $appDir 'plugin'))) {
    Write-Host "  warning: app\plugin not present - no HDF5 filter plugins were staged"
}

if ($failures.Count -gt 0) {
    # Write-Error renders a multi-line message as one run-together block
    Write-Host ''
    foreach ($failure in $failures) {
        Write-Host "  FAILED: $failure"
    }
    Write-Error "Core DLL relocation failed with $($failures.Count) problem(s); see above" -ErrorAction Continue
    exit 1
}

Write-Host "OK: core DLLs sit beside HDFView.exe, ahead of PATH in the loader's search order"
exit 0
