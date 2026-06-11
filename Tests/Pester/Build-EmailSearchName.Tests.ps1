#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $NamePath = '..\..\source\Private\Email\Build-EmailSearchName.ps1'
    . (Join-Path -Path $PSScriptRoot -ChildPath $NamePath)
}

Describe 'Build-EmailSearchName' {

    Context 'Recipient and keyword fields' {
        It 'renders each populated field as Label:value joined by the separator' {
            $c = [ordered]@{ From = 'sus@hacker.com'; Subject = 'Payroll change' }
            $name = Build-EmailSearchName -Criteria $c
            $name | Should -Be 'From:sus@hacker.com, Subject:Payroll change'
        }
        It 'joins multiple values for one field with a comma' {
            $name = Build-EmailSearchName -Criteria ([ordered]@{ From = 'a@x.com', 'b@y.com' })
            $name | Should -Be 'From:a@x.com,b@y.com'
        }
        It 'labels AttachmentName as Attachment' {
            $name = Build-EmailSearchName -Criteria ([ordered]@{ AttachmentName = 'invoice.pdf' })
            $name | Should -Be 'Attachment:invoice.pdf'
        }
    }

    Context 'Dates are excluded' {
        It 'omits Start and End from the name' {
            $c = [ordered]@{ Start = [datetime]'2026-05-28'; From = 'a@x.com' }
            $name = Build-EmailSearchName -Criteria $c
            $name | Should -Be 'From:a@x.com'
        }
    }

    Context 'Fallback and truncation' {
        It 'uses a timestamped fallback when nothing name-eligible is set' {
            $name = Build-EmailSearchName -Criteria ([ordered]@{ Start = [datetime]'2026-05-28' })
            $name | Should -Match '^EmailSearch \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
        }
        It 'truncates the name to MaxLength' {
            $c = [ordered]@{ Subject = ('x' * 300) }
            $name = Build-EmailSearchName -Criteria $c -MaxLength 50
            $name.Length | Should -Be 50
        }
    }
}
