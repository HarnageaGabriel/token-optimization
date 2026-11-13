# Thin wrapper so the installer test can be invoked from the provider root.
& (Join-Path $PSScriptRoot 'tests\install.tests.ps1') @args
