using namespace System.Collections.Generic

# Date format: "YYYY-mm-dd" - Set your date range for log collection/extraction.  
[datetime]$StartDate = "2019-05-02"
[datetime]$EndDate = "2019-05-03"


# Log Source Target - LogRhythm Log Source ID #.  Grab this number from the LogRhythm console via Log Sources.  Find your log source, scroll to the right for the ID.
$LogSourceIDs = @(31, 21)

# Platform Manager - Hostname or IP Address of Platform Manager
$PlatformManager = "TAM-PM"

# Archives Source Folder
$ArchivesSourceFolder = "D:\LogRhythmArchives\Inactive"

# Source & Destination Folder - Ensure appropriate storage is available to support copying and extracting the in-scope archives
$SourceFolder = "D:\ArchiveReplay\Source"
$DestFolder = "D:\ArchiveReplay\Dest"

# Archive Utility - Retrieve this executable from the LogRhythm Community
$ArchiveUtil = "D:\ArchiveReplay\LogRhythmArchiveUtility_1.0.0\lrarchiveutil.exe"



if (!(Test-Path -Path $SourceFolder)) {
    New-Item -Path $SourceFolder -ItemType "directory" -Force
}

if (!(Test-Path -Path $DestFolder)) {
    New-Item -Path $DestFolder -ItemType "directory" -Force
} else {
    #Remove-Item -Path $DestFolder"\*" -Recurse
}


function identifySourceFolders {
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$SourcePath,

        [Parameter(Mandatory=$false,Position=1)]
        [string]$Date
    )
    # List of folder paths that contain target files in scope for Bulk Archive Extract
    $ArchiveFolders = [list[string]]::new()
    Write-Host "Begin - Inspection of Archives for Target Folders."

    # Create Regex Date match that aligns to LogRhythm Archive folder format
    if ($Date) {
        # Set the regex match criteria based on Date
        $RegexDateMatch = "^(.*\\)?$Date.*"
        
        # Leverage Get-ChildItem to identify all folders in scope based on Date or AllFolders if not specified
        $TargetFolders = Get-ChildItem -Directory $SourcePath -Recurse | Where-Object -Property Name -Match $RegexDateMatch | Select-Object -ExpandProperty FullName
    } else {
        $TargetFolders = Get-ChildItem -Directory $SourcePath -Recurse | Select-Object -ExpandProperty FullName
    }
    
    ForEach ($TargetFolder in $TargetFolders) {
        if ($ArchiveFolders -notcontains $TargetFolder) {
            Write-Host "Adding Target folder: $TargetFolder to ArchiveFolders variable."
            $ArchiveFolders.add($TargetFolder)
        }
    }
    Write-Host "Archive Folders identified: $($ArchiveFolders.count)"
    Write-Host "End - Inspection of Archives for Target Folders."

    return $ArchiveFolders
}

function identifyTargetFiles {
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$TargetFolder,

        [Parameter(Mandatory=$true,Position=1)]
        [int[]]$LogSources
    )
    $ArchiveFiles = [list[string]]::new()
    Write-Host "Begin - Inspection of Archive Folders for Target Files."

    # Create Regex Date match that aligns to LogRhythm Archive folder format
    ForEach ($LogSourceId in $LogSources) {
        $RegexFileMatch = "^.*(\\)?\d+_$($LogSourceID.ToString())_.*\.lca$"
        Write-Host "TargetFile Regex: $RegexFileMatch"

        # Leverage Get-ChildItem to identify all folders to inspect for target log source types
        $TargetFiles = Get-ChildItem -File $TargetFolder -Recurse | Where-Object -Property Name -Match $RegexFileMatch | Select-Object -ExpandProperty FullName 
        
        ForEach ($TargetFile in $TargetFiles) {
            if ($ArchiveFiles -notcontains $TargetFile) {
                $ArchiveFiles.add($TargetFile)
            }
        }
    }
    Write-Host "Archive Files identified: $($ArchiveFiles.Count)"
    Write-Host "End - Inspection of Archive Folders for Target Files."
    return $ArchiveFiles
}


function copyArchiveFiles {
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string[]]$SourceFiles,

        [Parameter(Mandatory=$true,Position=0)]
        [string]$DestinationPath,
        
        [Parameter(Mandatory=$false,Position=0)]
        [int]$MaxThreads = 4
    )

    $CopyRunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $Jobs = [list[object]]::new()
    $CopyRunspacePool.Open()

    $SB_CopyFile = {
        param($Source, $Dest)
        Copy-Item -Path $Source -Destination $Dest -Force
    }

    Write-Host "Copy Archive Files - Starting"
    # Retrieve information for each ArchiveFile
    ForEach ($SourceFile in $SourceFiles) {
        Write-Host "Archive file: $SourceFile"
        $RegexDateMatch = "^.*\\(?<date>\d{8})_.*\.lca$"
        Write-Verbose "TargetFile Regex: $RegexFileMatch"
        $RegexMatches = ([regex]::Matches($SourceFile, $RegexDateMatch))
        
        # Set the appropriate Source folder to copy the Archive file to.
        $DestinationFolder = Join-Path $DestinationPath -ChildPath $($RegexMatches[0].Groups["date"].Value)
        
        # Test if the SourceDateFolder exists.  If it does not exist, create it.
        if (!(Test-Path -Path $DestinationFolder)) {
            New-Item -Path $DestinationFolder -ItemType "directory" -Force
        }

        $ParamList = @{
            Source = $SourceFile
            Dest = $DestinationFolder
        }

        $PowerShell = [powershell]::Create()
        $PowerShell.RunspacePool = $CopyRunspacePool
        $PowerShell.AddScript($SB_CopyFile).AddParameters($ParamList) | Out-Null
        Write-Verbose "Starting background job: Copy-Item -Source $($ParamList.Source) -Destination $($ParamList.Dest))"
        $Jobs.Add($($PowerShell.BeginInvoke())) | Out-Null
    }

    while ($Jobs.IsCompleted -contains $false) {
        Write-Host "Copy Archive Files - In Progress"
        Start-Sleep 1
    }

    
    $Jobs.clear()
    Get-Runspace | where { $_.RunspaceAvailability -eq "Available" } | foreach Close
    Write-Host "Copy Archive Files - Completed"
    return $ReturnData
}




function extractArchiveFiles {
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$SourceFolder,
    
        [Parameter(Mandatory=$true,Position=1)]
        [string]$DestinationPath,
        
        [Parameter(Mandatory=$false,Position=2)]
        [int]$MaxThreads = 4,

        [Parameter(Mandatory=$false,Position=3)]
        [switch]$RetainSource
    )

    $IndexFolders = [list[string]]::new()

    $SourceFiles = Get-ChildItem -File $SourceFolder
    Write-Host "Split Archive Files - Begin"
    For($i = 0; $i -lt $SourceFiles.count; $i++) {
        $TargetIndex = $i % $MaxThreads
        $TargetPath = Join-Path $SourceFolder -ChildPath $TargetIndex

        # Test if the TargetPath/IndexFolder exists.  If it does not exist, create it.
        if (!(Test-Path -Path $TargetPath)) {
            New-Item -Path $TargetPath -ItemType "directory" -Force
        }
        $SourceFiles[$i] | Move-Item -Destination $TargetPath -Force

        if ($IndexFolders -notcontains $TargetPath) {
            $IndexFolders.Add($TargetPath.ToString())
        }
    }
    Write-Host "Split Archive Files - Completed"

    # Setup some MultiThreading
    $ExtractRunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxThreads)
    $Jobs = [list[object]]::new()
    $ExtractRunspacePool.Open()

    $SB_ExtractLca = {
        param($Source, $Dest, $PM, $Util)
        Start-Process 'cmd' -ArgumentList "/k", "$Util -S $PM -U sa -P changeme -s $Source -d $Dest -cT -Ih -mt 2"
    }

    # Begin archive extract
    Write-Host "Extract Archive Files - Begin"
    ForEach ($IndexFolder in $IndexFolders) {
        Write-Host "Processing folder: $IndexFolder"
        $ParamList = @{
            Source = $IndexFolder
            Dest = $DestinationPath
            PM = $PlatformManager
            Util = $ArchiveUtil
        }

        #$PowerShell = [powershell]::Create()
        #$PowerShell.RunspacePool = $ExtractRunspacePool
        #$PowerShell.AddScript($SB_ExtractLca).AddParameters($ParamList) | Out-Null
        #Write-Host "Starting background job: 'cmd' -ArgumentList /c $ArchiveUtil, -S $PlatformManager, -U sa, -P , -s $($ParamList.Source), -d $($ParamList.Dest), -cT"
        #$Jobs.Add($($PowerShell.BeginInvoke())) | Out-Null
        
        # Add password to this, or set to use authenticated user's auth 
        & $ArchiveUtil -S $PlatformManager -s $IndexFolder -d $DestinationPath -cT -Ih -mt 2
    }

    
    Get-Runspace | where { $_.RunspaceAvailability -eq "Available" } | foreach Close
    Write-Host "Extract Archive Files - Completed"

    if ($RetainSource) {
        # Cleanup SourceDataFolder
    }

    return $ReturnData
}





# Iterate from the StartDate through to the EndDate in incriments of 1 day
$IterateDate = $StartDate
Write-Host "StartDate: $IterateDate" 
While ($IterateDate -le $EndDate) {
    Write-Host "Current Date: $IterateDate"
    # Set source folder to extract to DestFolder
    $SourceFolders = identifySourceFolders -SourcePath $ArchivesSourceFolder -Date $($IterateDate.ToString("yyyyMMdd"))
    
    ForEach ($SourceFld in $SourceFolders) {
        $SourceFiles = identifyTargetFiles -TargetFolder $SourceFld -LogSources $LogSourceIDs

        if ($SourceFiles) {
            $CopyResults = copyArchiveFiles -SourceFiles $SourceFiles -DestinationPath $SourceFolder -MaxThreads 8            
        }
    }

    $ExtractSourceFolder = Join-Path $SourceFolder -ChildPath $($IterateDate.ToString("yyyyMMdd"))
    If ($(Test-Path -Path $ExtractSourceFolder)) {
        $ExtractResults = extractArchiveFiles -SourceFolder $ExtractSourceFolder -DestinationPath $DestFolder -MaxThreads 1
    }
    

    # Iterate StartDate to next Day
    $IterateDate = $IterateDate.AddDays(1)
}
Write-Host "EndDate: $EndDate"



<#

# SYSLOG SETUP
$SyslogSource = "10.23.45.19"
$SyslogDestServer = "10.23.45.19"
$SyslogDestPort = 514
$SyslogProtocol = "UDP"
$SyslogFacility = "User"
$SyslogSeverity = "Notice"
$SyslogRFC = "-RFC3164"

# SYSLOG Required Packages
<#
# Enable PowerShell TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Install NuGet Provider
Install-PackageProvider NuGet

# Install Module PackageManagement
Install-Module PackageManagement -Force

# Install Module PowerShellGet
Install-Module PowershellGet -Force

# Install Module Posh-SYSLOG
Install-Module -Name Posh-SYSLOG



$SourceSyslogFiles = Get-ChildItem $DestFolder -Recurse -File | Select-Object -ExpandProperty FullName 
$SourceSyslogFiles = Get-ChildItem "E:\ArchiveReplay\ZScaler\Dest\SilentDevices_Exception_usdfw24as107v-nss.mrshmc.com" -Recurse -File | Select-object -ExpandProperty FullName
# Section
# Bring in the text file data as PowerShell Objects (Support object reference)
$LogCounter = 0

ForEach ($SyslogFile in $SourceSyslogFiles) {
    $Syslogs = Get-Content -Path $SyslogFile | Select-Object -First 1
    if ($Syslogs) {
        ForEach ($Log in $Syslogs) {
            $LogCounter += 1
            Start-Sleep -Milliseconds 9
            Send-SyslogMessage -Server $SyslogDestServer -Port $SyslogDestPort -Message $Log -Transport $SyslogProtocol -Severity $SyslogSeverity -Facility $SyslogFacility -ApplicationName " " -RFC3164 -Hostname $SyslogSource
            Write-Host $Log
        } 
    } else {
        Write-Host "Unable to retrieve data from file: $SyslogFile"
    }
}
#>



# Section
# Run previous section PowerShell Objects through SyslogOutput to Destination