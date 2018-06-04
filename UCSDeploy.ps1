[cmdletbinding()]
param (
	[string]$UCSM,
	[string]$NTPServer = "pool.ntp.org",
	[string]$Timezone = "America/Los_Angeles (Pacific Time)",
	[string]$DNSDomain = "domain.local",
	[string]$DNSPrimary,
	[string]$DNSSecondary,
	[string]$KVMIPPoolStart,
	[string]$KVMIPPoolEnd,
	[string]$KVMIPPoolMask,
	[string]$KVMIPPoolGateway,
	[string]$ISCSIAIPPoolStart,
	[string]$ISCSIAIPPoolEnd,
	[string]$ISCSIAIPPoolMask,
	[string]$ISCSIAIPPoolGateway,
	[string]$ISCSIBIPPoolStart,
	[string]$ISCSIBIPPoolEnd,
	[string]$ISCSIBIPPoolMask,
	[string]$ISCSIBIPPoolGateway,
	[string]$VlanMgmt,
	[alias("VlanStorage")]
	[string]$VlanStorageA,
	[string]$VlanStorageB,
	[alias("VlanMigration")]
	[string]$VlanMigrationA,
	[string]$VlanMigrationB,
	[array]$VlanVm
)

function Write-Log {
	param(
		[string]$Message,
		[ValidateSet("File", "Screen", "FileAndScreen")]
		[string]$OutTo = "FileAndScreen",
		[ValidateSet("Info", "Warn", "Error", "Verb", "Debug")]
		[string]$Level = "Info",
		[ValidateSet("Black", "DarkMagenta", "DarkRed", "DarkBlue", "DarkGreen", "DarkCyan", "DarkYellow", "Red", "Blue", "Green", "Cyan", "Magenta", "Yellow", "DarkGray", "Gray", "White")]
		[String]$ForegroundColor = "White",
		[ValidateRange(1,30)]
		[int]$Indent = 0,
		[switch]$Clobber,
		[switch]$NoNewLine
	)
	
	if (!($LogPath)){
		$LogPath = "$($env:ComputerName)-$(Get-Date -f yyyyMMdd).log"
	}
	
	$msg = "{0} : {1} : {2}{3}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level.ToUpper(), ("  " * $Indent), $Message
	if ($OutTo -match "File"){
		if (($Level -ne "Verb") -or ($VerbosePreference -eq "Continue")){
			if ($Clobber){
				$msg | Out-File $LogPath -Force
			}else{
				$msg | Out-File $LogPath -Append
			}
		}
	}
	
	$msg = "{0}{1}" -f ("  " * $Indent), $Message
	if ($OutTo -match "Screen"){
		switch ($Level){
			"Info" {
				if ($NoNewLine){
					Write-Host $msg -ForegroundColor $ForegroundColor -NoNewLine
				}else{
					Write-Host $msg -ForegroundColor $ForegroundColor
				}
			}
			"Warn" {Write-Warning $msg}
			"Error" {$host.ui.WriteErrorLine($msg)}
			"Verb" {Write-Verbose $msg}
			"Debug" {Write-Debug $msg}
		}
	}
}

$LogOutTo = "Screen"

$error.Clear()
Import-Module Cisco.UCSManager -ErrorAction SilentlyContinue

if ($error){
	Write-Log "Failed to load PS module" -Level "Error" -OutTo $LogOutTo
	Write-Log $error.Exception.Message -Level "Error" -OutTo $LogOutTo
	break
}

$error.Clear()
Connect-Ucs $UCSM -Credential (Get-Credential) -ErrorAction SilentlyContinue
if ($error){
	Write-Log "Failed to connect to UCSM" -Level "Error" -OutTo $LogOutTo
	Write-Log $error.Exception.Message -Level "Error" -OutTo $LogOutTo
	break
}

#Set timezone
if ($Timezone){
	Get-UcsTimezone | Set-UcsTimezone -Timezone $Timezone -Force
}

#Set NTP Server
if ($NTPServer){
	Get-UcsTimezone | Add-UcsNtpServer -Name $NTPServer
}

#Configure jumbo frames
Set-UcsBestEffortQosClass -mtu 9216 -Force
Get-UcsQosClass bronze | Set-UcsQosClass -mtu 9216 -Adminstate enabled -Force
Get-UcsQosClass gold | Set-UcsQosClass -mtu 9216 -Adminstate enabled -Force
Get-UcsQosClass platinum | Set-UcsQosClass -mtu 9216 -Adminstate enabled -Force
Get-UcsQosClass silver | Set-UcsQosClass -mtu 9216 -Adminstate enabled -Force

#Local disk policy
Add-UcsLocalDiskConfigPolicy -name NO-DISK -descr "No Local Disks" -mode no-local-storage -protectconfig:$true
Add-UcsLocalDiskConfigPolicy -name ANY-DISK -descr "Any Disk Configuration" -mode any-configuration -protectconfig:$true
Add-UcsLocalDiskConfigPolicy -name LOCAL-RAID1 -descr "RAID1 Local Disk" -mode raid-mirrored -protectconfig:$true
Add-UcsLocalDiskConfigPolicy -name FLEX-RAID1 -descr "RAID1 FlexFlash" -FlexFlashState enable -FlexFlashRAIDReportingState enable -mode any-configuration -protectconfig:$true

#Scrub policy
Add-UcsScrubPolicy -org root -name NO-SCRUB -Desc "No scrub" -FlexFlashScrub no -DiskScrub no -BiosSettingsScrub no
Add-UcsScrubPolicy -org root -name FULL-SCRUB -Desc "Scrubs everything" -FlexFlashScrub yes -DiskScrub yes -BiosSettingsScrub yes
Add-UcsScrubPolicy -org root -name FLEX-SCRUB -Desc "Scrub FlexFlash for SD install" -FlexFlashScrub yes -DiskScrub no -BiosSettingsScrub no

#Set Chassis Discovery Policy
#Get-UcsChassisDiscoveryPolicy | Set-UcsChassisDiscoveryPolicy -Action 4-link -LinkAggregationPref port-channel -Rebalance immediate -Force

#Server Pool Policy
# Remove default server pool and create custom
Get-UcsServerPool -Name default | Remove-UcsServerPool -Force
$serverPool = Add-UcsServerPool ALL-SERVERS
Add-UcsServerPoolPolicy -Name ALL-CHASSIS -Qualifier "all-chassis" -PoolDn $serverPool.Dn

#Maintenance Policy
Add-UcsMaintenancePolicy -Name USER-ACK -UptimeDisr user-ack

#Network Control Policy
Add-UcsNetworkControlPolicy -Org root -Name ENABLE-CDP-LLDP -Cdp enabled -LldpReceive enabled -LldpTransmit enabled -MacRegisterMode all-host-vlans

#BIOS Policy
$BIOS = Add-UcsBiosPolicy -Name BIOS-ESX -RebootOnUpdate no
$BIOS | Set-UcsBiosVfQuietBoot -VpQuietBoot disabled -Force
$BIOS | Set-UcsBiosVfResumeOnACPowerLoss -VpResumeOnACPowerLoss last-state -Force
$BIOS | Set-UcsBiosVfIntelVirtualizationTechnology -VpIntelVirtualizationTechnology enabled -Force
$BIOS | Set-UcsBiosHyperThreading -VpIntelHyperThreadingTech enabled -Force
$BIOS | Set-UcsBiosEnhancedIntelSpeedStep -VpEnhancedIntelSpeedStepTech enabled -Force
$BIOS | Set-UcsBiosTurboBoost -VpIntelTurboBoostTech enabled -Force
$BIOS | Set-UcsBiosVfCoreMultiProcessing -VpCoreMultiProcessing all -Force
$BIOS | Set-UcsBiosNUMA -VpNUMAOptimized enabled -Force
$BIOS | Set-UcsBiosVfCPUHardwarePowerManagement -VpCPUHardwarePowerManagement platform-default -Force
$BIOS | Set-UcsBiosVfCPUPerformance -VpCPUPerformance enterprise -Force
$BIOS | Set-UcsBiosVfEnergyPerformanceTuning -VpPwrPerfTuning os -Force
$BIOS | Set-UcsBiosVfProcessorEnergyConfiguration -VpEnergyPerformance balanced-performance -VpPowerTechnology performance -Force
$BIOS | Set-UcsBiosVfFrequencyFloorOverride -VpFrequencyFloorOverride enabled -Force
$BIOS | Set-UcsBiosVfPSTATECoordination -VpPSTATECoordination hw-all -Force
$BIOS | Set-UcsBiosVfProcessorCState -VpProcessorCState enabled -Force
$BIOS | Set-UcsBiosVfProcessorC1E -VpProcessorC1E enabled -Force
$BIOS | Set-UcsBiosVfProcessorC3Report -VpProcessorC3Report enabled -Force
$BIOS | Set-UcsBiosVfProcessorC6Report -VpProcessorC6Report enabled -Force
$BIOS | Set-UcsBiosVfProcessorC7Report -VpProcessorC7Report enabled -Force
$BIOS | Set-UcsBiosVfPackageCStateLimit -VpPackageCStateLimit auto -Force
$BIOS | Set-UcsBiosVfDRAMClockThrottling -VpDRAMClockThrottling performance -Force
$BIOS | Set-UcsBiosLvDdrMode -VpLvDDRMode performance-mode -Force
$BIOS | Set-UcsBiosVfSelectMemoryRASConfiguration -VpSelectMemoryRASConfiguration maximum-performance -Force

#Determine VLANs
$GlobalVlans = @()
$VmVlans = @()
#VM VLANs
foreach ($vmVlan in $VlanVm){
	$vlan = "" | select Name,Id
	$vlan.Name = "VLAN-$vmVlan"
	$vlan.Id = $vmVlan
	$VmVlans += $vlan
}
$GlobalVlans += $VmVlans
#MGMT VLAN
$vlan = "" | select Name,Id
$vlan.Name = "VLAN-MGMT"
$vlan.Id = $VlanMgmt
$GlobalVlans += $vlan
#Storage A VLAN
if ($VlanStorageA){
	$vlan = "" | select Name,Id
	if ($VlanStorageB){
		$vlan.Name = "VLAN-STORAGE-A"
	}else{
		$vlan.Name = "VLAN-STORAGE"
	}
	$vlan.Id = $VlanStorageA
	$GlobalVlans += $vlan
}
#Storage B VLAN
if ($VlanStorageB){
	$vlan = "" | select Name,Id
	$vlan.Name = "VLAN-STORAGE-B"
	$vlan.Id = $VlanStorageB
	$GlobalVlans += $vlan
}
#Migration A VLAN
if ($VlanMigrationA){
	$vlan = "" | select Name,Id
	if ($VlanMigrationB){
		$vlan.Name = "VLAN-MIGRATION-A"
	}else{
		$vlan.Name = "VLAN-MIGRATION-B"
	}
	$vlan.Id = $VlanMigrationA
	$GlobalVlans += $vlan
}
#Migration B VLAN
if ($VlanMigrationB){
	$vlan = "" | select Name,Id
	$vlan.Name = "VLAN-MIGRATION-B"
	$vlan.Id = $VlanMigrationB
	$GlobalVlans += $vlan
}

#Create VLANs
foreach ($vlan in $GlobalVlans){
	Get-UcsLanCloud | Add-UcsVlan -Name $vlan.Name -Id $vlan.Id
}

Get-UcsUuidSuffixPool default | Remove-UcsUuidSuffixPool -Force
#UUID Pool
Add-UcsUuidSuffixPool UUIDPOOL-DEFAULT
Get-UcsUuidSuffixPool UUIDPOOL-DEFAULT | Add-UcsUuidSuffixBlock -From "0000-000000000001" -To "0000-000000000256"

#Get-UcsIpPool ext-mgmt | Remove-UcsIpPool -Force
#IP Pool (KVM)
Get-UcsOrg -Level root | Add-UcsIpPool -Name IPPOOL-KVM -AssignmentOrder sequential
Get-UcsIpPool IPPOOL-KVM | Add-UcsIpPoolBlock -From $KVMIPPoolStart -To $KVMIPPoolEnd -DefGw $KVMIPPoolGateway -Subnet $KVMIPPoolMask -PrimDns $DNSPrimary -SecDns $DNSSecondary

Get-UcsIpPool iscsi-initiator-pool | Remove-UcsIpPool -Force
#IP Pool (iSCSI A)
if ($ISCSIAIPPoolStart){
	Get-UcsOrg -Level root | Add-UcsIpPool -Name IPPOOL-ISCSI-A -AssignmentOrder sequential
	Get-UcsIpPool IPPOOL-ISCSI-A | Add-UcsIpPoolBlock -From $ISCSIAIPPoolStart -To $ISCSIAIPPoolEnd -Subnet $ISCSIAIPPoolMask
}

#IP Pool (iSCSI B)
if ($ISCSIBIPPoolStart){
	Get-UcsOrg -Level root | Add-UcsIpPool -Name IPPOOL-ISCSI-B -AssignmentOrder sequential
	Get-UcsIpPool IPPOOL-ISCSI-B | Add-UcsIpPoolBlock -From $ISCSIBIPPoolStart -To $ISCSIBIPPoolEnd -Subnet $ISCSIBIPPoolMask
}

#IQN Pool
if ($ISCSIAIPPoolStart){
	[array]$splitDomain = $DNSDomain.Split(".")
	[array]::Reverse($splitDomain)
	[string]$iqnDomain = $splitDomain -join "."
	Add-UcsIqnPoolPool -Name IQN-POOL -Prefix "iqn.$(Get-Date -f "yyyy-M").$iqnDomain"
	Get-UcsIqnPoolPool IQN-POOL | Add-UcsIqnPoolBlock -Suffix "server" -From 0 -To 128
}

#Need to dynamically create MAC ranges
Get-UcsMacPool -Name default | Remove-UcsMacPool -Force

#MAC Pool Fab A ESXi
Add-UcsMacPool -Name MAC-ESX-A -Descr "Fab A ESXi" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-ESX-A | Add-UcsMacMemberBlock -From "00:25:B5:A1:10:00" -To "00:25:B5:A1:10:7F"
#MAC Pool Fab B ESXi
Add-UcsMacPool -Name MAC-ESX-B -Descr "Fab B ESXi" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-ESX-B | Add-UcsMacMemberBlock -From "00:25:B5:B1:10:00" -To "00:25:B5:B1:10:7F"

#MAC Pool Fab A Hyper-V
Add-UcsMacPool -Name MAC-HV-A -Descr "Fab A Hyper-V" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-HV-A | Add-UcsMacMemberBlock -From "00:25:B5:A1:20:00" -To "00:25:B5:A1:20:7F"
#MAC Pool Fab B Hyper-V
Add-UcsMacPool -Name MAC-HV-B -Descr "Fab B Hyper-V" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-HV-B | Add-UcsMacMemberBlock -From "00:25:B5:B1:20:00" -To "00:25:B5:B1:20:7F"

#MAC Pool Fab A Windows bare metal
Add-UcsMacPool -Name MAC-WIN-A -Descr "Fab A Windows bare metal" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-WIN-A | Add-UcsMacMemberBlock -From "00:25:B5:A1:30:00" -To "00:25:B5:A1:30:7F"
#MAC Pool Fab B Windows bare metal
Add-UcsMacPool -Name MAC-WIN-B -Descr "Fab B Windows bare metal" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-WIN-B | Add-UcsMacMemberBlock -From "00:25:B5:B1:30:00" -To "00:25:B5:B1:30:7F"

#MAC Pool Fab A Linux bare metal
Add-UcsMacPool -Name MAC-LINUX-A -Descr "Fab A Linux bare metal" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-LINUX-A | Add-UcsMacMemberBlock -From "00:25:B5:A1:40:00" -To "00:25:B5:A1:40:7F"
#MAC Pool Fab B Linux bare metal
Add-UcsMacPool -Name MAC-LINUX-B -Descr "Fab B Linux bare metal" -AssignmentOrder sequential
Get-UcsMacPool -Name MAC-LINUX-B | Add-UcsMacMemberBlock -From "00:25:B5:B1:40:00" -To "00:25:B5:B1:40:7F"


#ESXi vNIC Templates
#Mgmt vNICs
$vnic = Add-UcsVnicTemplate -Name ESX-MGMT-A -TemplType updating-template -SwitchId A -Target adaptor
$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-A -NwCtrlPolicyName ENABLE-CDP-LLDP -Force
$vnic | Add-UcsVnicInterface -Name $VlanMgmt
$vnic = Add-UcsVnicTemplate -Name ESX-MGMT-B -TemplType updating-template -SwitchId B -Target adaptor
$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-B -NwCtrlPolicyName ENABLE-CDP-LLDP -Force
$vnic | Add-UcsVnicInterface -Name $VlanMgmt

#iSCSI vNICs
if ($VlanStorageA){
	$vnic = Add-UcsVnicTemplate -Name ESX-ISCSI-A -TemplType updating-template -SwitchId A -Target adaptor
	$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-A -NwCtrlPolicyName ENABLE-CDP-LLDP -Mtu 9000 -Force
	$vnic | Add-UcsVnicInterface -Name $VlanStorageA

	$vnic = Add-UcsVnicTemplate -Name ESX-ISCSI-B -TemplType updating-template -SwitchId B -Target adaptor
	$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-B -NwCtrlPolicyName ENABLE-CDP-LLDP -Mtu 9000 -Force
	if ($VlanStorageB){
		$vnic | Add-UcsVnicInterface -Name $VlanStorageB
	}else{
		$vnic | Add-UcsVnicInterface -Name $VlanStorageA
	}
}

#vMotion vNICs
if ($VlanMigrationA){
	$vnic = Add-UcsVnicTemplate -Name ESX-MIGRATION-A -TemplType updating-template -SwitchId A -Target adaptor
	$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-A -NwCtrlPolicyName ENABLE-CDP-LLDP -Mtu 9000 -Force
	$vnic | Add-UcsVnicInterface -Name $VlanMigrationA
	$vnic = Add-UcsVnicTemplate -Name ESX-MIGRATION-B -TemplType updating-template -SwitchId B -Target adaptor
	$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-B -NwCtrlPolicyName ENABLE-CDP-LLDP -Mtu 9000 -Force
	if ($VlanMigrationB){
		$vnic | Add-UcsVnicInterface -Name $VlanMigrationB
	}else{
		$vnic | Add-UcsVnicInterface -Name $VlanMigrationA
	}
}

#VM vNICs
$vnic = Add-UcsVnicTemplate -Name ESX-VM1-A -TemplType updating-template -SwitchId A -Target adaptor
$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-A -NwCtrlPolicyName ENABLE-CDP-LLDP -Force
foreach ($vlan in $VmVlans){
	$vnic | Add-UcsVnicInterface -Name $vlan.Name
}
$vnic = Add-UcsVnicTemplate -Name ESX-VM1-B -TemplType updating-template -SwitchId B -Target adaptor
$vnic | Set-UcsVnicTemplate -IdentPoolName MAC-ESX-B -NwCtrlPolicyName ENABLE-CDP-LLDP -Force
foreach ($vlan in $VmVlans){
	$vnic | Add-UcsVnicInterface -Name $vlan.Name
}

Disconnect-Ucs