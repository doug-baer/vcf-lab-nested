#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

<#
.SYNOPSIS
    Pester unit tests for Deploy-NestedVcfLab.ps1

.DESCRIPTION
    Extracts the script's functions via AST parsing (so loading the test file never
    triggers vCenter connections or module installs) and tests:
      - Convert-CidrToSubnetMask (pure function)
      - Get-SequentialIpAddress (pure function, incl. subnet-boundary validation)
      - New-HostResult (result-object shape)
      - Script structure: param block, required config keys, known-regression checks

.NOTES
    Run with:
        Invoke-Pester -Path .\Deploy-NestedVcfLab.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot 'Deploy-NestedVcfLab.ps1'
    $scriptContent = Get-Content -Path $scriptPath -Raw

    # Parse the script into an AST without executing it.
    $tokens      = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors.Count -gt 0) {
        throw "Script failed to parse cleanly: $($parseErrors[0].Message)"
    }

    # Define only the functions for in-memory unit testing.
    $functionDefs = $ast.FindAll(
        { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] },
        $true
    )
    foreach ($fn in $functionDefs) {
        Invoke-Expression $fn.Extent.Text
    }
}

Describe 'Script Structure (Static Analysis)' {
    It 'parses without syntax errors' {
        # Assertion is implicit: BeforeAll throws on parse failure before any It runs.
        $ast | Should -Not -BeNullOrEmpty
    }

    It 'declares a mandatory ConfigFile parameter' {
        $paramAst = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ConfigFile' }
        $paramAst | Should -Not -BeNullOrEmpty
        $paramAst.Attributes.TypeName.Name | Should -Contain 'Parameter'
        $paramAst.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
    }

    It 'declares a mandatory OvaPath parameter' {
        $paramAst = $ast.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'OvaPath' }
        $paramAst | Should -Not -BeNullOrEmpty
        $paramAst.Attributes.NamedArguments.ArgumentName | Should -Contain 'Mandatory'
    }

    It 'supports ShouldProcess (WhatIf)' {
        $ast.ParamBlock.Attributes.TypeName.Name | Should -Contain 'CmdletBinding'
        $ast.ParamBlock.Attributes.NamedArguments.Argument.GetScriptBlock().ToString().Trim().ToLowerInvariant() |
            Should -Match 'supportsshouldprocess\s*=\s*\$true'
    }

    It 'requires the DATACENTER_NAME configuration key' {
        $scriptContent | Should -Match "'DATACENTER_NAME'"
    }

    It 'requires the MGMT_SUBNET_CIDR configuration key' {
        $scriptContent | Should -Match "'MGMT_SUBNET_CIDR'"
    }

    It 'uses the full -Source parameter on Import-VApp (regression guard for -Sourc typo)' {
        # Every Import-VApp call must use the full parameter name.
        $callTexts = $ast.FindAll(
            { param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
              $node.GetCommandName() -eq 'Import-VApp' },
            $true
        ) | ForEach-Object { $_.Extent.Text }

        $callTexts.Count | Should -BeGreaterThan 0
        foreach ($text in $callTexts) {
            $text | Should -Not -Match '(?<![\w`-])-(Sourc|Sou|S)(?![\w])\s+\$'
        }
    }

    It 'maps all OVF network mappings generically (regression guard for hardcoded VM_Network)' {
        $scriptContent | Should -Not -Match "NetworkMapping\.VM_Network"
    }

    It 'scopes the datacenter lookup to the configured name' {
        $scriptContent | Should -Match 'Get-Datacenter\s+-Name\s+\$config\.DATACENTER_NAME'
    }
}

Describe 'Convert-CidrToSubnetMask' {
    It 'converts <prefix> to <expected>' -TestCases @(
        @{ Prefix = 0;  Expected = '0.0.0.0' }
        @{ Prefix = 8;  Expected = '255.0.0.0' }
        @{ Prefix = 12; Expected = '255.240.0.0' }
        @{ Prefix = 16; Expected = '255.255.0.0' }
        @{ Prefix = 20; Expected = '255.255.240.0' }
        @{ Prefix = 24; Expected = '255.255.255.0' }
        @{ Prefix = 28; Expected = '255.255.255.240' }
        @{ Prefix = 31; Expected = '255.255.255.254' }
        @{ Prefix = 32; Expected = '255.255.255.255' }
    ) {
        Convert-CidrToSubnetMask -PrefixLength $Prefix | Should -Be $Expected
    }

    It 'throws on prefix length <prefix> (out of range)' -TestCases @(
        @{ Prefix = -1 }
        @{ Prefix = 33 }
        @{ Prefix = 128 }
    ) {
        { Convert-CidrToSubnetMask -PrefixLength $Prefix } | Should -Throw
    }
}

Describe 'Get-SequentialIpAddress' {
    Context 'valid offsets' {
        It 'returns <cidr> + <offset> = <expected>' -TestCases @(
            @{ Cidr = '192.168.10.0/24'; Offset = 1;   Expected = '192.168.10.1' }
            @{ Cidr = '192.168.10.0/24'; Offset = 101; Expected = '192.168.10.101' }
            @{ Cidr = '192.168.10.0/24'; Offset = 254; Expected = '192.168.10.254' } # last host
            @{ Cidr = '10.0.0.0/8';      Offset = 5000; Expected = '10.0.19.136' }
            @{ Cidr = '172.16.5.0/24';   Offset = 103; Expected = '172.16.5.103' }
        ) {
            Get-SequentialIpAddress -Cidr $Cidr -Offset $Offset | Should -Be $Expected
        }
    }

    Context 'subnet boundary validation' {
        It 'rejects the network address itself (offset 0)' {
            { Get-SequentialIpAddress -Cidr '192.168.10.0/24' -Offset 0 } | Should -Throw '*outside the subnet*'
        }

        It 'rejects the broadcast address (/24)' {
            { Get-SequentialIpAddress -Cidr '192.168.10.0/24' -Offset 255 } | Should -Throw '*outside the subnet*'
        }

        It 'rejects the broadcast address (/30)' {
            { Get-SequentialIpAddress -Cidr '192.168.1.0/30' -Offset 3 } | Should -Throw '*outside the subnet*'
        }

        It 'rejects an offset past the broadcast address (rolls into next subnet)' {
            { Get-SequentialIpAddress -Cidr '192.168.1.0/30' -Offset 5 } | Should -Throw '*outside the subnet*'
        }

        It 'rejects an offset past broadcast on a small subnet (/26)' {
            { Get-SequentialIpAddress -Cidr '10.1.1.0/26' -Offset 64 } | Should -Throw '*outside the subnet*'
        }

        It 'accepts the last host address on a /26' {
            Get-SequentialIpAddress -Cidr '10.1.1.0/26' -Offset 62 | Should -Be '10.1.1.62'
        }

        It 'handles int overflow attempts on a large offset without wrapping' {
            # A 2^31-ish offset in 64-bit arithmetic far exceeds any subnet broadcast.
            { Get-SequentialIpAddress -Cidr '10.0.0.0/8' -Offset 2000000000 } | Should -Throw '*outside the subnet*'
        }
    }

    Context 'input validation' {
        It 'throws on an unparseable network address' {
            { Get-SequentialIpAddress -Cidr 'not.an.ip/24' -Offset 5 } | Should -Throw
        }
    }
}

Describe 'New-HostResult' {
    It 'builds a result object with all expected properties' {
        $result = New-HostResult -ShortName 'esx01' -Fqdn 'esx01.lab.local' -Ip '192.168.10.101' `
            -Vlan 10 -Cpus 4 -RamGb 24 -Status 'Deployed Successfully'

        $result.HostName  | Should -Be 'esx01'
        $result.FQDN      | Should -Be 'esx01.lab.local'
        $result.IPAddress | Should -Be '192.168.10.101'
        $result.VLAN      | Should -Be 10
        $result.vCPU      | Should -Be 4
        $result.RAM_GB    | Should -Be 24
        $result.Status    | Should -Be 'Deployed Successfully'
    }

    It 'preserves error detail in the Status field' {
        $result = New-HostResult -ShortName 'esx02' -Fqdn 'esx02.lab.local' -Ip '192.168.10.102' `
            -Vlan 10 -Cpus 4 -RamGb 24 -Status 'Failed: Simulated import error'
        $result.Status | Should -BeLike 'Failed:*Simulated import error'
    }

    It 'is Mandatory-gated on ShortName' {
        { New-HostResult -Fqdn 'x.lab.local' -Ip '1.2.3.4' -Vlan 1 -Cpus 1 -RamGb 1 -Status 'x' } |
            Should -Throw '*ShortName*'
    }
}

Describe 'Host naming convention (end-to-end arithmetic, no vCenter required)' {
    It 'derives expected hostnames and IPs for START 1..3 with offset 100 (legacy default)' -TestCases @(
        @{ Index = 1; ExpectedName = 'esx01'; ExpectedIp = '192.168.10.101' }
        @{ Index = 2; ExpectedName = 'esx02'; ExpectedIp = '192.168.10.102' }
        @{ Index = 3; ExpectedName = 'esx03'; ExpectedIp = '192.168.10.103' }
    ) {
        $shortName = '{0}{1:D2}' -f 'esx', $Index
        $shortName | Should -Be $ExpectedName

        $assignedIp = Get-SequentialIpAddress -Cidr '192.168.10.0/24' -Offset (100 + $Index)
        $assignedIp | Should -Be $ExpectedIp
    }

    It 'derives two-digit padding correctly for indexes above 9' -TestCases @(
        @{ Index = 10; ExpectedName = 'esx10'; ExpectedIp = '192.168.10.110' }
        @{ Index = 12; ExpectedName = 'esx12'; ExpectedIp = '192.168.10.112' }
    ) {
        ('{0}{1:D2}' -f 'esx', $Index) | Should -Be $ExpectedName
        Get-SequentialIpAddress -Cidr '192.168.10.0/24' -Offset (100 + $Index) | Should -Be $ExpectedIp
    }
}