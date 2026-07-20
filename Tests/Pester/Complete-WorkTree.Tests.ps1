<#
.SYNOPSIS
    Pester tests for Scripts\Complete-WorkTree.ps1.

.DESCRIPTION
    The script now guards its main body with `if ($MyInvocation.InvocationName
    -eq '.') { return }` (added alongside this test), so it can be dot-sourced
    to reach its pure helper functions without running the interactive flow.

    Per the coverage plan, only the non-gh-dependent, non-mutating parts are
    covered: Get-DirtyStatusLine (clean-tree check), ConvertFrom-PrNote
    (cross-device note parsing), and Get-NotesRef (per-slug ref naming). The
    script's real work -- pushing branches and calling `gh pr create` -- is
    deliberately left untested here: this environment has `gh` installed and
    authenticated against a real account, so any test that reached that code
    path for real would risk pushing branches or opening pull requests against
    a real repository. NonLive; no tag.
#>

BeforeAll {
    $SutParams = @{
        Path      = $PSScriptRoot
        ChildPath = '..\..\Scripts\Complete-WorkTree.ps1'
    }
    $script:Sut = (Resolve-Path (Join-Path @SutParams)).Path

    # Dot-source with -WebFromNotes/-Slug so any accidental fall-through before
    # the guard would hit the "no note found" throw rather than a live gh call;
    # the guard itself returns before any of that runs.
    . $script:Sut -WebFromNotes -Slug 'dot-source-probe'
}

Describe 'Complete-WorkTree helpers' -Tag 'unit', 'functional' {

    Context 'Get-DirtyStatusLine' {
        It 'returns every status line when no path is exempt' {
            $Lines = @(' M Source/Public/Get-Greeting.ps1', '?? scratch.txt')
            $Result = Get-DirtyStatusLine -StatusLines $Lines -ExemptPath $null
            $Result.Count | Should -Be 2
        }

        It 'excludes the exempt path (e.g. PR.md)' {
            $Lines = @(' M Source/Public/Get-Greeting.ps1', '?? PR.md')
            $Result = @(Get-DirtyStatusLine -StatusLines $Lines -ExemptPath 'PR.md')
            $Result.Count | Should -Be 1
            $Result[0] | Should -Match 'Get-Greeting.ps1'
        }

        It 'ignores blank lines' {
            $Lines = @(' M a.ps1', '', '  ', '?? b.ps1')
            $Result = Get-DirtyStatusLine -StatusLines $Lines -ExemptPath $null
            $Result.Count | Should -Be 2
        }

        It 'handles a quoted path with special characters' {
            $Lines = @('?? "PR.md"')
            $Result = @(Get-DirtyStatusLine -StatusLines $Lines -ExemptPath 'PR.md')
            $Result.Count | Should -Be 0
        }
    }

    Context 'ConvertFrom-PrNote' {
        It 'parses base/title front matter and the body' {
            $Content = "base: develop`ntitle: feat: add thing`n---`nSummary here.`n"
            $Result = ConvertFrom-PrNote -Content $Content
            $Result.Base | Should -Be 'develop'
            $Result.Title | Should -Be 'feat: add thing'
            $Result.Body | Should -Match 'Summary here.'
        }

        It 'treats content with no separator as all body' {
            $Result = ConvertFrom-PrNote -Content 'just a plain body, no front matter'
            $Result.Base | Should -BeNullOrEmpty
            $Result.Title | Should -BeNullOrEmpty
            $Result.Body | Should -Be 'just a plain body, no front matter'
        }

        It 'handles an empty body after the separator' {
            $Result = ConvertFrom-PrNote -Content "base: develop`ntitle: x`n---"
            $Result.Base | Should -Be 'develop'
            $Result.Body | Should -Be ''
        }
    }

    Context 'Get-NotesRef' {
        It 'prefixes the slug with pr-body-' {
            Get-NotesRef -Slug 'issue-42' | Should -Be 'pr-body-issue-42'
        }

        It 'replaces slashes so the ref name stays a single path segment' {
            Get-NotesRef -Slug 'fix/login' | Should -Be 'pr-body-fix-login'
        }
    }
}
