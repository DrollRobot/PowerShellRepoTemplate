#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $QueryPath = '..\..\source\Private\Email\Build-EmailSearchQuery.ps1'
    . (Join-Path -Path $PSScriptRoot -ChildPath $QueryPath)
}

Describe 'Build-EmailSearchQuery' {

    Context 'kind:email scoping' {
        It 'always begins with (kind:email)' {
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ From = 'a@x.com' })
            $q | Should -BeLike '(kind:email)*'
        }
        It 'returns only (kind:email) when no criteria are set' {
            Build-EmailSearchQuery -Criteria ([ordered]@{}) | Should -Be '(kind:email)'
        }
    }

    Context 'Single text value (regression: scalar indexing)' {
        It 'quotes a single From value correctly' {
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ From = 'sushacker' })
            $q | Should -Be '(kind:email) AND (From:"sushacker")'
        }
    }

    Context 'Multiple text values' {
        It 'joins multiple values with OR inside the clause' {
            $c = [ordered]@{ From = 'a@x.com', 'b@y.com' }
            $q = Build-EmailSearchQuery -Criteria $c
            $q | Should -Be '(kind:email) AND (From:("a@x.com" OR "b@y.com"))'
        }
    }

    Context 'Property mapping and ordering' {
        It 'maps AttachmentName to the AttachmentNames property' {
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ AttachmentName = 'invoice.pdf' })
            $q | Should -Be '(kind:email) AND (AttachmentNames:"invoice.pdf")'
        }
        It 'emits clauses in a fixed property order regardless of input order' {
            $c = [ordered]@{ Subject = 'hi'; From = 'a@x.com' }
            $q = Build-EmailSearchQuery -Criteria $c
            $q | Should -Be '(kind:email) AND (From:"a@x.com") AND (Subject:"hi")'
        }
    }

    Context 'Date ranges on Received' {
        It 'builds a both-bounds range with ..' {
            $start = [datetime]'2026-05-28T00:00:00'
            $end = [datetime]'2026-05-28T23:59:59'
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ Start = $start; End = $end })
            $expected = '(kind:email) AND (Received:2026-05-28T00:00:00..2026-05-28T23:59:59)'
            $q | Should -Be $expected
        }
        It 'uses >= for a start-only range' {
            $start = [datetime]'2026-05-28T00:00:00'
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ Start = $start })
            $q | Should -Be '(kind:email) AND (Received>=2026-05-28T00:00:00)'
        }
        It 'uses <= for an end-only range' {
            $end = [datetime]'2026-05-28T23:59:59'
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ End = $end })
            $q | Should -Be '(kind:email) AND (Received<=2026-05-28T23:59:59)'
        }
    }

    Context 'Whitespace handling' {
        It 'ignores empty and whitespace-only values' {
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ From = @('', '  ') })
            $q | Should -Be '(kind:email)'
        }
        It 'trims surrounding whitespace from values' {
            $q = Build-EmailSearchQuery -Criteria ([ordered]@{ From = '  a@x.com  ' })
            $q | Should -Be '(kind:email) AND (From:"a@x.com")'
        }
    }
}
