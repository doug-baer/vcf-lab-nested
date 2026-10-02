<#
.SYNOPSIS
    Pester unit tests for core helper functions in Deploy-NestedVcfLab.ps1
#>

BeforeAll {
    # ---------------------------------------------------------------------------
    # Helper Functions Under Test
    # ---------------------------------------------------------------------------
    function Convert-CidrToSubnetMask {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [int]$PrefixLength
        )
        if ($PrefixLength -lt 0 -or $PrefixLength -gt 32) {
            throw "Invalid CIDR prefix length: /$PrefixLength"
        }
        if ($PrefixLength -eq 0) { return "0.0.0.0" }
        
        $mask = ([uint32]::MaxValue -shl (32 - $PrefixLength));
        $bytes = [System.BitConverter]::GetBytes([uint32]$mask);
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
        return ($bytes -join '.')
    }

    function Get-SequentialIpAddress {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$Cidr,
            [Parameter(Mandatory = $true)]
            [int]$Offset
        )
        $networkAddress, $prefix = $Cidr.Split('/')
        $ipBytes = ([System.Net.IPAddress]::Parse($networkAddress)).GetAddressBytes()
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($ipBytes) }
        
        $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0);
        $targetInt = $ipInt + $Offset;
        $targetBytes = [System.BitConverter]::GetBytes([uint32]$targetInt);
        
        if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($targetBytes) }
        return ([System.Net.IPAddress]($targetBytes)).IPAddressToString
    }

    function Connect-TargetVCenter {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [string]$vCenterFqdn,
            [string]$User,
            [string]$Password
        )
        try {
            Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

            if ($global:DefaultVIServer -and $global:DefaultVIServer.Name -eq $vCenterFqdn) {
                Write-Verbose "Already connected to vCenter $vCenterFqdn"
                return $global:DefaultVIServer
            } else {
                if (-not [string]::IsNullOrWhiteSpace($User) -and -not [string]::IsNullOrWhiteSpace($Password)) {
                    $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
                    $cred = New-Object System.Management.Automation.PSCredential ($User, $securePass)
                    return Connect-VIServer -Server $vCenterFqdn -Credential $cred -ErrorAction Stop
                } else {
                    return Connect-VIServer -Server $vCenterFqdn -ErrorAction Stop
                }
            }
        } catch {
            throw "Failed to connect to hosting vCenter ($vCenterFqdn): $_"
        }
    }
}

# ---------------------------------------------------------------------------
# CIDR Conversion Tests
# ---------------------------------------------------------------------------
Describe "Convert-CidrToSubnetMask" {
    Context "Valid CIDR Prefix Lengths" {
        It "Converts /24 to 255.255.255.0" {
            $result = Convert-CidrToSubnetMask -PrefixLength 24;
            $result | Should -Be "255.255.255.0"
        }

        It "Converts /16 to 255.255.0.0" {
            $result = Convert-CidrToSubnetMask -PrefixLength 16;
            $result | Should -Be "255.255.0.0"
        }

        It "Converts /8 to 255.0.0.0" {
            $result = Convert-CidrToSubnetMask -PrefixLength 8;
            $result | Should -Be "255.0.0.0"
        }

        It "Converts /32 to 255.255.255.255" {
            $result = Convert-CidrToSubnetMask -PrefixLength 32;
            $result | Should -Be "255.255.255.255"
        }

        It "Converts /0 to 0.0.0.0" {
            $result = Convert-CidrToSubnetMask -PrefixLength 0;
            $result | Should -Be "0.0.0.0"
        }

        It "Converts /27 to 255.255.255.224" {
            $result = Convert-CidrToSubnetMask -PrefixLength 27;
            $result | Should -Be "255.255.255.224"
        }
    }

    Context "Invalid CIDR Prefix Lengths" {
        It "Throws an exception for negative prefix lengths (-1)" {
            { Convert-CidrToSubnetMask -PrefixLength -1 } | Should -Throw "*Invalid CIDR prefix length*"
        }

        It "Throws an exception for prefix lengths greater than 32 (33)" {
            { Convert-CidrToSubnetMask -PrefixLength 33 } | Should -Throw "*Invalid CIDR prefix length*"
        }
    }
}

# ---------------------------------------------------------------------------
# Sequential IP Calculation Tests (Base Offset 101)
# ---------------------------------------------------------------------------
Describe "Get-SequentialIpAddress" {
    Context "Sequential IP Calculation Starting at Host 1 Offset 101" {
        It "Calculates Host 1 (offset 101) on 10.45.0.0/24 as 10.45.0.101" {
            $hostNumber = 1;
            $ipOffset = 100 + $hostNumber;
            $result = Get-SequentialIpAddress -Cidr "10.45.0.0/24" -Offset $ipOffset;
            $result | Should -Be "10.45.0.101"
        }

        It "Calculates Host 10 (offset 110) on 10.45.0.0/24 as 10.45.0.110" {
            $hostNumber = 10;
            $ipOffset = 100 + $hostNumber;
            $result = Get-SequentialIpAddress -Cidr "10.45.0.0/24" -Offset $ipOffset;
            $result | Should -Be "10.45.0.110"
        }

        It "Handles subnet boundaries across octets (10.45.0.0/24 + offset 258 -> 10.45.1.2)" {
            $result = Get-SequentialIpAddress -Cidr "10.45.0.0/24" -Offset 258;
            $result | Should -Be "10.45.1.2"
        }
    }
}

# ---------------------------------------------------------------------------
# Host Name Padding Tests
# ---------------------------------------------------------------------------
Describe "Host Name Padding Verification" {
    It "Pads host index 1 to two digits '01'" {
        $index = 1;
        $padded = "{0:D2}" -f $index;
        $padded | Should -Be "01"
    }

    It "Formats host index 10 correctly as '10'" {
        $index = 10;
        $padded = "{0:D2}" -f $index;
        $padded | Should -Be "10"
    }

    It "Combines prefix 'esx' and padded index 1 to 'esx01'" {
        $prefix = "esx";
        $index = 1;
        $hostShortName = "$prefix$("{0:D2}" -f $index)";
        $hostShortName | Should -Be "esx01"
    }
}

# ---------------------------------------------------------------------------
# vCenter Connection Tests (Mocked)
# ---------------------------------------------------------------------------
Describe "Connect-TargetVCenter" {
    BeforeEach {
        Mock Set-PowerCLIConfiguration {}
        Mock Connect-VIServer {
            return [PSCustomObject]@{
                Name        = "vc01.lab.local"
                IsConnected = $true
            }
        }
        $global:DefaultVIServer = $null
    }

    Context "Connection Parameter Execution" {
        It "Executes Connect-VIServer with explicit PSCredential when credentials are provided" {
            Connect-TargetVCenter -vCenterFqdn "vc01.lab.local" -User "admin@vsphere.local" -Password "Secret123!"

            Should -Invoke Connect-VIServer -Times 1 -Exactly -ParameterFilter {
                $Server -eq "vc01.lab.local" -and $Credential -ne $null
            }
        }

        It "Executes Connect-VIServer without explicit PSCredential when User/Password are omitted" {
            Connect-TargetVCenter -vCenterFqdn "vc01.lab.local"

            Should -Invoke Connect-VIServer -Times 1 -Exactly -ParameterFilter {
                $Server -eq "vc01.lab.local" -and $Credential -eq $null
            }
        }

        It "Sets PowerCLI SSL certificate policy to Ignore during execution" {
            Connect-TargetVCenter -vCenterFqdn "vc01.lab.local"

            Should -Invoke Set-PowerCLIConfiguration -Times 1 -Exactly -ParameterFilter {
                $InvalidCertificateAction -eq "Ignore" -and $Scope -eq "Session"
            }
        }

        It "Bypasses Connect-VIServer call if already connected to target vCenter" {
            $global:DefaultVIServer = [PSCustomObject]@{ Name = "vc01.lab.local"; IsConnected = $true }

            $session = Connect-TargetVCenter -vCenterFqdn "vc01.lab.local"

            Should -Invoke Connect-VIServer -Times 0
            $session.Name | Should -Be "vc01.lab.local"
        }

        It "Catches underlying SSL/connection errors and wraps them in a friendly error message" {
            Mock Connect-VIServer { throw "The SSL connection could not be established" }

            { Connect-TargetVCenter -vCenterFqdn "vc01.lab.local" } | Should -Throw "*Failed to connect to hosting vCenter (vc01.lab.local)*"
        }
    }
}