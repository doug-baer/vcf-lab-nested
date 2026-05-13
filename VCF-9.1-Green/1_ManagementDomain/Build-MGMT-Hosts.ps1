## Updated May 8, 2026 - minor tweaks

$passwordFile = "$PSScriptRoot\password_vc_admin.txt"
$vc_password = Get-Content -Path $passwordFile -Raw
Connect-VIServer -Server chi-w01-vc01.set.lab -User 'administrator@wld.local' -Password $vc_password -Force

# Define physical host, datastore, network
$ClusterName = "chi-w01"
$Datastore = "chi-w01-vsan01"
$NetworkName = "vcf9-vlan400"
$FolderName = "vcf910-blue"
$EnvironmentName = "vcf910"  # the "environment" used on the build server
$ResourcePoolName = "" # none setup for testing in mgmt domain
$MyFolder = Get-Folder -Name $FolderName
$GuestOS = "vmkernel9Guest" # Corresponds to "VMware ESXi 9.x"
$RAM_GB = 128
$RAM_GB_AUTOMATION_HOST = 192 # bigger RAM to handle VCF Automation
$CPU = 48
$CoresPerCPU = 8
$NUM_ADD_NICS = 1
$USE_VSAN_OSA = $false # not unless absolutely necessary
$CacheDiskSizeGB = 200 #only used if $USE_VSAN_OSA is True
$DataDiskSizeGB = 600 #thin provisioned
$ReservationMHz = 20000 # these hosts need CPU reservation for bringup to succeed
$webInstallHost = '10.41.0.250' # the build server with ESX bits and kickstart files
$DrsClusterGroupName = "" # an existing host group to prevent vESX VMs from running on the specific host(s)
$iterationList = (1,2,3,4,5,6)
$fireThemUp = $True #start the vESX VMs immediately after creation so they can start building

$cluster = Get-Cluster -Name $ClusterName
if ($DrsClusterGroupName -ne "") {
    $DrsClusterGroup = Get-DrsClusterGroup -Name $DrsClusterGroupName -ErrorAction SilentlyContinue
}

if ($ResourcePoolName -eq "") { 
    $ResourcePool = Get-ResourcePool -Location $cluster -Name Resources
} else {
    $ResourcePool = Get-ResourcePool -Location $cluster -Name $ResourcePoolName
}

foreach ( $iteration in $iterationList ) {
    $it = "{0:D2}" -f $iteration # make sure the ids are 2-digits
    $VMName = $EnvironmentName + "-esx" + $it #ensure the VM name references its environment
    $BootPathName = "esx" + $it #simplify the path names on the bootserver
    
    $vmExists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ( $vmExists ) { 
        Write-Host -ForegroundColor Yellow "*** VM with name $VMName already exists, skipping ***"
        continue 
    }

    #make host 6 special since Auto is not small
    if ( $iteration -eq 6 ) {
        $hostRamGB = $RAM_GB_AUTOMATION_HOST
    } else {
        $hostRamGB = $RAM_GB
    }

    # Create the virtual machine
    New-VM -Name $VMName -ResourcePool $ResourcePool -Datastore $Datastore -GuestId $GuestOS -NumCpu $CPU -CoresPerSocket $CoresPerCPU -MemoryGB $hostRamGB -Location $MyFolder | Out-Null
    # this would put it on a specific host instead of into a cluster/pool
    #New-VM -Name $VMName -VMHost $VMHost -Datastore $Datastore -GuestId $GuestOS -NumCpu $CPU -MemoryGB $RAM_GB | Out-Null

    $VM = Get-vm $VMName
    # this should be the default, but make sure since NVMe needs HW 21+
    if ($vm.HardwareVersion -ne 'vmx-22') {
        $VM | set-vm -HardwareVersion "vmx-22" -Confirm:$false
    }

    # Set EFI instead of BIOS
    $bootspec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $bootspec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
    $vm.ExtensionData.ReconfigVM($bootspec)

    # Set the initial NIC to the proper network
    Get-vm $VMName | Get-NetworkAdapter | Set-Networkadapter -NetworkName $NetworkName -Confirm:$false | Out-Null
    # Add second NIC
    for ($i = 1; $i -le $NUM_ADD_NICS; $i++) {
        Get-VM $VMName | New-NetworkAdapter -NetworkName $NetworkName -Type vmxnet3 -StartConnected | Out-Null
    }

    # Set the initial/boot disk to 40 GB
    $vm | Get-HardDisk | Set-HardDisk -CapacityGB 40 -Confirm:$false

    # Add three 100 GB disks on SCSI (will move to NVMe Controller later)
    if( $USE_VSAN_OSA ) {
        Get-VM $VMName | New-HardDisk -CapacityGB $CacheDiskSizeGB -Datastore $Datastore | New-ScsiController -Type ParaVirtual | Out-Null
    } else {
        Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore | New-ScsiController -Type ParaVirtual | Out-Null
    }
    $tempController = Get-VM $VMName | Get-ScsiController -Name "SCSI controller 1"
    Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore -Controller $tempController | Out-Null
    Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore -Controller $tempController | Out-Null

    # Enable CPU virtualization extensions for the guest OS
    $vm = Get-VM -Name $VMName
    $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $vmConfigSpec.nestedHVEnabled = $true
    $vm.ExtensionData.ReconfigVM_Task($vmConfigSpec)

    # Add the net boot properties
    # this will not put the management network onto a VLAN and that needs to be done 
    # manually after firstboot and move to a trunk port group
    $vm = Get-VM -Name $VMName
    New-AdvancedSetting -entity $vm -Type VM -Name "networkBootProtocol" -Value "httpv4" -Confirm:$false
    $bootUri = "http://$webInstallHost/boot/install/$EnvironmentName/$BootPathName/mboot.efi"
    Write-Host "Configured to pull from $bootUri via IPv4"
    New-AdvancedSetting -entity $vm -Type VM -Name "networkBootUri" -Value $bootUri -Confirm:$false

    # Adding the NVMe Controller is currently a pain since it is not natively available in PowerCLI
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
    Set-VMResourceConfiguration -Conf $conf -CpuReservationMhz $ReservationMHz -MemReservationGB $RAM_GB

    # NOTE: in the airgap environment, should add these to a VM group to prevent them from running on the GPU hust
    if( $DrsClusterGroup ) {
        Set-DrsClusterGroup -DrsClusterGroup $DrsClusterGroup -Add -VM $vm
    }
    if( $fireThemUp ) {
        Write-Host "Starting '$VMName' !!"
        Start-VM -VM $vm -RunAsync -Confirm:$false
    }
}
Write-Host "***** FINISHED *****"
Disconnect-ViServer * -Confirm:$false
