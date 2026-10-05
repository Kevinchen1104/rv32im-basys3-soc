# Compatibility entry point; the shared cleanup tool owns simulator cleanup.
param([switch]$Apply)
& "$PSScriptRoot/clean-artifacts.ps1" -Category Simulators -Apply:$Apply
