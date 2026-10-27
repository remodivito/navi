# Sets up a PowerShell session to build Navi on Windows. It re-reads the Swift
# toolchain's variables (SDKROOT and PATH), in case this shell started before
# Swift was installed; the toolchain finds MSVC and the Windows SDK itself.
#
#   . .\scripts\win-env.ps1
#   swift build --build-system native
#   swift run --build-system native navi-core-check
#
# Swift 6.4.1's default build system (Swift Build) fails on Windows with
# "use of undeclared identifier '_SH_DENYNO'" in the SDK's LibcOverlayShims.h,
# so use the native one until that's fixed. SwiftPM also warns that it can't
# make the .build\debug symlink unless Windows' Developer Mode is on; the
# build itself is fine.

$user = [Environment]::GetEnvironmentVariables('User')
if ($user['SDKROOT']) { $env:SDKROOT = $user['SDKROOT'] }
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + $user['Path']

if (-not (Get-Command swift -ErrorAction SilentlyContinue)) { throw "swift isn't on PATH; is the toolchain installed?" }
