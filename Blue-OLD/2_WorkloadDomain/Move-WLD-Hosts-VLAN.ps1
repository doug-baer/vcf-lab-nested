## Script to move a vESX host from an access port to a trunk port 
## and also move its Management and VM Network portgroups onto the VLAN
$esx_passwordFile = "$PSScriptRoot\password_esx_root.txt"
$esx_password = Get-Content -Path $esx_passwordFile -Raw

$vc_passwordFile = "$PSScriptRoot\password_vc_admin.txt"
$vc_password = Get-Content -Path $vc_passwordFile -Raw

$DomainName = "ire.set.lab"
$FolderName = "vcf910-blue"
$EnvironmentName = "vcf910"
$VLAN = 400
$TrunkPortName = 'vcf9-vlans400-407' #a trunk port group containing VLAN 400
$ManagementVC = 'chi-w01-vc01.set.lab'
$ManagementUser = 'administrator@wld.local'
$VMName = "" #initialize to blank prevents copy/paste issues
$iterationList = (7,8,9,10)

### TODO: make it check for the vms existing prior to going crazy
### TODO: should probably check that trunk port exists 

foreach ( $iteration in $iterationList ) {
    $it = "{0:D2}" -f $iteration # make sure the ids are 2-digits
    $VMName = $EnvironmentName + "-esx" + $it #ensure the VM name references its environment
    $ESXiFQDN = "esx" + $it + '.' + $DomainName

    ### check for the vms prior to going crazy
    $management = Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $vc_password -Force
    $VmToolsStatus = (Get-VM $VMName | Get-View).Guest.ToolsStatus
    $vmExists = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ( -Not $vmExists ) { 
        Write-Host -ForegroundColor Yellow "*** VM with name $VMName does not exist, skipping ***"
        continue 
    }
    Disconnect-ViServer $management -Confirm:$false

    if ( ($VmToolsStatus -eq 'toolsOk') -and (Test-Connection -TcpPort 80 -IPv4 $ESXiFQDN -ResolveDestination) ) {
        #Connect to the ESXi OS within the VM and change its VLAN configuration
        $esxHost = Connect-ViServer -Server $ESXiFQDN -username 'root' -password $esx_password -Force
        Get-VirtualPortGroup -Name "VM Network" | Set-VirtualPortGroup -vlanId $VLAN
        #Doing this will make the host inaccessible over the network
        Get-VirtualPortGroup -Name "Management Network" | Set-VirtualPortGroup -vlanId $VLAN  -ErrorAction SilentlyContinue
        Disconnect-ViServer $esxHost -Force -Confirm:$false
    
        #Connect to the hosting vCenter for the VM and move its NICs to the trunk port
        $management = Connect-VIServer -Server $ManagementVC -User $ManagementUser -Password $vc_password -Force
        $MyFolder = Get-Folder -Name $FolderName # to make sure we change the correct VM
        Get-VM $VMName -Location $MyFolder | Get-NetworkAdapter | Set-Networkadapter -NetworkName $TrunkPortName -Confirm:$false
        Disconnect-ViServer $management -Confirm:$false
    
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