Connect-VIServer -Server chi-m03-vc02.set.lab -User 'administrator@vsphere.local' -Password 'VMware@123!'

$ClusterName = "airgapped"
$Datastore = "airgap-airgapped-vsan01"
$NetworkName = "vcf9-vlan400"
$FolderName = "vcf9"
$EnvironmentName = $FolderName
$ResourcePoolName = "db-VCF9-Beta-Sandbox"
$MyFolder = Get-Folder -Name $FolderName
$GuestOS = "vmkernel8Guest" # Corresponds to "VMware ESXi 8.0U2"
$RAM_GB = 32
$CPU = 16
$CoresPerCPU = 4
$NUM_ADD_NICS = 1
$NUM_ADD_VMDKS = 2
$DataDiskSizeGB = 200
$webInstallHost = '10.40.0.250'
$DrsClusterGroupName = 'VCF9-vESXi' # a group that prevents the VMs from running on the GPU host
$iterationList = (11,12,13,14)
$fireThemUp = $True #start the vESXi VMs immediately after creation so they can start building


$cluster = Get-Cluster -Name $ClusterName
$DrsClusterGroup = Get-DrsClusterGroup -Name $DrsClusterGroupName

if ($ResourcePoolName -eq "") { 
    $ResourcePool = Get-ResourcePool -Location $cluster -Name Resources
} else {
    $ResourcePool = Get-ResourcePool -Location $cluster -Name $ResourcePoolName
}

foreach ( $iteration in $iterationList ) {
    if ( $iteration -lt 10 ) {
        $it = "0$iteration"
    } else {
        $it = "$iteration"
    }
    $VMName = $EnvironmentName + "-esx" + $it #ensure the VM name references its environment
    $BootPathName = "esx" + $it #simplify the path names on the bootserver

    # Create the virtual machine
    New-VM -Name $VMName -ResourcePool $ResourcePool -Datastore $Datastore -GuestId $GuestOS -NumCpu $CPU -CoresPerSocket $CoresPerCPU -MemoryGB $RAM_GB -Location $MyFolder | Out-Null
    # this would put it on a specific host instead of into a cluster/pool
    #New-VM -Name $VMName -VMHost $VMHost -Datastore $Datastore -GuestId $GuestOS -NumCpu $CPU -MemoryGB $RAM_GB | Out-Null

    $VM = Get-vm $VMName
    # this should be the default, but make sure since NVMe needs HW 21
    if ($vm.HardwareVersion -ne 'vmx-21') {
        $VM | set-vm -HardwareVersion "vmx-21" -Confirm:$false
    }

    # set EFI instead of BIOS
    $bootspec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $bootspec.Firmware = [VMware.Vim.GuestOsDescriptorFirmwareType]::efi
    $vm.ExtensionData.ReconfigVM($bootspec)

    # Set the initial NIC to the proper network
    Get-vm $VMName | Get-NetworkAdapter | Set-Networkadapter -NetworkName $NetworkName -Confirm:$false | Out-Null
    # Add second NIC
    for ($i = 1; $i -le $NUM_ADD_NICS; $i++) {
        Get-VM $VMName | New-NetworkAdapter -NetworkName $NetworkName -Type vmxnet3 -StartConnected | Out-Null
    }

    # set the initial/boot disk to 40 GB
    $vm | Get-HardDisk | Set-HardDisk -CapacityGB 40 -Confirm:$false

    #add additional disks on a new SCSI controller. will move to NVMe Controller later. 
    #new controller is added with first disk and iused with subsequent disks
    Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore | New-ScsiController -Type ParaVirtual | Out-Null
    $tempController = Get-VM $VMName | Get-ScsiController -Name "SCSI controller 1"
    for ($i = 2; $i -le $NUM_ADD_VMDKS; $i++) {
        Get-VM $VMName | New-HardDisk -CapacityGB $DataDiskSizeGB -Datastore $Datastore -Controller $tempController | Out-Null
    }

    # Enable CPU virtualization extensions for the guest OS
    $vm = Get-VM -Name $VMName
    $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $vmConfigSpec.nestedHVEnabled = $true
    $vm.ExtensionData.ReconfigVM_Task($vmConfigSpec)

    #Write-Host "Adding CD drive, attaching ISO"
    #$vm = Get-VM -Name $VMName
    #$CDDrive = Get-CDDrive -VM $VM
    #if (-not $CDDrive) {
    #    New-CDDrive -VM $VM -ISOPath $ISOPath -StartConnected:$CDConnectAtPowerOn -Confirm:$false
    #}

    #Add the net boot properties -- this will not put the management network onto a VLAN and that needs to be done manually after firstboot and move to a trunk port group
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

    # NOTE: in the airgap environment, should add these to a VM group to prevent them from running on the GPU hust
    if( $fireThemUp -and $DrsClusterGroup ) {
        Set-DrsClusterGroup -DrsClusterGroup $DrsClusterGroup -Add -VM $vm
        Write-Host "Starting '$VMName' !!"
        Start-VM -VM $vm -RunAsync -Confirm:$false
    }
}

Disconnect-ViServer * -Confirm:$false
