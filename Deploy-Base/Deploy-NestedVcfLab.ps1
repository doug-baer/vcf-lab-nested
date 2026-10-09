<#
.SYNOPSIS
    Deploys nested ESX host virtual machines for VCF 9.1 lab environments based on a YAML configuration file.

.DESCRIPTION
    Automates Phase 1 of standing up a nested VCF lab environment. It parses a YAML setup file,
    validates hosting infrastructure, provisions VM host shells from a nested ESX OVA template, customizes
    OVF properties (including vmk0 VLAN tagging, IP, DNS, NTP, and passwords), configures VM hardware
    (vCPU, RAM, Nested HV, disk layout, dual trunk network adapters), and outputs a summary along with
    a DNS record creation checklist.

.PARAMETER ConfigFile
    Path to the YAML file containing network, host sizing, and location configurations.

.PARAMETER OvaPath
    Path to the local nested ESX OVA template file.

.EXAMPLE
    .\Deploy-NestedVcfLab.ps1 -ConfigFile ".\base-demo.yaml" -OvaPath ".\Nested_ESXi9.1.1.0_Appliance_Template_v1.0.ova"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Path to the YAML configuration file.")]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile,

    [Parameter(Mandatory = $true, HelpMessage = "Path to the local nested ESX OVA file.")]
    [ValidateNotNullOrEmpty()]
    [string]$OvaPath
)

# ---------------------------------------------------------------------------
# Helper Functions
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

    $mask = ([uint32]::MaxValue -shl (32 - $PrefixLength))
    $bytes = [System.BitConverter]::GetBytes([uint32]$mask)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($bytes) }
    return ($bytes -join '.')
}

function Get-SequentialIpAddress {
    <#
        .SYNOPSIS
        Returns the IP at a given integer offset from a CIDR network address,
        throwing if the result falls outside the subnet.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Cidr,

        [Parameter(Mandatory = $true)]
        [int]$Offset
    )
    $networkAddress, $prefix = $Cidr.Split('/')

    if ($prefix -lt 0 -or $prefix -gt 32) {
        throw "Invalid CIDR prefix length in '$Cidr'."
    }

    $ipBytes = ([System.Net.IPAddress]::Parse($networkAddress)).GetAddressBytes()
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($ipBytes) }
    $ipInt = [System.BitConverter]::ToUInt32($ipBytes, 0)

    if ($prefix -eq 0) {
        $maskInt = [uint32]0
    } else {
        $maskInt = [uint32]::MaxValue -shl (32 - $prefix)
    }

    # Highest usable address within the subnet (broadcast address).
    $broadcastInt = [int64]$ipInt -bor ([int64][uint32]::MaxValue - $maskInt)

    # Compute in 64-bit space first so offset overflow cannot silently wrap around.
    $targetInt = [int64]$ipInt + $Offset
    if ($targetInt -lt $ipInt + 1 -or $targetInt -gt $broadcastInt) {
        throw "Computed IP (offset $Offset from $Cidr) falls outside the subnet."
    }

    $targetBytes = [System.BitConverter]::GetBytes([uint32]$targetInt)
    if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($targetBytes) }
    return ([System.Net.IPAddress]($targetBytes)).IPAddressToString
}

function New-TrunkPortGroup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory = $true)]
        [string]$PortGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VdsName,

        [string]$VlanTrunkRange = "0-4094"
    )

    $vds = Get-VDSwitch -Name $VdsName -ErrorAction SilentlyContinue
    if (-not $vds) {
        throw "Unable to locate Distributed Virtual Switch (vDS) '$VdsName' to create port group '$PortGroupName'."
    }

    Write-Host "Creating Ephemeral VLAN Trunk Port Group '$PortGroupName' on vDS '$($vds.Name)'..." -ForegroundColor Yellow

    if ($PSCmdlet.ShouldProcess($PortGroupName, "Create Ephemeral Trunk Port Group on $($vds.Name)")) {
        $newPg = New-VDPortgroup -VDSwitch $vds `
                                 -Name $PortGroupName `
                                 -PortBinding Ephemeral `
                                 -VlanTrunkRange $VlanTrunkRange `
                                 -ErrorAction Stop

        Write-Verbose "Enabling Forged Transmits and MAC Address Changes on '$PortGroupName'..."
        $secPolicy = Get-VDSecurityPolicy -VDPortgroup $newPg
        Set-VDSecurityPolicy -SecurityPolicy $secPolicy `
                             -AllowForgedTransmits $true `
                             -AllowMacChanges $true `
                             -Confirm:$false | Out-Null

        return $newPg
    } else {
        return [PSCustomObject]@{ Name = $PortGroupName }
    }
}

function New-HostResult {
    <#
        .SYNOPSIS
        Builds the standardized per-host result object used in the deployment summary
        and DNS checklist output.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)][string]$ShortName,
        [Parameter(Mandatory = $true)][string]$Fqdn,
        [Parameter(Mandatory = $true)][string]$Ip,
        [Parameter(Mandatory = $true)]$Vlan,
        [Parameter(Mandatory = $true)]$Cpus,
        [Parameter(Mandatory = $true)]$RamGb,
        [Parameter(Mandatory = $true)][string]$Status
    )
    return [PSCustomObject]@{
        HostName  = $ShortName
        FQDN      = $Fqdn
        IPAddress = $Ip
        VLAN      = $Vlan
        vCPU      = $Cpus
        RAM_GB    = $RamGb
        Status    = $Status
    }
}

# ---------------------------------------------------------------------------
# Dependency Check & Environment Setup
# ---------------------------------------------------------------------------
Write-Verbose "Checking required PowerShell modules..."
if (-not (Get-Module -Name VMware.VimAutomation.Core -ListAvailable)) {
    throw "The 'VMware.VimAutomation.Core' PowerCLI module is required but not installed."
}

if (-not (Get-Module -Name powershell-yaml -ListAvailable)) {
    Write-Host "Installing missing dependency 'powershell-yaml'..." -ForegroundColor Yellow
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber
}
Import-Module -Name powershell-yaml -ErrorAction Stop

if (-not (Test-Path -Path $ConfigFile)) {
    throw "Configuration file not found at path: $ConfigFile"
}
if (-not (Test-Path -Path $OvaPath)) {
    throw "OVA template file not found at path: $OvaPath"
}

# ---------------------------------------------------------------------------
# Parse & Validate Configuration
# ---------------------------------------------------------------------------
Write-Host "Loading configuration from '$ConfigFile'..." -ForegroundColor Cyan
$rawYaml = Get-Content -Path $ConfigFile -Raw
$config = ConvertFrom-Yaml -Yaml $rawYaml

$requiredKeys = @(
    'ENVIRONMENT_NAME', 'FOLDER_NAME', 'DATACENTER_NAME', 'HOSTING_VCENTER_FQDN',
    'HOSTING_CLUSTER_NAME', 'HOSTING_DATASTORE_NAME', 'VDS_NAME', 'MGMT_VLAN_NUMBER',
    'TRUNK_PG_NAME', 'MGMT_SUBNET_CIDR', 'MGMT_DEFAULT_GATEWAY', 'DNS_DOMAIN_NAME',
    'DNS_SERVERS', 'NTP_SERVERS', 'HOST_NAME_PREFIX', 'START_HOST_NUMBER',
    'END_HOST_NUMBER', 'HOST_RAM_GB', 'HOST_CPUS', 'DISK_COUNT', 'DISK_SIZE_GB',
    'ESX_VM_ROOT_PASSWORD'
)

foreach ($key in $requiredKeys) {
    if (-not $config.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($config[$key])) {
        throw "Missing or empty required configuration key in YAML: '$key'"
    }
}

$cidrParts = $config.MGMT_SUBNET_CIDR.Split('/')
if ($cidrParts.Count -ne 2) {
    throw "Invalid MGMT_SUBNET_CIDR format. Expected format 'x.x.x.x/yy', got: $($config.MGMT_SUBNET_CIDR)"
}
$subnetMask = Convert-CidrToSubnetMask -PrefixLength ([int]$cidrParts[1])

# Optional key: defaults to the legacy behaviour of reserving the first ~100 addresses.
$ipStartOffset = 100
if ($config.ContainsKey('MGMT_IP_START_OFFSET') -and -not [string]::IsNullOrWhiteSpace($config['MGMT_IP_START_OFFSET'])) {
    $ipStartOffset = [int]$config.MGMT_IP_START_OFFSET
}

# ---------------------------------------------------------------------------
# vCenter Authentication & Infrastructure Operations
# ---------------------------------------------------------------------------
try {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -Scope Session | Out-Null

    if ($global:DefaultVIServer -and $global:DefaultVIServer.Name -eq $config.HOSTING_VCENTER_FQDN) {
        Write-Verbose "Already connected to vCenter $($config.HOSTING_VCENTER_FQDN)"
    } else {
        Write-Host "Connecting to vCenter '$($config.HOSTING_VCENTER_FQDN)'..." -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($config.HOSTING_VCENTER_USER) -and
            -not [string]::IsNullOrWhiteSpace($config.HOSTING_VCENTER_PASSWORD)) {
            $securePass = ConvertTo-SecureString $config.HOSTING_VCENTER_PASSWORD -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential ($config.HOSTING_VCENTER_USER, $securePass)
            Connect-VIServer -Server $config.HOSTING_VCENTER_FQDN -Credential $cred -ErrorAction Stop -Force | Out-Null
        } else {
            Connect-VIServer -Server $config.HOSTING_VCENTER_FQDN -ErrorAction Stop -Force | Out-Null
        }
    }

    $datacenter = Get-Datacenter -Name $config.DATACENTER_NAME -ErrorAction SilentlyContinue
    if (-not $datacenter) { throw "Target datacenter '$($config.DATACENTER_NAME)' not found in vCenter." }

    $cluster = Get-Cluster -Name $config.HOSTING_CLUSTER_NAME -Location $datacenter -ErrorAction SilentlyContinue
    if (-not $cluster) { throw "Target cluster '$($config.HOSTING_CLUSTER_NAME)' not found in datacenter '$($config.DATACENTER_NAME)'." }

    $datastore = $cluster | Get-Datastore -Name $config.HOSTING_DATASTORE_NAME -ErrorAction SilentlyContinue
    if (-not $datastore) { throw "Target datastore '$($config.HOSTING_DATASTORE_NAME)' not found in cluster '$($config.HOSTING_CLUSTER_NAME)'." }

    $targetHost = $cluster | Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" } | Select-Object -First 1
    if (-not $targetHost) { throw "No connected ESX hosts found in cluster '$($config.HOSTING_CLUSTER_NAME)' to perform deployment." }

    # Verify or provision trunk port group, scoped to the configured vDS / host.
    $vds = Get-VDSwitch -Name $config.VDS_NAME -ErrorAction SilentlyContinue
    $portGroup = $null
    if ($vds) {
        $portGroup = Get-VDPortgroup -Name $config.TRUNK_PG_NAME -VDSwitch $vds -ErrorAction SilentlyContinue
    }
    if (-not $portGroup) {
        $portGroup = Get-VirtualPortGroup -Name $config.TRUNK_PG_NAME -VMHost $targetHost -ErrorAction SilentlyContinue
    }

    if (-not $portGroup) {
        Write-Host "Target trunk port group '$($config.TRUNK_PG_NAME)' was not found. Provisioning automatically on vDS '$($config.VDS_NAME)'..." -ForegroundColor Yellow
        $portGroup = New-TrunkPortGroup -PortGroupName $config.TRUNK_PG_NAME -VdsName $config.VDS_NAME
    }

    # Verify or create VM target folder, scoped to this datacenter's VM root folder.
    $vmRootFolder = Get-Folder -Name "vm" -Location $datacenter -NoRecursion -ErrorAction SilentlyContinue
    if (-not $vmRootFolder) { throw "VM root folder not found in datacenter '$($config.DATACENTER_NAME)'" }

    $targetFolder = Get-Folder -Name $config.FOLDER_NAME -Location $vmRootFolder -NoRecursion -ErrorAction SilentlyContinue
    if (-not $targetFolder) {
        Write-Host "Creating VM Folder '$($config.FOLDER_NAME)'..." -ForegroundColor Yellow
        if ($PSCmdlet.ShouldProcess($config.FOLDER_NAME, "Create VM Folder")) {
            try {
                $targetFolder = New-Folder -Name $config.FOLDER_NAME -Location $vmRootFolder -ErrorAction Stop
            } catch {
                throw "Failed to create target VM Folder '$($config.FOLDER_NAME)': $_"
            }
        } else {
            $targetFolder = $vmRootFolder
        }
    }

    # Parse the OVF descriptor once; per-host property values are set inside the deployment loop.
    Write-Verbose "Parsing OVA configuration from '$OvaPath'..."
    $ovfConfig = Get-OvfConfiguration -Ovf $OvaPath

    # ---------------------------------------------------------------------------
    # Deployment Loop
    # ---------------------------------------------------------------------------
    $deploymentResults = [System.Collections.Generic.List[object]]::new()

    Write-Host "`nStarting deployment of nested hosts ($($config.START_HOST_NUMBER) to $($config.END_HOST_NUMBER))..." -ForegroundColor Cyan

    for ($i = [int]$config.START_HOST_NUMBER; $i -le [int]$config.END_HOST_NUMBER; $i++) {
        $paddedIndex = "{0:D2}" -f $i
        $hostShortName = "$($config.HOST_NAME_PREFIX)$paddedIndex"
        $hostFqdn = "$hostShortName.$($config.DNS_DOMAIN_NAME)"

        $ipOffset = $ipStartOffset + $i
        $assignedIp = Get-SequentialIpAddress -Cidr $config.MGMT_SUBNET_CIDR -Offset $ipOffset

        Write-Host "`n--------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "Deploying Host [$i/$($config.END_HOST_NUMBER)]: $hostFqdn ($assignedIp)" -ForegroundColor Green
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray

        try {
            # vCenter-wide existence check so duplicates anywhere in inventory are skipped
            # gracefully rather than failing mid-import.
            $existingVm = Get-VM -Name $hostShortName -ErrorAction SilentlyContinue
            if ($existingVm) {
                Write-Warning "VM '$hostShortName' already exists in vCenter inventory. Skipping deployment."
                $deploymentResults.Add((New-HostResult -ShortName $hostShortName -Fqdn $hostFqdn `
                    -Ip $assignedIp -Vlan $config.MGMT_VLAN_NUMBER -Cpus $config.HOST_CPUS -RamGb $config.HOST_RAM_GB `
                    -Status "Skipped (Exists)"))
                continue
            }

            if ($PSCmdlet.ShouldProcess($hostShortName, "Import OVA and Configure Nested ESX")) {
                if ($ovfConfig.common.guestinfo.hostname) { $ovfConfig.common.guestinfo.hostname.Value = $hostShortName }
                if ($ovfConfig.common.guestinfo.ipaddress) { $ovfConfig.common.guestinfo.ipaddress.Value = $assignedIp }
                if ($ovfConfig.common.guestinfo.netmask) { $ovfConfig.common.guestinfo.netmask.Value = $subnetMask }
                if ($ovfConfig.common.guestinfo.gateway) { $ovfConfig.common.guestinfo.gateway.Value = $config.MGMT_DEFAULT_GATEWAY }
                if ($ovfConfig.common.guestinfo.dns) { $ovfConfig.common.guestinfo.dns.Value = ($config.DNS_SERVERS -join ' ') }
                if ($ovfConfig.common.guestinfo.vlan) { $ovfConfig.common.guestinfo.vlan.Value = [string]$config.MGMT_VLAN_NUMBER }
                if ($ovfConfig.common.guestinfo.domain) { $ovfConfig.common.guestinfo.domain.Value = $config.DNS_DOMAIN_NAME }
                if ($ovfConfig.common.guestinfo.ntp) { $ovfConfig.common.guestinfo.ntp.Value = ($config.NTP_SERVERS -join ' ') }
                if ($ovfConfig.common.guestinfo.password) { $ovfConfig.common.guestinfo.password.Value = $config.ESX_VM_ROOT_PASSWORD }
                if ($ovfConfig.common.guestinfo.ssh) { $ovfConfig.common.guestinfo.ssh.Value = $true }

                # Map every OVF network to the trunk port group rather than assuming a
                # specific network label (e.g. 'VM_Network') survives future OVA revisions.
                foreach ($mapping in $ovfConfig.NetworkMapping.PSObject.Properties) {
                    if ($mapping.Value) { $mapping.Value.Value = $config.TRUNK_PG_NAME }
                }

                Write-Verbose "Importing OVA for $hostShortName..."
                $vm = Import-VApp -Source $OvaPath `
                                  -Name $hostShortName `
                                  -OvfConfiguration $ovfConfig `
                                  -Location $cluster `
                                  -InventoryLocation $targetFolder `
                                  -VMHost $targetHost `
                                  -Datastore $datastore `
                                  -DiskStorageFormat Thin `
                                  -ErrorAction Stop

                # Consolidated hardware reconfiguration: vCPU, cores-per-socket, RAM,
                # nested HV, and CPU reservation in a single ReconfigVM task.
                Write-Verbose "Reconfiguring VM hardware (vCPU: $($config.HOST_CPUS), RAM: $($config.HOST_RAM_GB) GB)..."
                $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
                $spec.NumCPUs = [int]$config.HOST_CPUS
                $spec.MemoryMB = [long]([double]$config.HOST_RAM_GB * 1024)
                if ($null -ne $config.HOST_CORES_PER_CPU -and [int]$config.HOST_CORES_PER_CPU -gt 0) {
                    $spec.NumCoresPerSocket = [int]$config.HOST_CORES_PER_CPU
                }
                $spec.NestedHVEnabled = $true
                if ($null -ne $config.HOST_CPU_RESERVATION_MHZ -and [int]$config.HOST_CPU_RESERVATION_MHZ -gt 0) {
                    $spec.CpuAllocation = New-Object VMware.Vim.ResourceAllocationInfo
                    $spec.CpuAllocation.Reservation = [long]$config.HOST_CPU_RESERVATION_MHZ
                }
                $vm.ExtensionData.ReconfigVM_Task($spec) | Out-Null

                Write-Verbose "Adding $($config.DISK_COUNT) x $($config.DISK_SIZE_GB) GB capacity disks..."
                for ($d = 1; $d -le [int]$config.DISK_COUNT; $d++) {
                    New-HardDisk -VM $vm -CapacityGB $config.DISK_SIZE_GB -StorageFormat Thin -Confirm:$false | Out-Null
                }

                Write-Verbose "Configuring dual vNICs connected to '$($config.TRUNK_PG_NAME)'..."
                # NIC 1 is already mapped to the trunk port group via the OVF NetworkMapping
                # during import, so only ensure a second adapter exists on the same network.
                $existingNics = Get-NetworkAdapter -VM $vm
                if ($existingNics.Count -ge 2) {
                    Set-NetworkAdapter -NetworkAdapter $existingNics[1] -NetworkName $config.TRUNK_PG_NAME -Confirm:$false | Out-Null
                } else {
                    New-NetworkAdapter -VM $vm -NetworkName $config.TRUNK_PG_NAME -Type vmxnet3 -StartConnected -Confirm:$false | Out-Null
                }

                if ($config.POWER_ON_ESX_VMS -eq $true) {
                    Write-Host "Powering on $hostShortName..." -ForegroundColor Cyan
                    Start-VM -VM $vm -Confirm:$false | Out-Null
                }

                $deploymentResults.Add((New-HostResult -ShortName $hostShortName -Fqdn $hostFqdn `
                    -Ip $assignedIp -Vlan $config.MGMT_VLAN_NUMBER -Cpus $config.HOST_CPUS -RamGb $config.HOST_RAM_GB `
                    -Status "Deployed Successfully"))
            } else {
                $deploymentResults.Add((New-HostResult -ShortName $hostShortName -Fqdn $hostFqdn `
                    -Ip $assignedIp -Vlan $config.MGMT_VLAN_NUMBER -Cpus $config.HOST_CPUS -RamGb $config.HOST_RAM_GB `
                    -Status "WhatIf (Dry Run)"))
            }
        } catch {
            Write-Error "Failed to deploy host $hostShortName : $_"
            $deploymentResults.Add((New-HostResult -ShortName $hostShortName -Fqdn $hostFqdn `
                -Ip $assignedIp -Vlan $config.MGMT_VLAN_NUMBER -Cpus $config.HOST_CPUS -RamGb $config.HOST_RAM_GB `
                -Status "Failed: $_"))
        }
    }

    # ---------------------------------------------------------------------------
    # Output Summary & DNS Reminder
    # ---------------------------------------------------------------------------
    Write-Host "`n==========================================================================" -ForegroundColor Cyan
    Write-Host "                      DEPLOYMENT SUMMARY REPORT                          " -ForegroundColor Cyan
    Write-Host "==========================================================================" -ForegroundColor Cyan
    if ($deploymentResults.Count -gt 0) {
        $deploymentResults | Format-Table -AutoSize
    }

    Write-Host "==========================================================================" -ForegroundColor Yellow
    Write-Host "       CRITICAL REQUIREMENT: DNS RECORD VERIFICATION CHECKLIST           " -ForegroundColor Yellow
    Write-Host "==========================================================================" -ForegroundColor Yellow
    Write-Host "BEFORE powering on or joining these hosts to VCF, ensure both Forward (A)" -ForegroundColor Yellow
    Write-Host "and Reverse (PTR) DNS entries exist on domain '$($config.DNS_DOMAIN_NAME)':" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------------------" -ForegroundColor Yellow

    if ($deploymentResults.Count -gt 0) {
        $dnsChecklist = $deploymentResults | Select-Object -Property `
            @{N = 'Host FQDN'; E = { $_.FQDN } },
            @{N = 'Assigned IP'; E = { $_.IPAddress } },
            @{N = 'Subnet Mask'; E = { $subnetMask } },
            @{N = 'VLAN Tag'; E = { $_.VLAN } }
        $dnsChecklist | Format-Table -AutoSize
    }

    Write-Host "==========================================================================" -ForegroundColor Yellow
} finally {
    if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
        Write-Host "`nDisconnecting from vCenter '$($config.HOSTING_VCENTER_FQDN)'..." -ForegroundColor Cyan
        Disconnect-VIServer -Server $config.HOSTING_VCENTER_FQDN -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
}