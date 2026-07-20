[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "Path to the configuration YAML file.")]
    [Alias("ConfigPath")] # Keeps compatibility if you happen to use the old name
    [string]$Config
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
$ConfigYaml = ConvertFrom-Yaml $YamlContent

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
    "AUTO_HOST_RAM_GB",
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

# 5. Populate individual PowerShell variables dynamically
foreach ($Param in $TargetParameters) {
    # Extract the value from the config object (default to $null if missing)
    $Value = if ($null -ne $ConfigYaml.$Param) { $ConfigYaml.$Param } else { $null }
    
    # Create the variable in the Script scope so it's usable later in the script
    Set-Variable -Name $Param -Value $Value -Scope Script
}

# 6. Loop through and print the freshly created variables
Write-Host "--------------------------------------------------------" -ForegroundColor Gray
Write-Host "  VARIABLE NAME              |  VALUE        " -ForegroundColor Yellow
Write-Host "--------------------------------------------------------" -ForegroundColor Gray

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

# --- PROOF OF WORK / EXAMPLE USE ---
# Because they are now standalone variables, you can reference them normally further down in your script:
Write-Host "Testing standalone variable access..." -ForegroundColor Cyan
Write-Host "The current environment is: $ENVIRONMENT_NAME"
Write-Host "The target cluster is: $HOSTING_CLUSTER_NAME"
$iterationList = ($($START_HOST_NUMBER)..$($END_HOST_NUMBER))
Write-Host "The iteration is: $iterationList"
Write-Host "Power on vESX VMs: $POWER_ON_ESX_VMS"