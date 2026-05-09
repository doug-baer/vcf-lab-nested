<#
.SYNOPSIS
    Consolidated vESX Management Tool for Build and Move operations.
    Updated: May 8, 2026

.EXAMPLE
    .\Manage-vESX.ps1 -Build
    .\Manage-vESX.ps1 -Build -NoOsInstall
    .\Manage-vESX.ps1 -Move
#>

Param(
    [Parameter(ParameterSetName = "Build", Mandatory = $true)]
    [switch]$Build,

    # Added the NoOsInstall option here
    [Parameter(ParameterSetName = "Build")]
    [switch]$NoOsInstall,

    [Parameter(ParameterSetName = "Move", Mandatory = $true)]
    [switch]$Move
)

# --- 1. Common Configuration ---
$EnvironmentName  = "vcf910b"
$FolderName       = "vcf910-blue"
$iterationList    = (1..6)
$ManagementVC     = 'chi-w01-vc01.set.lab'
$ManagementUser   = 'administrator@wld.local'
$vc_passwordFile  = "$PSScriptRoot\password_vc_admin.txt"
$vc_password      = Get-Content -Path $vc_passwordFile -Raw

# --- 2. Build Specific Variables ---
$ClusterName      = "chi-w01"
$Datastore        = "chi-w01-vsan01"
$NetworkName      = "vcf9-vlan400"
$GuestOS          = "vmkernel9Guest"
$RAM_GB           = 128
$RAM_GB_AUTO      = 192 
$CPU              = 48
$CoresPerCPU      = 8
$DataDiskSizeGB   = 600
$ReservationMHz   = 20000
$webInstallHost   = '10.41.0.250'
$fireThemUp       = $true

# --- 3. Move Specific Variables ---
$esx_passwordFile = "$PSScriptRoot\password_esx_root.txt"
$esx_password     = Get-Content -Path $esx_passwordFile -Raw
$DomainName       = "ire.set.lab"
$VLAN             = 400
$TrunkPortName    = 'vcf9-vlans400-407'

# --- 4. Main Execution ---

Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $vc_password -Force | Out-Null
$MyFolder = Get-Folder -Name $FolderName

if ($Build) {
    Write-Host "--- STARTING BUILD MODE ---" -ForegroundColor Green
    if ($NoOsInstall) { Write-Host "[Option Enabled: Skipping OS Installation/PXE Config]" -ForegroundColor Yellow }

    $cluster = Get-Cluster -Name $ClusterName
    $ResourcePool = Get-ResourcePool -Location $cluster -Name Resources

    foreach ($iteration in $iterationList) {
        $it = "{0:D2}" -f $iteration
        $VMName = "$EnvironmentName-esx$it"
        $BootPathName = "esx$it"
        
        if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) { 
            Write-Host "*** VM $VMName already exists, skipping ***" -ForegroundColor Yellow
            continue 
        }

        $hostRam = if ($iteration -eq 6) { $RAM_GB_AUTO } else { $RAM_GB }

        Write-Host "Creating Virtual Machine: $VMName..." -ForegroundColor White
        $vm = New-VM -Name $VMName -ResourcePool $ResourcePool -Datastore $Datastore -GuestId $GuestOS -NumCpu $CPU -CoresPerSocket $CoresPerCPU -MemoryGB $hostRam -Location $MyFolder
        
        $vm | Set-VM -HardwareVersion "vmx-22" -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        $bootspec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $bootspec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
        $vm.ExtensionData.ReconfigVM($bootspec)

        $vm | Get-NetworkAdapter | Set-Networkadapter -NetworkName $NetworkName -Confirm:$false | Out-Null
        $vm | New-NetworkAdapter -NetworkName $NetworkName -Type vmxnet3 -StartConnected | Out-Null
        $vm | Get-HardDisk | Set-HardDisk -CapacityGB 40 -Confirm:$false | Out-Null
        
        $vm | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore | New-ScsiController -Type ParaVirtual | Out-Null
        #$tempController = Get-VM $VMName | Get-ScsiController | Where-Object {$_.BusNumber -eq 1}
        $tempController = Get-VM $VMName | Get-ScsiController -Name "SCSI controller 1" ## hacky, but this works!
        1..2 | ForEach-Object { Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore -Controller $tempController | Out-Null }

        # Enable Nested HV
        $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $vmConfigSpec.nestedHVEnabled = $true
        $vm.ExtensionData.ReconfigVM_Task($vmConfigSpec) | Out-Null
        
        # --- CONDITIONAL BOOT CONFIGURATION ---
        if (-not $NoOsInstall) {
            Write-Host "Configuring PXE Boot Settings for $VMName..." -ForegroundColor Gray
            $bootUri = "http://$webInstallHost/boot/install/$EnvironmentName/$BootPathName/mboot.efi"
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
        
        # Add Reservations
        $conf = Get-VMResourceConfiguration $vm
        Set-VMResourceConfiguration -Conf $conf -CpuReservationMhz $ReservationMHz -MemReservationGB $hostRam | Out-Null
        if ($fireThemUp) { 
            Start-VM -VM $vm -RunAsync -Confirm:$false | Out-Null 
        }
    }
}

if ($Move) {
    Write-Host "--- STARTING MOVE MODE ---" -ForegroundColor Green
    $targetNetwork = Get-VirtualPortGroup -Name $TrunkPortName -ErrorAction SilentlyContinue
    if (-not $targetNetwork) {
        Write-Error "CRITICAL: Trunk Port Group '$TrunkPortName' not found. Aborting."
        return
    }
    
    foreach ( $iteration in $iterationList ) {
        $it = "{0:D2}" -f $iteration # make sure the ids are 2-digits
        $VMName = $EnvironmentName + "-esx" + $it #ensure the VM name references its environment
        $ESXiFQDN = "esx" + $it + '.' + $DomainName

        ### check for the vms prior to going crazy
        #Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $vc_password -Force | Out-Null
        $VmToolsStatus = (Get-VM $VMName | Get-View).Guest.ToolsStatus
        $vmExists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
        if ( -Not $vmExists ) { 
            Write-Host -ForegroundColor Yellow "*** VM with name $VMName does not exist, skipping ***"
            continue 
        }
        Disconnect-ViServer * -Force -Confirm:$false

        if ( ($VmToolsStatus -eq 'toolsOk') -and (Test-Connection -TcpPort 80 -IPv4 $ESXiFQDN -ResolveDestination) ) {
            #Connect to the ESX OS within the VM and change its VLAN configuration
            $esxHost = Connect-ViServer -Server $ESXiFQDN -username 'root' -password $esx_password -Force
            Get-VirtualPortGroup -Name "VM Network" | Set-VirtualPortGroup -vlanId $VLAN
            #Doing this will make the host inaccessible over the network
            Get-VirtualPortGroup -Name "Management Network" | Set-VirtualPortGroup -vlanId $VLAN  -ErrorAction SilentlyContinue
            Disconnect-ViServer $esxHost -Force -Confirm:$false
        
            #Connect to the hosting vCenter for the VM and move its NICs to the trunk port
            Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $vc_password -Force
            $MyFolder = Get-Folder -Name $FolderName # to make sure we change the correct VM
            Get-VM $VMName -Location $MyFolder | Get-NetworkAdapter | Set-Networkadapter -NetworkName $TrunkPortName -Confirm:$false
        
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