#######################  QUICK CONNECTION  ######################
Import-Module "c:\ManagementStudio\ManagementStudioApi"
Connect-MSApi -ApiUrl http://localhost -ProjectId 1 -UserName "UserName" -Password "YourPassw0rd!" -Logfile "C:\ManagementStudio\ScriptLog.txt" | Out-Null
Set-MSDebugOptions -LogFile "C:\ManagementStudio\ScriptLog.txt" -WriteToFile $true -WriteToHost $true
#################################################################


<#
-----------------------------------------
    Virtual Machine App Links Compressor
-----------------------------------------

USE CASE
For environments where a User is assigned a new VM every time they log in.

PROBLEM
Each time a user logs in and gets a new VM the SCCM Connector will discover and import the App usage from that VM creating a lot (possibly millions) of redundant User-App links where the User is shown to have used the same App on 300 VMs. 

SOLUTION
This script will create single Device to represent all VMs and copy all a User’s App usage info to that one device. After copying the App usage, it will remove all the User’s VM links and associated App links. There by reducing the number of User-App-Device links by up to 75% depending on the environment. 
The User will still retain the knowledge of which Apps they used on a VM and when they last used them. 

VERSION
v0.1 - 2022-01-13

Change Log:

------------------------------------------------

USAGE

To identify which devices are Virtual Devices the Script uses the value in ScriptArgs.Arg1 as the filter criteria
There are three supported filters, Hostname, Blueprint, BpFolder. Each take a comma delimited list of values. 

ScriptArg1
Hostname – Match any Devices that contain part of the supplied value. E.g. ‘VM%’ Any Device whose hostname begins with VM
	Ex. Hostname:VMAB%, VMCD%, VMEF%;

BlueprintId – Match and devices in the list of Blueprint Ids. 
BpFolderId – Match and devices in the list of Blueprint Folder Ids. 
	Ex. BlueprintId: 1,6,3;
	Ex. BpFolderId: 2,5;


ScriptArg2 - optional
A unique name of the Device to create on the Device Grid to compress the User-App Links to

ScriptArg3 - optional
Debug / Testing switches
e.g. DontCopyLinksToVm, DontRemoveLinksFromUser, DontRemoveOrphanedDevices

#>


## Read Virtual Device Pattern match from Arg1 (required)
$vmDevicePattern = $ScriptArgs.ScriptArg1

# Uncomment to hardcode a pattern here that will override what is in $ScriptArgs.Arg1
#$vmDevicePattern = "Hostname:Win7*" #  ; BpFolderId : 1,3; BlueprintId : 11,23  " 
if([string]::IsNullOrWhiteSpace($vmDevicePattern)){ 
    Write-MSDebug -LogText "The 'Virtual Device Pattern' in Arg1 is required. e.g. 'Hostname: VTR*, *CTX*; BlueprintId : 10, 11, 12; BpFolderId: 1, 2, 3'" -ResultStatus Warning
    return
}


## Read Name of Compressor Machine to create from Arg2 (optional)
$vmDeviceName = $ScriptArgs.ScriptArg2
if([string]::IsNullOrWhiteSpace($vmDeviceName)){ $vmDeviceName = "MS-Link-Compressor-Device" }


## Read any Debug / Testing Options from Arg3 (optional)
$debugOptions = $ScriptArgs.ScriptArg3
if([string]::IsNullOrWhiteSpace($debugOptions)){ $debugOptions = "-" }

#$debugOptions = "DontCopyLinksToVm, DontRemoveLinksFromUser, DontRemoveOrphanedDevices"

$copyLinksToVm = $debugOptions -notlike "*DontCopyLinksToVm*"
$removeLinksFromUser = $debugOptions -notlike "*DontRemoveLinksFromUser*"
$removeOrphanedDevices = $debugOptions -notlike "*DontRemoveOrphanedDevices*"


## -------------------------------------------------------------------------------------------
## Script Start - Do not edit below this line
## -------------------------------------------------------------------------------------------

##------------------------------------------
## Create a Compressor VM Device record
##------------------------------------------
#region Compressor VM Device
## Get the Compressor VM Device if it doesn't exist
## Note the Hostname can be changed in the UI to something more friendly, but the AssetTag must remain the same
$compressorVm  = Get-MSDevices -All | Where-Object { $_.AssetTag -eq $vmDeviceName } | Select-Object -First 1

## Create a Compressor VM Device record
##------------------------------------------
if($null -eq $compressorVm ) {
    $compressorVm  = New-MSDevices -Hostname $vmDeviceName -AssetTag $vmDeviceName

    if($null -eq $compressorVm ) { 
        Write-MSDebug -LogText "Error: No '$($vmDeviceName)' Compressor Device found" -ResultStatus Error 
        return
    }
}
#endregion


##------------------------------------------
## Get a list of Devices that are Virtual from the Args1 search patterns
##------------------------------------------
#region Virtual Devices
$vmDeviceIds = [System.Collections.Generic.HashSet[int]]::new()

$patternTypes = $vmDevicePattern.Split(";")
foreach($pattern in $patternTypes)
{
    $sections = $pattern.Split(":")
    if($sections.Count -ne 2) { continue } ## Invalid pattern

    $filterItems = $sections[1].Split(",") | ForEach-Object { $_.Trim() }

    Write-MSDebug -LogText "Filter: $($sections[0]) - $($sections[1])"

    switch ($sections[0].Trim()) {
        "Hostname" { 
            ## Get all Devices, filter Devices and add Device Id to list of VM Devices
            $allDevices = Get-MSDevices -All | Select-Object Hostname, DeviceId
            foreach($fitler in $filterItems)
            {
                $ids = $allDevices | Where-Object { $_.Hostname -like $fitler } | Select-Object -ExpandProperty DeviceId
                $ids | ForEach-Object { $vmDeviceIds.Add($_) | Out-Null }
            }
        }

        "BlueprintId" { 
            ## Get a list of Device Ids in each Blueprint Id and add Device Id to list of VM Devices
            foreach($bpId in $filterItems)
            {
                $ids = Get-MSDevices -BlueprintId $bpId -IdsOnly
                $ids | ForEach-Object { $vmDeviceIds.Add($_) | Out-Null }
            }                   
        }

        "BpFolderId" { 
            ## Get a list of Device Ids in each Folder Id and add Device Id to list of VM Devices
            foreach($fldrId in $filterItems)
            {
                $ids = Get-MSDevices -BlueprintFolderId  $fldrId -IdsOnly
                $ids | ForEach-Object { $vmDeviceIds.Add($_) | Out-Null }
            }
        }
    }
}

if($vmDeviceIds.Count -eq 0) { 
    Write-MSDebug -LogText "No Virtual Devices found for pattern filter: $($vmDevicePattern)" -ResultStatus Error    
    return
}
Write-MSDebug -LogText "Virtual Devices Found: $($vmDeviceIds.Count)" -ResetElapsedTime
#endregion



##------------------------------------------
## Get a list of User-App links attached to the VM Devices
##------------------------------------------
#region User-App links

## DMR - User-App-Device links where the Device is Virtual and the User & App Ids are present    
$appTier = New-MSDataminingTier -Module Applications -Fields @("AppId")
$userTier = New-MSDataminingTier -Module UserMigrations -Fields @("MigrationId")

$linkRpt = Get-MSDeviceDataminingReport -DeviceIds $vmDeviceIds `
            -Fields @("DeviceId") -AdditionalTiers @($appTier, $userTier) `
            -Options @("Link_LinkId", "Link_LastUsedInfo", , "Link_StatusInfo") -HeaderFormat InternalName `
            -RemoveColumns @("Link_LastUsedDateLabel") `
            -FilterExpression "(UserMigrations_MigrationId IS NOT NULL) AND (Devices_DeviceId  IS NOT NULL) AND (Applications_AppId IS NOT NULL) AND (Link_LastUsedDate IS NOT NULL)" `
            -SortExpression "UserMigrations_MigrationId ASC, Applications_AppId ASC, Link_LastUsedDate DESC"

Write-MSDebug -LogText "Links to Virtual Devices: $($linkRpt.Status.Rows)" -ElapsedTime -ResetElapsedTime

if($linkRpt.Status.Rows -gt 0)
{
    ## Extract Links from DMR
    $copyLinksTo = @{}
    foreach($row in $linkRpt.Data.Rows)
    {
        $key = "$($row.MigrationId)-$($row.AppId)"
    
        ## Create a hash table of new links to create
        if(-not $copyLinksTo.ContainsKey($key)) 
        {        
            $copyLinksTo.Add($key, @{ DeviceId = $compressorVm.DeviceId; AppId = $row.AppId; MigrationId = $row.MigrationId; LastUsedDate = $row.LastUsedDate; }) 
        }
        else
        {
            ## If link-to-create exists already, update the LastUsedDate if newer
            if($copyLinksTo[$key].LastUsedDate -lt $row.LastUsedDate){
                $copyLinksTo[$key].LastUsedDate = $row.LastUsedDate
            }
        }    
    }
    
    Write-MSDebug -LogText "Links Compressed to : $($copyLinksTo.Count). Saving $($linkRpt.Status.Rows - $copyLinksTo.Count) Links" -ElapsedTime -ResetElapsedTime


    ## Create compressed links and remove old redundant links
    try 
    {
        ## Copy User-App Links to 'GOV-VM-Compressor' Device
        if($copyLinksToVm -eq $true -and $copyLinksTo.Values.Count -gt 0){
            Import-MSUserAppDeviceLinks -Links $copyLinksTo.Values -LinkAction Create | Out-Null
            Write-MSDebug -LogText "Links Copied to 'GOV-VM-Compressor' : $($copyLinksTo.Count)" -ElapsedTime -ResetElapsedTime
        }
        else {
            Write-MSDebug -LogText "Links Copy disabled or no links found to move, no action taken"
        }
        

        ## Remove the App links on Virtual Devices from Users
        if($removeLinksFromUser -eq $true)
        {
            ## Remove User-App-Device Links for Virtual Devices
            $linksToRemove = $linkRpt.Data.Rows | Select-Object -ExpandProperty LinkId
            Remove-MSModuleLinksByLinkdIds -LinkIds $linksToRemove -Delete | Out-Null

            Write-MSDebug -LogText "User-App-VirtualDevice links removed: $($linksToRemove.Count)" -ElapsedTime -ResetElapsedTime            
        }
        else {
            Write-MSDebug -LogText "Remove links disabled, no action taken"
        }
        
    }
    catch {
        Write-MSDebug -Exception $_
        return
    }
    finally{
        $linkRpt = $null
        $copyLinksTo = $null
    }
}
#endregion



##------------------------------------------
## Orphaned Virtual Devices.
##------------------------------------------
#region Orphaned Devices

## Remove Virtual Devices from Users where the only link is the User-Device and no Apps remain
if($removeOrphanedDevices -eq $true)
{  
    ## DMR - User-App-Device links where the Device is Virtual and the User & App Ids are present    
    $appTier = New-MSDataminingTier -Module Applications -Fields @("AppId")
    $userTier = New-MSDataminingTier -Module UserMigrations -Fields @("MigrationId")

    $linkRpt = Get-MSDeviceDataminingReport -DeviceIds $vmDeviceIds `
            -Fields @("DeviceId") -AdditionalTiers @($appTier, $userTier) `
            -Options @("Link_LinkId", "Link_LastUsedInfo", , "Link_StatusInfo") -HeaderFormat InternalName `
            -RemoveColumns @("Link_LastUsedDateLabel") `
            -FilterExpression "(UserMigrations_MigrationId IS NOT NULL) AND (Devices_DeviceId  IS NOT NULL) AND (Applications_AppId IS NULL)" `
            -SortExpression "UserMigrations_MigrationId ASC, Applications_AppId ASC, Link_LastUsedDate DESC"

    if($linkRpt.Status.Rows -gt 0)
    {
        $linksToRemove = $linkRpt.Data.Rows | Select-Object -ExpandProperty LinkId
        Remove-MSModuleLinksByLinkdIds -LinkIds $linksToRemove -Delete | Out-Null

        Write-MSDebug -LogText "Orphaned Virtual Devices removed:  $($linksToRemove.Count)" -ElapsedTime -ResetElapsedTime        
    }
    else {
        Write-MSDebug -LogText "No Orphaned Virtual Devices found to remove"
    }

}
#endregion

## Summary Report for UI
Write-MSDebug -ResultHeader "Compressor Complete" -ResultStatus Success -LogText "Check log file for details" -WriteToUI $true -WriteToFile $false