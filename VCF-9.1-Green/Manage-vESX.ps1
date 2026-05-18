<#
.SYNOPSIS
    Consolidated vESX Management Tool for Build and Move operations.
    Updated: May 18, 2026

    Requires a YAML-based configuration file

.EXAMPLE
    .\Manage-vESX.ps1 -Config green.yaml -Build
    .\Manage-vESX.ps1 -Config blue.yaml -Build -NoOsInstall
    .\Manage-vESX.ps1 -Config yellow.yaml -Move
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the configuration YAML file.")]
    [string]$Config,

    [Parameter(ParameterSetName = "Build", Mandatory = $true)]
    [switch]$Build,

    # AA NoOsInstall option for Building the VMs but not configuring the EFI to pull the OS
    [Parameter(ParameterSetName = "Build")]
    [switch]$NoOsInstall,

    [Parameter(ParameterSetName = "Move", Mandatory = $true)]
    [switch]$Move
)

# --- 0. Ensure the powershell-yaml module is installed ---
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Host "Installing required 'powershell-yaml' module..." -ForegroundColor Cyan
    Install-Module -Name powershell-yaml -Scope CurrentUser -Force
}

# --- 1. Resolve the path to the config file---
$AbsoluteConfigPath = Resolve-Path $Config -ErrorAction SilentlyContinue

if (-not $AbsoluteConfigPath) {
    Write-Error "Configuration file not found at: $Config"
    exit
}

# --- 2. Read and parse the YAML file ---
Write-Host "Reading configuration from $AbsoluteConfigPath...`n" -ForegroundColor Green
$YamlContent = Get-Content -Raw -Path $AbsoluteConfigPath
$Config = ConvertFrom-Yaml $YamlContent

## the parameters we need from the config file
$TargetParameters = @(
    "ENVIRONMENT_NAME",
    "FOLDER_NAME",
    "DNS_DOMAIN_NAME",
    "SSO_DOMAIN_NAME",
    "START_HOST_NUMBER",
    "END_HOST_NUMBER",
    "HOST_RAM_GB",
    "HOST_CPUS",
    "HOST_CORES_PER_CPU",
    "HOST_CPU_RESERVATION_MHZ",
    "AUTO_HOST_NUM",
    "AUTO_HOST_RAM",
    "DISK_SIZE_GB",
    "MGMT_VLAN_NUMBER",
    "ACCESS_PG_NAME",
    "TRUNK_PG_NAME",
    "HTTP_INSTALL_HOST_IP",
    "HOSTING_CLUSTER_NAME",
    "HOSTING_DATASTORE_NAME",
    "HOSTING_VCENTER_FQDN",
    "HOSTING_VCENTER_USER",
    "HOSTING_VCENTER_PASSWORD",
    "ESX_VM_ROOT_PASSWORD",
    "POWER_ON_ESX_VMS"
)

# --- 3. Populate individual PowerShell variables dynamically ---
foreach ($Param in $TargetParameters) {
    # Extract the value from the config object (default to $null if missing)
    $Value = if ($null -ne $Config.$Param) { $Config.$Param } else { $null }
    
    # Create the variable in the Script scope so it's usable later in the script
    Set-Variable -Name $Param -Value $Value -Scope Script
}

foreach ($Param in $TargetParameters) {
    # Fetch the variable value by its string name
    $VariableValue = Get-Variable -Name $Param -ValueOnly -ErrorAction SilentlyContinue
    
    # Format the output cleanly
    if ($null -ne $VariableValue) {
        Write-Host "$(('$' + $Param).PadRight(28)) : $VariableValue"
    } else {
        Write-Host "$(('$' + $Param).PadRight(28)) : [NOT FOUND / NULL]" -ForegroundColor Red
    }
}

Write-Host "--------------------------------------------------------" -ForegroundColor Gray

#TODO: bail out if the variables don't get set properly -- there seems to be an oddity with Set-Variable 


# --- 4. Common or Override Configuration ---
$iterationList    = ($($START_HOST_NUMBER)..$($END_HOST_NUMBER))
$GuestOS          = "vmkernel9Guest"

# --- 5. Main Execution ---
Connect-VIServer -Server $HOSTING_VCENTER_FQDN -User $HOSTING_VCENTER_USER -Password $HOSTING_VCENTER_PASSWORD -Force | Out-Null

$MyFolder = Get-Folder -Name $FOLDER_NAME -ErrorAction SilentlyContinue

# If the folder doesn't exist, create it
if ($null -eq $MyFolder) {
    Write-Host "Folder '$FOLDER_NAME' not found. Creating it now..." -ForegroundColor Cyan
    
    # Get the root VM folder of the datacenter to place your new folder in
    $RootFolder = Get-Folder -NoRecursion | Where-Object { $_.Name -eq "vm" }
    
    if ($RootFolder) {
        $MyFolder = New-Folder -Name $FOLDER_NAME -Location $RootFolder
        Write-Host "Successfully created folder '$FOLDER_NAME'." -ForegroundColor Green
    } else {
        Write-Error "Could not locate the root VM inventory folder to create '$FOLDER_NAME'."
    }
} else {
    Write-Host "Folder '$FOLDER_NAME' already exists." -ForegroundColor Gray
}

if ($Build) {
    Write-Host "--- STARTING BUILD MODE ---" -ForegroundColor Green
    if ($NoOsInstall) { Write-Host "[Option Enabled: Skipping OS Installation/PXE Config]" -ForegroundColor Yellow }

    $cluster = Get-Cluster -Name $HOSTING_CLUSTER_NAME
    $ResourcePool = Get-ResourcePool -Location $cluster -Name Resources

    foreach ($iteration in $iterationList) {
        $it = "{0:D2}" -f $iteration
        $VMName = "$ENVIRONMENT_NAME-esx$it"
        $BootPathName = "esx$it"
        
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 
            Write-Host "*** VM $VMName already exists, skipping ***" -ForegroundColor Yellow
            continue 
        }

        $hostRam = if ($iteration -eq $AUTO_HOST_NUM) { $HOST_RAM_GB_AUTO } else { $HOST_RAM_GB }

        Write-Host "Creating Virtual Machine: $VMName..." -ForegroundColor White
        $vm = New-VM -Name $VMName -ResourcePool $ResourcePool -Datastore $HOSTING_DATASTORE_NAME -GuestId $GuestOS -NumCpu $HOST_CPUS -CoresPerSocket $HOST_CORES_PER_CPU -MemoryGB $hostRam -Location $MyFolder
        
        # in 9.1, this is default and it complains about setting it again, but we need this
        $vm | Set-VM -HardwareVersion "vmx-22" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $bootspec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $bootspec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
        $vm.ExtensionData.ReconfigVM($bootspec)

        $vm | Get-NetworkAdapter | Set-Networkadapter -NetworkName $ACCESS_PG_NAME -Confirm:$false | Out-Null
        $vm | New-NetworkAdapter -NetworkName $ACCESS_PG_NAME -Type vmxnet3 -StartConnected | Out-Null
        $vm | Get-HardDisk | Set-HardDisk -CapacityGB 40 -Confirm:$false | Out-Null
        
        $vm | New-HardDisk -CapacityGB $DISK_SIZE_GB -Datastore $HOSTING_DATASTORE_NAME | New-ScsiController -Type ParaVirtual | Out-Null
        #$tempController = Get-VM $VMName | Get-ScsiController | Where-Object {$_.BusNumber -eq 1}
        $tempController = Get-VM $VMName | Get-ScsiController -Name "SCSI controller 1" ## hacky, but this works!
        1..2 | ForEach-Object { Get-VM $VMName | New-HardDisk -CapacityGB $DISK_SIZE_GB -Datastore $HOSTING_DATASTORE_NAME -Controller $tempController | Out-Null }

        # Enable Nested HV
        $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $vmConfigSpec.nestedHVEnabled = $true
        $vm.ExtensionData.ReconfigVM_Task($vmConfigSpec) | Out-Null
        
        # --- CONDITIONAL BOOT CONFIGURATION ---
        if (-not $NoOsInstall) {
            Write-Host "Configuring PXE Boot Settings for $VMName..." -ForegroundColor Gray
            $bootUri = "http://$HTTP_INSTALL_HOST_IP/boot/install/$ENVIRONMENT_NAME/$BootPathName/mboot.efi"
            New-AdvancedSetting -Entity $vm -Name "networkBootProtocol" -Value "httpv4" -Confirm:$false -Force | Out-Null
            New-AdvancedSetting -Entity $vm -Name "networkBootUri" -Value $bootUri -Confirm:$false -Force | Out-Null
        }

        # NVMe Controller Transformation
        $vm = Get-VM -Name $VMName
        $devices = $vm.ExtensionData.Config.Hardware.Device
        $newControllerKey = -102
        # Reconfigure 1 - Add NVMe Controller & Update Disk Mapping to new controller
        $deviceChanges = @()
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        #$scsiController = $devices | Where-Object {$_.getType().Name -eq "ParaVirtualSCSIController"}
        $scsiController = $devices | Where-Object {$_.getType().Name -eq "ParaVirtualSCSIController"}  | Where-Object {$_.BusNumber -eq 1}
        $scsiControllerDisks = $scsiController.device
        $nvmeControllerAddSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $nvmeControllerAddSpec.Device = New-Object VMware.Vim.VirtualNVMEController
        $nvmeControllerAddSpec.Device.Key = $newControllerKey
        $nvmeControllerAddSpec.Device.BusNumber = 0
        $nvmeControllerAddSpec.Operation = 'add'
        $deviceChanges+=$nvmeControllerAddSpec
        foreach ($scsiControllerDisk in $scsiControllerDisks) {
            $device = $devices | Where-Object {$_.key -eq $scsiControllerDisk}
            $changeControllerSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
            $changeControllerSpec.Operation = 'edit'
            $changeControllerSpec.Device = $device
            $changeControllerSpec.Device.key = $device.key
            $changeControllerSpec.Device.unitNumber = $device.UnitNumber
            $changeControllerSpec.Device.ControllerKey = $newControllerKey
            $deviceChanges+=$changeControllerSpec
        }
        $spec.deviceChange = $deviceChanges
        $task = $vm.ExtensionData.ReconfigVM_Task($spec)
        $task1 = Get-Task -Id ("Task-$($task.value)")
        $task1 | Wait-Task | Out-Null

        # Reconfigure 2 - Remove PVSCSI Controller
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $scsiControllerRemoveSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $scsiControllerRemoveSpec.Operation = 'remove'
        $scsiControllerRemoveSpec.Device = $scsiController
        $spec.deviceChange = $scsiControllerRemoveSpec
        $task = $vm.ExtensionData.ReconfigVM_Task($spec)
        $task2 = Get-Task -Id ("Task-$($task.value)")
        $task2 | Wait-Task | Out-Null

        Write-Host "Virtual machine '$VMName' created successfully with the specified configuration."
        
        # Add Reservations -- reserving all host RAM (you cna change this later if you like)
        $conf = Get-VMResourceConfiguration $vm
        Set-VMResourceConfiguration -Conf $conf -CpuReservationMhz $HOST_CPU_RESERVATION_MHZ -MemReservationGB $hostRam | Out-Null
        if ($POWER_ON_ESX_VMS) { 
            Start-VM -VM $vm -RunAsync -Confirm:$false | Out-Null 
        }
    }
}

if ($Move) {
    Write-Host "--- STARTING MOVE MODE ---" -ForegroundColor Green
    $targetNetwork = Get-VirtualPortGroup -Name $TRUNK_PG_NAME -ErrorAction SilentlyContinue
    if (-not $targetNetwork) {
        Write-Error "CRITICAL: Trunk Port Group '$TRUNK_PG_NAME' not found. Aborting."
        return
    }
    
    foreach ( $iteration in $iterationList ) {
        $it = "{0:D2}" -f $iteration # make sure the ids are 2-digits
        $VMName = $ENVIRONMENT_NAME + "-esx" + $it #ensure the VM name references its environment
        $ESXiFQDN = "esx" + $it + '.' + $DNS_DOMAIN_NAME

        ### check for the vms prior to going crazy
        #Connect-VIServer -Server $HOSTING_VCENTER_FQDN -User $HOSTING_VCENTER_USER -Password $HOSTING_VCENTER_PASSWORD -Force | Out-Null
        $VmToolsStatus = (Get-VM $VMName | Get-View).Guest.ToolsStatus
        $vmExists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ( -Not $vmExists ) { 
            Write-Host -ForegroundColor Yellow "*** VM with name $VMName does not exist, skipping ***"
            continue 
        }
        Disconnect-ViServer * -Force -Confirm:$false

        if ( ($VmToolsStatus -eq 'toolsOk') -and (Test-Connection -TcpPort 80 -IPv4 $ESXiFQDN -ResolveDestination) ) {
            #Connect to the ESX OS within the VM and change its VLAN configuration
            $esxHost = Connect-ViServer -Server $ESXiFQDN -username 'root' -password $ESX_VM_ROOT_PASSWORD -Force
            Get-VirtualPortGroup -Name "VM Network" | Set-VirtualPortGroup -vlanId $MGMT_VLAN_NUMBER
            #Doing this will make the host inaccessible over the network
            Get-VirtualPortGroup -Name "Management Network" | Set-VirtualPortGroup -vlanId $MGMT_VLAN_NUMBER  -ErrorAction SilentlyContinue
            Disconnect-ViServer $esxHost -Force -Confirm:$false
        
            #Connect to the hosting vCenter for the VM and move its NICs to the trunk port
            Connect-VIServer -Server $HOSTING_VCENTER_FQDN -User $HOSTING_VCENTER_USER -Password $HOSTING_VCENTER_PASSWORD -Force
            $MyFolder = Get-Folder -Name $FOLDER_NAME # to make sure we change the correct VM
            Get-VM $VMName -Location $MyFolder | Get-NetworkAdapter | Set-Networkadapter -NetworkName $TRUNK_PG_NAME -Confirm:$false
        
            # A check to make sure it is reachable after the changes
            if ("Success" -in (Test-Connection -ping -count 5 -IPv4 $ESXiFQDN -ResolveDestination).Status) { 
                Write-Host -ForegroundColor Green "***** All done for $VMName *****"
            } else {
                Write-Host "$VMName not currently reachable. You may need to check the console and the trunk configuration."    
            }
        } else {
            Write-Host "VM tools not ready or $VMName not all the way up yet. No changes made."
        }
    }
}

Disconnect-VIServer * -Force -Confirm:$false
Write-Host "Finished." -ForegroundColor Cyan