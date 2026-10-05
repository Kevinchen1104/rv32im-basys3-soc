<#
Script: scripts/test-catalog.ps1
Purpose: Reads the compact test catalog and applies shared metadata defaults.
Common usage:
  . "$PSScriptRoot/test-catalog.ps1"
Outputs:
  A catalog object with complete metadata for every test.
Scope:
  Catalog data loading; validation is performed by check-test-catalog.ps1.
#>
function Read-TestCatalog {
    param([Parameter(Mandatory = $true)][string]$Path)

    $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($catalog.schema_version -ne 3) { throw 'Test catalog schema_version must be 3.' }
    $allowedDefaults = @('evidence_level', 'uses_hierarchical_access', 'included_in_full_regression')
    foreach ($property in $catalog.defaults.PSObject.Properties) {
        if ($allowedDefaults -notcontains $property.Name) {
            throw "Unsupported test catalog default: $($property.Name)"
        }
    }
    $catalog.tests = @(
        foreach ($entry in $catalog.tests) {
            $fields = [ordered]@{}
            foreach ($property in $catalog.defaults.PSObject.Properties) {
                $fields[$property.Name] = $property.Value
            }
            foreach ($property in $entry.PSObject.Properties) {
                $fields[$property.Name] = $property.Value
            }
            [pscustomobject]$fields
        }
    )
    return $catalog
}
