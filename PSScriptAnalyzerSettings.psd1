@{
    # These scripts are interactive installers and a statusline renderer: their
    # console output is the user-facing product, not incidental logging, so
    # Write-Host is the correct cmdlet here. Every other default rule applies.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
