# tests/powershell/helpers/SecretStoreStub.psm1 — Pester twin of
# tests/bash/helpers/secret_store_stub.bash.
#
# Feature 021's SC-004 says the store is consulted AT MOST ONCE per reconcile.
# On the PowerShell port the store is `Get-JiraSecretManagerToken` in
# Credentials.psm1 (Phase 8, US6), called unqualified from `Resolve-JiraToken`
# in the SAME module — an ordinary function override from outside the module
# is invisible to that call, because unqualified command lookup inside a
# module resolves against the module's own session state first. Pester's
# `Mock -ModuleName` is the mechanism built for exactly this: it injects the
# stand-in into the module's own session state, so the real call site executes
# and every invocation is recorded to a file the caller owns (the PowerShell
# equivalent of the Bash PATH shim, and Constitution XIII test isolation —
# never a machine-wide scan).

Set-StrictMode -Version Latest

function Install-SecretStoreStub {
    <#
    .SYNOPSIS
      Redefine Get-JiraSecretManagerToken (inside the Credentials module) to a
      counting stand-in.

    .PARAMETER CounterFile
      One line appended per invocation. The caller creates and owns it.

    .PARAMETER Token
      What the stand-in returns. $null (the default) stands for "no entry of
      that name", which the bridge must treat as a silent fall-through.
    #>
    param(
        [Parameter(Mandatory)][string] $CounterFile,
        [string] $Token = $null
    )
    Set-Content -LiteralPath $CounterFile -Value $null
    Mock -ModuleName Credentials -CommandName Get-JiraSecretManagerToken -MockWith {
        Add-Content -LiteralPath $CounterFile -Value 'secretmanager'
        return $Token
    }.GetNewClosure()
}

function Get-SecretStoreStubCount {
    <#
    .SYNOPSIS
      How many times the store was asked. A missing file is 0.
    #>
    param([Parameter(Mandatory)][string] $CounterFile)
    if (-not (Test-Path -LiteralPath $CounterFile)) { return 0 }
    $lines = Get-Content -LiteralPath $CounterFile -ErrorAction SilentlyContinue
    if ($null -eq $lines) { return 0 }
    @($lines | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Length -gt 0 }).Count
}

Export-ModuleMember -Function Install-SecretStoreStub, Get-SecretStoreStubCount
