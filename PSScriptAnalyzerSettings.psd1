@{
    # PSScriptAnalyzer configuration for the spec-kit-jira PowerShell 7+ port.
    Severity = @('Error', 'Warning')

    # Enforce the full default rule set; the port targets pwsh 7+ only.
    IncludeDefaultRules = $true

    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.0')
        }
    }

    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions',
        # The port stores every file as UTF-8 WITHOUT a BOM by design: byte-parity
        # with the Bash port (Constitution VI) requires deterministic, BOM-free
        # encoding, and PowerShell 7 reads UTF-8 without a BOM natively.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
