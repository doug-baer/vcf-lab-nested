$DomainName = "ire.set.lab"
$FolderName = "vcf9"
$EnvironmentName = $FolderName
$ESXiPassword = 'VMware@123!'
$VLAN = 400
$TrunkPortName = 'vcf9-vlans400-407' #a trunk port group containing VLAN 400
$ManagementVC = 'chi-m03-vc02.set.lab'
$ManagementUser = 'administrator@vsphere.local'
$ManagementPassword = 'VMware@123!'
$VMName = "" #initialize to blank prevents copy/paste issues
$iterationList = (11,12,13,14)
#$iterationList = (11)


foreach ( $iteration in $iterationList ) {
    if ( $iteration -lt 10 ) {
        $it = "0$iteration"
    } else {
        $it = "$iteration"
    }
    $VMName = $EnvironmentName + "-esx" + $it #ensure the VM name references its environment
    $ESXiFQDN = "esx" + $it + '.' + $DomainName

    $management = Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $ManagementPassword
    $VmToolsStatus = (Get-VM $VMName | Get-View).Guest.ToolsStatus
    Disconnect-ViServer $management -Confirm:$false

    if ( ($VmToolsStatus -eq 'toolsOk') -and (Test-Connection -TcpPort 80 -IPv4 $ESXiFQDN -ResolveDestination) ) {
        #Connect to the ESXi OS within the VM and change its VLAN configuration
        $esxHost = Connect-ViServer -Server $ESXiFQDN -username 'root' -password $ESXiPassword
        Get-VirtualPortGroup -Name "VM Network" | Set-VirtualPortGroup -vlanId $VLAN
        #Doing this will make the host inaccessible over the network
        Get-VirtualPortGroup -Name "Management Network" | Set-VirtualPortGroup -vlanId $VLAN -ErrorAction Ignore
        Disconnect-ViServer $esxHost -Force -Confirm:$false
    
        #Connect to the hosting vCenter for the VM and move its NICs to the trunk port
        $management = Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $ManagementPassword
        $MyFolder = Get-Folder -Name $FolderName # to make sure we change the correct VM
        Get-VM $VMName -Location $MyFolder | Get-NetworkAdapter | Set-Networkadapter -NetworkName $TrunkPortName -Confirm:$false
        Disconnect-ViServer $management -Confirm:$false
    
        #A check to make sure it is reachable after the changes
        if ("Success" -in (Test-Connection -ping -count 5 -IPv4 $ESXiFQDN -ResolveDestination).Status) { 
            Write-Host "All done for $VMName"
        } else {
            Write-Host "$VMName not currently reachable. You may need to check the console and the trunk configuration."    
        }
    } else {
        Write-Host "VM tools not ready or $VMName not all the way up yet. No changes made."
    }
}