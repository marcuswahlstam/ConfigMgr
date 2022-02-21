<# Author: Daniel Gråhns, Nicklas Eriksson
 Date: 2021-02-11
 Purpose: Download HP Drivers to a repository and apply drivers with ConfigMgr adminservice and a custom script in the taskSequence. Check out ApplyHPIA.ps1 how to apply the drivers during oSD or IPU.

 Information: Some variabels are hardcoded, search on Hardcoded variabels and you will find those. 

 Version: 1.8
 Changelog: 1.0 - 2021-02-11 - Nicklas Eriksson -  Script Edited and fixed Daniels crappy hack and slash code :)
            1.1 - 2021-02-18 - Nicklas Eriksson - Added HPIA to download to HPIA Download instead to Root Directory, Added BIOSPwd should be copy to HPIA so BIOS upgrades can be run during OSD. 
            1.2 - 2021-04-14 - Daniel Gråhns - Added check if Offline folder is created
            1.3 - 2021-04-27 - Nicklas Eriksson - Completed the function so the script also downloaded BIOS updates during sync.
            1.4 - 2021-05-21 - Nicklas Eriksson & Daniel Gråhns - Changed the logic for how to check if the latest HPIA is downloaded or not since HP changed the how the set the name for HPIA.
            1.5 - 2021-06-10 - Nicklas Eriksson - Added check to see that folder path exists in ConfigMgr otherwise creat the folder path.
            1.6 - 2021-06-17 - Nicklas Eriksson - Added -Quiet to Invoke-RepositorySync, added max log size so the log file will rollover.
            1.7 - 2021-06-18 - Nicklas Eriksson & Daniel Gråhns - Added if it's the first time the model is running skip filewatch.
            1.8 - 2022-02-09 - Modified by Marcus Wahlstam, Advitum AB <marcus.wahlstam@advitum.se>
                                - Fancier console output (see Print function)
                                - Updated Config XML with more correct settings names
                                - Removed unused code
                                - Windows 11 support
                                - Changed folder structure of the repository, both disk level and in CM (to support both Windows 10 and 11 and to make repository cleaner)
                                - Added migration check - will migrate old structure to the new structure (both disk level and CM)
                                - Changed how repository filters are handled in the script
                                - Added function to check if module is updated or not before trying to update it
                                - Fixed broken check if HPIA was updated or not (will now check value of FileVersionInfo.FileVersion on HPImageassistant.exe)
                                - Changed csv format of supported models, added column "OSVersion" (set to Win10 or Win11)
                                - Changed format of package name to include OSVersion (Win10 or Win11)
                                - Offline cache folder is now checked 10 times if it exists (while loop)
                                - Added progress bar to show which model is currently processed and how many there are left
 
 TO-Do
 - Maybe add support for Software.

How to run HPIA:
- ImportHPIA.ps1 -Config .\config.xml

Credit, inspiration and copy/paste code from: garytown.com, dotnet-helpers.com, ConfigMgr.com, www.imab.dk, Ryan Engstrom
#>

[CmdletBinding()]
param(
    [Parameter(HelpMessage='Path to XML Configuration File')]
    [string]$Config
)

#$Config = "E:\Scripts\ImportHPIA\Config_TestRef.xml" #(.\ImportHPIA.ps1 -config .\config.xml) # Only used for debug purpose, it's better to run the script from script line.
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function Print
{
    param(
    [Parameter(Mandatory=$true)]
    [string]$Message,
    [Parameter(Mandatory=$false)]
    [string]$Color = "White",
    [Parameter(Mandatory=$false)]
    [int]$Indent
    )

    switch ($Indent)
    {
        1 {$Prefix = "  "}
        2 {$Prefix = "     "}
        3 {$Prefix = "        "}
        4 {$Prefix = "           "}
        5 {$Prefix = "             "}
        6 {$Prefix = "               "}
        default {$Prefix = " "}
    }

    $DateTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$DateTime - $Prefix$Message" -ForegroundColor $Color 
}

function Log {
    Param (
    [Parameter(Mandatory=$false)]
    $Message,
    [Parameter(Mandatory=$false)]
    $ErrorMessage,
    [Parameter(Mandatory=$false)]
    $Component,

    [Parameter(Mandatory=$false)]
    [int]$Type,
                                                          
    [Parameter(Mandatory=$true)]
    $LogFile
                             )
<#
Type: 1 = Normal, 2 = Warning (yellow), 3 = Error (red)
#>
    $Time = Get-Date -Format "HH:mm:ss.ffffff"
    $Date = Get-Date -Format "MM-dd-yyyy"
    if ($ErrorMessage -ne $null) {$Type = 3}
    if ($Component -eq $null) {$Component = " "}
    if ($Type -eq $null) {$Type = 1}
    $LogMessage = "<![LOG[$Message $ErrorMessage" + "]LOG]!><time=`"$Time`" date=`"$Date`" component=`"$Component`" context=`"`" type=`"$Type`" thread=`"`" file=`"`">"
    $LogMessage | Out-File -Append -Encoding UTF8 -FilePath $LogFile
}


function ModuleUpdateAvailable($Module)
{
    [version]$OnlineVersion = (Find-Module $Module).Version
    [version]$InstalledVersion = (Get-Module -ListAvailable | where {$_.Name -eq "$Module"} -ErrorAction Ignore | sort Version -Descending).Version | select -First 1

    if ($OnlineVersion -le $InstalledVersion)
    {
        return $false
    }
    else
    {
        return $true
    }
}

Print -Message "######################################" -Color Cyan
Print -Message "### MASHPIA - Starting Import-HPIA ###" -Color Cyan
Print -Message "######################################" -Color Cyan

Print -Message "Initializing script" -Color Magenta

if (Test-Path -Path $Config) {
 
    $Xml = [xml](Get-Content -Path $Config -Encoding UTF8)
    Print -Message "Successfully loaded config file: $Config" -Indent 1 -Color Green
    #Write-Host "Info: Successfully loaded $Config" -ForegroundColor Magenta

 }
 else {
    
    $ErrorMessage = $_.Exception.Message
    #Write-Host "Info: Error, could not read $Config" -ForegroundColor Red
    Print -Message "Could not find config file: $Config" -Indent 1 -Color Red
    Print -Message "Error: $ErrorMessage" -Indent 1 -Color Red
    #Write-Host "Info: Error message: $ErrorMessage" -ForegroundColor Red
    Exit 1

 }
 

# Getting information from Config File
$InstallPath = $Xml.Configuration.Install | Where-Object {$_.Name -like 'InstallPath'} | Select-Object -ExpandProperty "Value"
$XMLInstallHPIA = $Xml.Configuration.Install | Where-Object {$_.Name -like 'InstallHPIA'} | Select-Object 'Enabled','Value'
$SiteCode = $Xml.Configuration.Setting | Where-Object {$_.Name -like 'SiteCode'} | Select-Object -ExpandProperty 'Value'
$CMFolderPath = $Xml.Configuration.Setting | Where-Object {$_.Name -like 'CMFolderPath'} | Select-Object -ExpandProperty 'Value'
$ConfigMgrModule = $Xml.Configuration.Install | Where-Object {$_.Name -like 'ConfigMgrModule'} | Select-Object -ExpandProperty 'Value'
$InstallHPCML = $Xml.Configuration.Option | Where-Object {$_.Name -like 'InstallHPCML'} | Select-Object -ExpandProperty 'Enabled'
$RepositoryPath = $Xml.Configuration.Install | Where-Object {$_.Name -like 'RepositoryPath'} | Select-Object -ExpandProperty 'Value'
$SupportedModelsCSV = $Xml.Configuration.Install | Where-Object {$_.Name -like 'SupportComputerModels'} | Select-Object -ExpandProperty 'Value'
$HPIAFilter_Dock = $Xml.Configuration.HPIAFilter | Where-Object {$_.Name -like 'Dock'} | Select-Object -ExpandProperty 'Enabled'
$HPIAFilter_Driver = $Xml.Configuration.HPIAFilter | Where-Object {$_.Name -like 'Driver'} | Select-Object -ExpandProperty 'Enabled'
$HPIAFilter_Firmware = $Xml.Configuration.HPIAFilter | Where-Object {$_.Name -like 'Firmware'} | Select-Object -ExpandProperty 'Enabled'
$HPIAFilter_Driverpack = $Xml.Configuration.HPIAFilter | Where-Object {$_.Name -like 'Driverpack'} | Select-Object -ExpandProperty 'Enabled'
$HPIAFilter_BIOS = $Xml.Configuration.HPIAFilter | Where-Object {$_.Name -like 'BIOS'} | Select-Object -ExpandProperty 'Enabled'
$DPGroupName = $Xml.Configuration.Setting | Where-Object {$_.Name -like 'DPGroupName'} | Select-Object -ExpandProperty 'Value'
$XMLEnableSMTP = $Xml.Configuration.Option | Where-Object {$_.Name -like 'EnableSMTP'} | Select-Object 'Enabled','SMTP',"Adress"
#$XMLLogfile = $Xml.Configuration.Option | Where-Object {$_.Name -like 'Logfile'} | Select-Object -ExpandProperty 'Value'

# Hardcoded variabels in the script.
$ScriptVersion = "1.8"
#$OS = "Win10" #OS do not change this.
$LogFile = "$InstallPath\RepositoryUpdate.log" #Filename for the logfile.
[int]$MaxLogSize = 9999999


#If the log file exists and is larger then the maximum then roll it over with with an move function, the old log file name will be .lo_ after.
If (Test-path  $LogFile -PathType Leaf) {
    If ((Get-Item $LogFile).length -gt $MaxLogSize){
        Move-Item -Force $LogFile ($LogFile -replace ".$","_")
        Log -Message "The old log file is too big, renaming it and creating a new logfile" -LogFile $Logfile

    }
}


Log  -Message  "<--------------------------------------------------------------------------------------------------------------------->"  -type 2 -LogFile $LogFile
Log -Message "Successfully loaded ConfigFile from $Config" -LogFile $Logfile
Log -Message "Script was started with version: $($ScriptVersion)" -type 1 -LogFile $LogFile

# Check if there is anything to migrate from old to new structure with support for Windows 11
$NewFolderStructureTest = Get-ChildItem $RepositoryPath | where {$_.Name -eq "Win10" -or $_.Name -eq "Win11"}
$OldFolderNames = "1909","2004","20H1","2009","20H2","21H1","21H2"
$OldFolderTest = Get-ChildItem $RepositoryPath | where {$_.Name -in $OldFolderNames}

if (([string]::IsNullOrEmpty($NewFolderStructureTest)) -and (-not [string]::IsNullOrEmpty($OldFolderTest)))
{
    Print -Message "New folder structure does not exist, need to migrate and rename packages to new structure" -Color Yellow -Indent 1
    Import-Module $ConfigMgrModule
    #Set-location "$($SiteCode):\"
    Set-Location $InstallPath

    # Moving repository to new structure, assuming old is Windows 10
    Print -Message "Assuming old folder structure is for Windows 10, creating Win10 subfolder in $RepositoryPath" -Color Green -Indent 2
    $OldFolders = Get-ChildItem $RepositoryPath
    $NewWin10Folder = New-Item $(Join-Path $RepositoryPath "Win10") -ItemType Directory
    
    foreach ($OldFolder in $OldFolders)
    {
        Print -Message "Working on $($OldFolder.FullName)" -Color Green -Indent 3
        Set-Location $RepositoryPath
        Print -Message "Moving $($OldFolder.FullName) to $($NewWin10Folder.FullName)" -Color Green -Indent 4
        Move-Item $OldFolder $NewWin10Folder -Force

        # ConfigMgr changes
        Print -Message "Creating new package root folder in ConfigMgr" -Color Green -Indent 4
        Set-location "$($SiteCode):\"
        $NewCMRootPath = New-Item -ItemType Directory "$CMfolderPath\Win10"
        $NewCMParentPath = New-Item -ItemType Directory "$CMfolderPath\Win10\$($OldFolder.Name)"
        $NewCMParentPath = "$CMfolderPath\Win10\$($OldFolder.Name)"
        Set-Location $InstallPath
        Set-Location $RepositoryPath

        $SourcePackages = Get-ChildItem $(Join-Path $NewWin10Folder $OldFolder)

        foreach ($SourcePackage in $SourcePackages)
        {
            $SourcePackageName = $SourcePackage.Name
            Print -Message "Working on ($($SourcePackage.Name))" -Color Green -Indent 5

            Set-location "$($SiteCode):\"
            $CMPackage = Get-CMPackage -Name "*$SourcePackageName" -Fast
            

            if (-not ([string]::IsNullOrEmpty($CMPackage)))
            {
                Print -Message "Setting new sourcepath ($($SourcePackage.FullName)) in ConfigMgr for package $($CMPackage.Name)" -Color Green -Indent 6
                Set-CMPackage -Name $($CMPackage.Name) -Path $($SourcePackage.FullName)
                
                $NewCMPackageName = $($CMPackage.Name) -replace 'HPIA-','HPIA-Win10-'
                Print -Message "Renaming package $($CMPackage.Name) to $NewCMPackageName" -Color Green -Indent 6
                Set-CMPackage -Name $($CMPackage.Name) -NewName $NewCMPackageName

                Print -Message "Moving package $NewCMPackageName to $NewCMParentPath" -Color Green -Indent 6
                Move-CMObject -FolderPath $NewCMParentPath -InputObject $CMPackage
            }
            else
            {
                # Could not find CMPackage based on folder name
                Print -Message "Could not find package based on folder name ($SourcePackageName)" -Color Red -Indent 4
            }
        }
    }

    Print -Message "Done migrating packages" -Color Green -Indent 1
}
else
{
    # New folder structure in place
}

# CHeck if HPCMSL should autoupdate from Powershell gallery if's specified in the config.
if ($InstallHPCML -eq "True")
{
        Log -Message "HPCML was enabled to autoinstall in ConfigFile, starting to install HPCML" -type 1 -LogFile $LogFile
        #Write-host "Info: HPCML was enbabled to autoinstall in ConfigFile, starting to install HPCML"
        Print -Message "Installation of HPCML was enabled in config. Installing HPCML" -Indent 1 -Color Green
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 # Force Powershell to use TLS1.2
        # make sure Package NuGet is up to date 
        Print -Message "Checking if there's a new version of PowerShellGet module" -Indent 1
        if (ModuleUpdateAvailable -Module "PowerShellGet")
        {
            Print -Message "New version of PowerShellGet module found, installing" -Indent 2
            Install-Module -Name PowerShellGet -Force -Scope AllUsers
        }
        else
        {
            Print -Message "No newer version of PowerShellGet module found, importing module" -Indent 2
            Import-Module PowerShellGet
        }

        Print -Message "Checking if there's a new version of HPCMSL module" -Indent 1
        if (ModuleUpdateAvailable -Module "HPCMSL")
        {
            Print -Message "New version of HPCMSL module found, installing" -Indent 2
            Install-Module -Name HPCMSL -Force -AcceptLicense -Scope AllUsers
        }
        else
        {
            Print -Message "No newer version of HPCMSL module found, importing module" -Indent 2
            Import-Module HPCMSL
        }
        #Install-Module -Name PowerShellGet -Force # install the latest version of PowerSHellGet module
        #Install-Module -Name HPCMSL -Force -AcceptLicense 
        Log -Message "HPCML was successfully updated" -type 1 -LogFile $LogFile -Component HPIA
        #Write-host "Info: HPCML was successfully updated"

}
else
{
    Log -Message "HPCML was not enabled to autoinstall from Powershell Gallery in ConfigFile" -type 1 -LogFile $LogFile -Component HPIA
    Print -Message "Installation/update of HPCML was disabled in config. Skipping." -Indent 1 -Color Green
}

Print -Message "Checking HPIA Prereqs" -Color Magenta

# Check if HPIA Installer was updated and create download folder for HPIA. With this folder we control if any new versions of HPIA is downloaded.
if ((Test-path -Path "$($XMLInstallHPIA.Value)\HPIA Download") -eq $false)
{
    Log -Message "HPIA Download folder does not exists" -type 1 -LogFile $LogFile -Component HPIA
    Log -Message "Creating HPIA Download folder" -type 1 -LogFile $LogFile -Component HPIA

    #Write-host "Info: HPIA Download folder does not exists"
    #Write-host "Info: Creating HPIA Download folder" -ForegroundColor Green
    Print -Message "HPIA Download folder does not exist, creating it." -Color Green -Indent 1
    New-Item -ItemType Directory -Path "$($XMLInstallHPIA.Value)\HPIA Download" -ErrorAction Stop
    Print -Message "Creating information file" -Color Green -Indent 1
    New-Item -ItemType File -Path "$($XMLInstallHPIA.Value)\HPIA Download\Dont Delete the latest SP-file.txt" -ErrorAction Stop
    #Write-host "Info: Creating file, dont delete the latest SP-file.txt" -ForegroundColor Green
    Log -Message "Creating file, dont delete the latest SP-file.txt" -type 1 -LogFile $LogFile -Component HPIA

}
else
{
    Log -Message "HPIA Download folder exists, no need to create folder" -type 1 -LogFile $LogFile -Component HPIA
    #Write-host "Info: HPIA Download folder exists, no need to create folder"
    Print -Message "HPIA Download folder exists. Skipping." -Color Green -Indent 1
}

Print -Message "Processing HPIA Tasks" -Color Magenta
#$CurrentHPIAVersion = Get-ChildItem -path "$($XMLInstallHPIA.Value)\HPIA Download" -Name *.EXE -ErrorAction SilentlyContinue | sort LastWriteTime -Descending | select -First 1
[version]$CurrentHPIAVersion = (Get-Command "$($XMLInstallHPIA.Value)\HPIA Base\HPImageAssistant.exe").FileVersionInfo.FileVersion
#Print -Message "Currently downloaded HPIA Version: $($CurrentHPIAVersion.ToString())" -Color Green -Indent 1

Print -Message "Updating HPIA Files" -Color Green -Indent 1
# CHeck if HPIA should autoupdate from HP if's specified in the config.
if ($XMLInstallHPIA.Enabled -eq "True")
{
        Log -Message "HPIA was enabled to autoinstall in ConfigFile, starting to autoupdate HPIA" -type 1 -LogFile $LogFile -Component HPIA
        #Write-host "Info: HPIA was enbabled to autoinstall in ConfigFile, starting to autoupdate HPIA"
        Print -Message "Running HPIA Install" -Color Green -Indent 2
        Set-location -Path "$($XMLInstallHPIA.Value)\HPIA Download"
        try
        {
            Install-HPImageAssistant -Extract -DestinationPath "$($XMLInstallHPIA.Value)\HPIA Base" -ErrorAction Stop
            Set-Location -path $InstallPath
            Log -Message "HPIA was successfully updated in $($XMLInstallHPIA.Value)\HPIA Base" -type 1 -LogFile $LogFile -Component HPIA
            #Write-host "Info: HPIA was successfully updated in $($XMLInstallHPIA.Value)\HPIA Base"
            Print -Message "HPIA was successfully updated in $($XMLInstallHPIA.Value)\HPIA Base" -Color Green -Indent 2
        }
        catch
        {
            Print -Message "Error: HPIA could not be updated" -Color Red -Indent 2
        }
        
        
}
else
{
    Print -Message "HPIA update is disabled in config" -Color Green -Indent 2
    Log -Message "HPIA was not enabled to autoinstall in ConfigFile" -type 1 -LogFile $LogFile
    
}

Print -Message "Processing BIOS password file" -Color Green -Indent 1
# Copy BIOS PWD to HPIA. 
$BIOS = (Get-ChildItem -Path "$($XMLInstallHPIA.Value)\*.bin" | sort LastWriteTime -Descending | select -First 1) # Check for any Password.BIN file. 

if (-not ([string]::IsNullOrEmpty($BIOS)))
{
    if (Test-Path $BIOS.FullName)
    {
        Print -Message "Found BIOS password file: $($BIOS.Fullname)" -Color Green -Indent 2
        if (-not (Test-Path -Path "$($XMLInstallHPIA.Value)\HPIA Base\$($BIOS.Name)")) {
            #Write-Host "Info: BIOS File does not exists, need to copy file to HPIA"
            Print -Message "BIOS Password file not found in $($XMLInstallHPIA.Value)\HPIA Base, copying." -Color Green -Indent 2
            Log -Message "BIOS File does not exists, need to copy file to HPIA" -type 1 -LogFile $LogFile -Component HPIA
            Copy-Item -Path $BIOS -Destination "$($XMLInstallHPIA.Value)\HPIA Base"
        } 
        else {
            #Write-host "Info: BIOS File exists in HPIA or does not exits in root, no need to copy"
            Log -Message "BIOS File exists in HPIA or does not exits in root, no need to copy" -type 1 -LogFile $LogFile -Component HPIA
            Print -Message "BIOS File exists in HPIA, no need to copy" -Color Green -Indent 2
        }
    }
}

# If HPIA Installer was not updated, set false flag value
#$NewHPIAVersion = Get-ChildItem "$($XMLInstallHPIA.Value)\HPIA Download" -Name SP*.* -ErrorAction SilentlyContinue | select -last 1
#$NewHPIAVersion = (Get-ChildItem -path "$($XMLInstallHPIA.Value)\HPIA Download" -Name *.EXE -ErrorAction SilentlyContinue | sort LastWriteTime -Descending | select -First 1).LastWriteTime
[version]$NewHPIAVersion = (Get-Command "$($XMLInstallHPIA.Value)\HPIA Base\HPImageAssistant.exe").FileVersionInfo.FileVersion
#Print -Message "Newly downloaded HPIA Version: $($NewHPIAVersion.ToString())" -Color Green -Indent 1

Print -Message "Checking if HPIA was updated" -Color Green -Indent 1

if($CurrentHPIAVersion -le $NewHPIAVersion) {
    $HPIAVersionUpdated = $false
    #Write-host "Info: HPIA was not updated, skipping to set HPIA to copy to driverpackages"
    Print -Message "HPIA was not updated, will not copy HPIA to existing driverpackages" -Color Green -Indent 2
    Log -Message "HPIA was not updated, skipping to set HPIA to copy to driverpackages" -type 1 -LogFile $LogFile -Component HPIA
} 
else {
    $HPIAVersionUpdated = $true
    #Write-host "Info: HPIA was updated, will update in each driverpackage"
    Print -Message "HPIA was updated, will copy HPIA to existing driverpackages" -Color Green -Indent 2
    Log -Message "HPIA was updated will update HPIA in each Driverpackage" -type 1 -LogFile $LogFile -Component HPIA
    }

<#
Print -Message "Setting repository filters" -Color Green -Indent 1

# Check if Category1 is enabled in the config.
if ($HPIAFilter_Dock -eq "True") {
    $Category1 = "dock"
    Log -Message "Added dock drivers for download" -type 1 -LogFile $LogFile -Component HPIA
}
else {
        Log -Message "Not enabled to download dock in ConfigFile" -type 2 -LogFile $LogFile -Component HPIA
}

# Check if Category2 is enabled in the config.
if ($HPIAFilter_Driver -eq "True") {
    $Category2 = "driver"
    Log -Message "Added drivers for download" -type 1 -LogFile $LogFile -Component HPIA
}
else {
        Log -Message "Not Enabled to download drivers in ConfigFile" -type 2 -LogFile $LogFile -Component HPIA
}

# Check if Category3 is enabled in the config.
if ($HPIAFilter_Firmware -eq "True") {
    $Category3 = "firmware"
    Log -Message "Added firmware for download" -type 1 -LogFile $LogFile -Component HPIA
}
else {
        Log -Message "Not Enabled to download firmware in ConfigFile" -type 1 -LogFile $LogFile -Component HPIA
}

# Check if Category4 is enabled in the config.
if ($HPIAFilter_Driverpack -eq "True") {
    $Category4 = "driverpack"
    Log -Message "Added driverpacks for download" -type 1 -LogFile $LogFile

}
else {
        Log -Message "Not Enabled to download Driverpack in ConfigFile" -type 1 -LogFile $LogFile -Component HPIA
}

# Check if Category5 is enabled in the config.
if ($HPIAFilter_BIOS -eq "True") {
    $Category5 = "Bios"
    Log -Message "Added BIOS for download" -type 1 -LogFile $LogFile -Component HPIA

}
else {
    Log -Message "Not Enabled to download BIOS in ConfigFile" -type 1 -LogFile $LogFile -Component HPIA
}

Print -Message "Done setting repository filters" -Color Green -Indent 2

#>

# Check if Email notificaiton is enabled in the config.
if ($XMLEnableSMTP.Enabled -eq "True") {
    $SMTP = $($XMLEnableSMTP.SMTP)
    $EMAIL = $($XMLEnableSMTP.Adress)
    Log -Message "Added SMTP: $SMTP and EMAIL: $EMAIL" -type 1 -LogFile $LogFile -Component HPIA
} 
else {
    Log -Message "Email notification is not enabled in the Config" -type 1 -LogFile $LogFile -Component HPIA
}

Print -Message "Processing models and drivers" -Color Magenta

Print -Message "Importing CSV with supported models" -Color Green -Indent 1

#Importing supported computer models CSV file
if (Test-path $SupportedModelsCSV) {
	$ModelsToImport = Import-Csv -Path $SupportedModelsCSV -ErrorAction Stop
    if ($ModelsToImport.Model.Count -gt "1")
    {
        Log -Message "Info: $($ModelsToImport.Model.Count) models found" -Type 1 -LogFile $LogFile -Component FileImport
        #Write-host "Info: $($ModelsToImport.Model.Count) models found"
        Print -Message "$($ModelsToImport.Model.Count) models found" -Color Green -Indent 2

    }
    else
    {
        Log -Message "Info: $($ModelsToImport.Model.Count) model found" -Type 1 -LogFile $LogFile -Component FileImport
        #Write-host "Info: $($ModelsToImport.Model.Count) model found"
        Print -Message "$($ModelsToImport.Model.Count) model found" -Color Green -Indent 2

    }   
}
else {
    #Write-host "Could not find any .CSV file, the script will break" -ForegroundColor Red
    Print -Message "Could not find any .CSV file, the script will break" -Color Red -Indent 2
    Log -Message "Could not find any .CSV file, the script will break" -Type 3 -LogFile $LogFile -Component FileImport
    Break
}

$HPModelsTable = foreach ($Model in $ModelsToImport) {
    @(
    @{ ProdCode = "$($Model.ProductCode)"; Model = "$($Model.Model)"; WindowsBuild = $Model.WindowsBuild; OS = "$($Model.OSVersion)" }
    )
    Log -Message "Added $($Model.ProductCode) $($Model.Model) $($Model.OSVersion) $($Model.WindowsBuild) to download list" -type 1 -LogFile $LogFile -Component FileImport
    #Write-host "Info: Added $($Model.ProductCode) $($Model.Model) $($Model.WindowsVersion) to download list"
    Print -Message "Added $($Model.ProductCode) $($Model.Model) $($Model.OSVersion) $($Model.WindowsBuild) to download list" -Color Green -Indent 3
}


Print -Message "Processing specified models" -Color Green -Indent 1

$ModelsToImportCount = $ModelsToImport.Model.Count
$CurrentModelCount = 0

# Loop through the list of models in csv file
foreach ($Model in $HPModelsTable) {
    $CurrentModelCount++
    Write-Progress -Id 1 -Activity "Working on $($Model.Model) ($CurrentModelCount of $ModelsToImportCount)" -PercentComplete ($CurrentModelCount/$ModelsToImportCount*100)
 

    # Set WindowsBuild for 2009 to 20H2.  
    if($Model.WindowsBuild -eq "2009") # Want to set OSVersion to 20H2 in ConfigMgr, and must use 2009 to download Drivers from HP.
    {
         $WindowsBuild = "20H2"
         
    }
    else
    {
        $WindowsBuild = $Model.WindowsBuild
    }

    $OS = $Model.OS

    $GLOBAL:UpdatePackage = $False

    #==============Monitor Changes for Update Package======================================================

    Log -Message "----------------------------------------------------------------------------" -LogFile $LogFile -Component HPIA -Type 1

    Print -Message "Working on $($Model.Model)" -Color Cyan -Indent 2

    $ModelPath = Join-Path $RepositoryPath "$OS\$WindowsBuild\$($Model.Model) $($Model.ProdCode)"
    $ModelRepositoryPath = Join-Path $ModelPath "Repository"


    if (Test-path $ModelRepositoryPath)
    {
        $ModelRepositoryExists = $true
        #write-host "Info: $($Model.Model) exists, monitoring is needed to see if any softpaqs changes in the repository during the synchronization"
        Print -Message "$($Model.Model) exists in local repository, monitoring is needed to see if any softpaqs changes is made during repository synchronization" -Color Green -Indent 3
        Log -Message "$($Model.Model) exists, monitoring is needed to see if any softpaqs changes in the repository during the synchronization" -Type 1 -Component FileWatch -LogFile $LogFile

        $filewatcher = New-Object System.IO.FileSystemWatcher
    
        #Mention the folder to monitor
        $filewatcher.Path = $ModelRepositoryPath
        $filewatcher.Filter = "*.cva"
        #include subdirectories $true/$false
        $filewatcher.IncludeSubdirectories = $False
        $filewatcher.EnableRaisingEvents = $true  
    ### DEFINE ACTIONS AFTER AN EVENT IS DETECTED
        $writeaction = { $path = $Event.SourceEventArgs.FullPath
                    $changeType = $Event.SourceEventArgs.ChangeType
                    $logline = "$(Get-Date), $changeType, $path"
                    Print -Message "$logline" -Indent 3 -Color Green
                    Print -Message "Setting Update Package to True, need to update package on $DPGroupName when sync is done" -Indent 3 -Color Green
                    #Write-Host "Info: $logline" #Add-content
                    #Write-Host "Info: Setting Update Package to True, need to update package on $DPGroupName when sync is done"
                    Log -Message "$logline" -Type 1 -Component FileWatch -LogFile $LogFile
                    Log -Message "Setting Update Package to True, need to update package on $DPGroupName when synchronization is done" -Type 1 -Component FileWatch -LogFile $LogFile
                    $GLOBAL:UpdatePackage = $True
                    #Write-Host "Info: Write Action $UpdatePackage"
                  }
              
    ### DECIDE WHICH EVENTS SHOULD BE WATCHED
        Register-ObjectEvent $filewatcher "Created" -Action $writeaction | Out-Null
        Register-ObjectEvent $filewatcher "Changed" -Action $writeaction | Out-Null
        Register-ObjectEvent $filewatcher "Deleted" -Action $writeaction | Out-Null
        Register-ObjectEvent $filewatcher "Renamed" -Action $writeaction | Out-Null

    }
    else
    {
        $ModelRepositoryExists = $false

        Print -Message "This is the first time syncing $($Model.Model), no need to monitor file changes" -Indent 3 -Color Green
        Log -Message "It's the first time this $($Model.Model) is running, no need to monitor file changes" -Type 1 -Component FileWatch -LogFile $LogFile

        Log -Message "Creating repository $ModelRepositoryPath" -LogFile $LogFile -Type 1 -Component HPIA
        Print -Message "Creating repository $ModelRepositoryPath" -Indent 3 -Color Green
        New-Item -ItemType Directory -Path $ModelRepositoryPath -Force | Out-Null
        
        if (Test-Path $ModelRepositoryPath)
        {
            Log -Message "$ModelRepositoryPath successfully created" -LogFile $LogFile -Type 1 -Component HPIA
            #Write-host "Info: $($Model.Model) $($Model.ProdCode) HPIA folder and repository subfolder successfully created" -ForegroundColor Green
            Print -Message "Repository $ModelRepositoryPath successfully created" -Indent 4 -Color Green
        }
        else
        {
            Log -Message "Failed to create repository $ModelRepositoryPath" -LogFile $LogFile -Type 3 -Component HPIA
            #Write-host "Info: Failed to create repository subfolder!" -ForegroundColor Red
            Print -Message "Failed to create repository $ModelRepositoryPath. Cannot continue" -Indent 4 -Color Red
            Exit
        }

    }

    $ModelRepositoryInitPath = Join-Path $ModelRepositoryPath ".repository"
    if (-not (Test-Path $ModelRepositoryInitPath))
    {
        Log -Message "Repository not initialized, initializing now" -LogFile $LogFile -Type 1 -Component HPIA
        Print -Message "Repository not initialized, initializing now" -Indent 3 -Color Green

        Set-Location -Path $ModelRepositoryPath
        
        Initialize-Repository

        if (Test-Path $ModelRepositoryInitPath)
        {
            #Write-host "Info: $($Model.Model) $($Model.ProdCode) repository successfully initialized"
            Print -Message "Repository $($Model.Model) $($Model.ProdCode) successfully initialized" -Indent 4 -Color Green
            Log -Message "$($Model.Model) $($Model.ProdCode) repository successfully initialized" -LogFile $LogFile -Type 1 -Component HPIA
        }
        else
        {
            Log -Message "Failed to initialize repository for $($Model.Model) $($Model.ProdCode)" -LogFile $LogFile -Type 3 -Component HPIA
            Print -Message "Repository $($Model.Model) $($Model.ProdCode) failed to initialize. Cannot continue" -Indent 4 -Color Red
            #Write-host "Info: Failed to initialize repository for $($Model.Model) $($Model.ProdCode)" -ForegroundColor Red
            Exit
        }
    }    
    
    Log -Message "Setting download location to: $ModelRepositoryPath" -LogFile $LogFile -Type 1 -Component HPIA
    Set-Location -Path $ModelRepositoryPath
    
    if ($XMLEnableSMTP.Enabled -eq "True") {
        Set-RepositoryNotificationConfiguration $SMTP
        Add-RepositorySyncFailureRecipient -to $EMAIL
        Log -Message "Configured notification for $($Model.Model) $($Model.ProdCode) with SMTP: $SMTP and Email: $EMAIL" -LogFile $LogFile -Type 1 -Component HPIA
    }  
    
    Log -Message "Remove any existing repository filter for $($Model.Model)" -LogFile $LogFile -Type 1 -Component HPIA
    Remove-RepositoryFilter -platform $($Model.ProdCode) -yes
    
    Print -Message "Applying repository filter for $($Model.Model)" -Indent 3 -Color Green
    Log -Message "Applying repository filter for $($Model.Model) repository" -LogFile $LogFile -Type 1 -Component HPIA

    # Set HPIA Filter: Dock
    if ($HPIAFilter_Dock -eq "True") {
           Add-RepositoryFilter -platform $($Model.ProdCode) -os $OS -osver $($Model.WindowsBuild) -category dock
           Log -Message "Applying repository filter to $($Model.Model) repository to download: Dock" -type 1 -LogFile $LogFile -Component HPIA

    }
    else {
        Log -Message "Not applying repository filter to download $($Model.Model) for: Dock" -type 1 -LogFile $LogFile -Type 1 -Component HPIA

    }

    # Set HPIA Filter: Driver
    if ($HPIAFilter_Driver -eq "True") {
        Add-RepositoryFilter -platform $($Model.ProdCode) -os $OS -osver $($Model.WindowsBuild) -category driver
        Log -Message "Applying repository filter to $($Model.Model) repository to download: Driver" -type 1 -LogFile $LogFile -Component HPIA

    }
    else {
        Log -Message "Not applying repository filter to download $($Model.Model) for: Driver" -type 1 -LogFile $LogFile -Component HPIA

    }

    # Set HPIA Filter: Firmware
    if ($HPIAFilter_Firmware -eq "True") {
        Add-RepositoryFilter -platform $($Model.ProdCode) -os $OS -osver $($Model.WindowsBuild) -category firmware
        Log -Message "Applying repository filter to $($Model.Model) repository to download: Firmware" -type 1 -LogFile $LogFile -Component HPIA
    }
    else {
        Log -Message "Not applying repository filter to download $($Model.Model) for: Firmware" -type 1 -LogFile $LogFile -Component HPIA
    }

    # Set HPIA Filter: Driverpack
    if ($HPIAFilter_Driverpack -eq "True") {
        Add-RepositoryFilter -platform $($Model.ProdCode) -os $OS -osver $($Model.WindowsBuild) -category driverpack
        Log -Message "Applying repository filter to $($Model.Model) repository to download: Driverpack" -type 1 -LogFile $LogFile -Component HPIA

    }
    else {
        Log -Message "Not applying repository filter to download $($Model.Model) for: DriverPack" -type 1 -LogFile $LogFile -Component HPIA
    }

    # Set HPIA Filter: BIOS
    if ($HPIAFilter_BIOS -eq "True") {
        Add-RepositoryFilter -platform $($Model.ProdCode) -os $OS -osver $($Model.WindowsBuild) -category bios
        Log -Message "Applying repository filter to $($Model.Model) repository to download: BIOS" -type 1 -LogFile $LogFile -Component HPIA

    }
    else {
        Log -Message "Not applying repository filter to download $($Model.Model) for: BIOS" -type 1 -LogFile $LogFile -Component HPIA
    }


    Log -Message "Invoking repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild)" -LogFile $LogFile -Component HPIA
    Print -Message "Invoking repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) (might take some time)" -Indent 3 -Color Green
    
    try
    {
        Invoke-RepositorySync -Quiet

        Set-RepositoryConfiguration -Setting OfflineCacheMode -CacheValue Enable
        Start-Sleep -s 15
        Set-RepositoryConfiguration -Setting OfflineCacheMode -CacheValue Enable

        Log -Message "Repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) successful" -LogFile $LogFile -Component HPIA
        Print -Message "Repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) successful" -Indent 4 -Color Green
    }
    catch
    {
        Log -Message "Repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) NOT successful" -LogFile $LogFile -Component HPIA -Type 2
        Print -Message "Repository sync for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) NOT successful" -Indent 4 -Color Red
    }

    Log -Message "Invoking repository cleanup for $($Model.Model) $($Model.ProdCode) repository for all selected categories" -LogFile $LogFile -Type 1 -Component HPIA
    Print -Message "Invoking repository cleanup for $($Model.Model) $($Model.ProdCode) repository for all selected categories" -Indent 3 -Color Green
    
    try
    {
        Invoke-RepositoryCleanup
    
        Set-RepositoryConfiguration -Setting OfflineCacheMode -CacheValue Enable
        Log -Message "Inventory cleanup for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) successful" -LogFile $LogFile -Component HPIA
        Print -Message "Inventory cleanup for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) successful" -Indent 4 -Color Green

    }
    catch
    {
        Log -Message "Inventory cleanup for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) NOT successful" -LogFile $LogFile -Component HPIA -Type 2
        Print -Message "Inventory cleanup for $($Model.Model) $($Model.ProdCode). OS: $OS, $($Model.WindowsBuild) NOT successful" -Indent 4 -Color Red
    }

    Log -Message "Confirm HPIA files are up to date for $($Model.Model) $($Model.ProdCode)" -LogFile $LogFile -Type 1 -Component HPIA
    Print -Message "Confirm HPIA files are up to date for $($Model.Model) $($Model.ProdCode)" -Indent 3 -Color Green
    #Write-host "Info: Confirm HPIA files are up to date for $($Model.Model) $($Model.ProdCode)" 

    $HPIARepoPath = Join-Path $ModelPath "HPImageAssistant.exe"
    #$HPIAExist = Get-Item $HPIARepoPath -ErrorAction SilentlyContinue
    $HPIAExist = Test-Path $HPIARepoPath -PathType Leaf -ErrorAction SilentlyContinue
    #Print -Message "DEBUG: HPIAExist - $HPIAExist" -Indent 3 -Color Green
    
    if (($HPIAVersionUpdated) -or (-not ($HPIAExist)))
    {
        #Write-Host "Info: Running HPIA Update"
        Print -Message "Updating HPIA files in $ModelPath with robocopy" -Indent 4 -Color Green
        Log -Message "Updating HPIA files in $ModelPath with robocopy" -type 1 -LogFile $LogFile -Component HPIA

        $RobocopySource = "$($XMLInstallHPIA.Value)\HPIA Base"
        $RobocopyDest = $ModelPath
        $RobocopyArg = '"'+$RobocopySource+'"'+' "'+$RobocopyDest+'"'+' /xc /xn /xo /fft /e /b /copyall'
        $RobocopyCmd = "robocopy.exe"

        Start-Process -FilePath $RobocopyCmd -ArgumentList $RobocopyArg -Wait
    
    } 
    else
    {
        #Write-Host "Info: No need to update HPIA, skipping this step."
        Print -Message "No need to update HPIA, skipping" -Indent 4 -Color Green
        Log -Message "No need to update HPIA, skipping." -type 1 -LogFile $LogFile -Component HPIA
    }

    Print -Message "Check if offline cache folder exists" -Indent 3 -Color Green
    # Checking if offline folder is created.
    $OfflinePath = Join-Path $ModelRepositoryInitPath "cache\offline"

    if (-not (Test-Path $OfflinePath))
    {
        Print -Message "Offline cache folder does not exist, invoking sync" -Indent 4 -Color Green
        Log -Message "Offline cache folder does not exist, invoking sync" -type 1 -LogFile $LogFile -Component HPIA

        $OfflineFolderCreated = $false
        $OfflineCheckCount = 0
        Invoke-RepositorySync -Quiet
        Start-Sleep -Seconds 15
        Set-RepositoryConfiguration -Setting OfflineCacheMode -CacheValue Enable
        Start-Sleep -Seconds 10

        while (($OfflineFolderCreated -ne $true) -and $OfflineCheckCount -lt 10)
        {
            $OfflineCheckCount++
            
            if (Test-Path $OfflinePath)
            {
                $OfflineFolderCreated = $true
                Print -Message "Offline cache folder exists, will continue" -Indent 4 -Color Green
            }
            else
            {
                Print -Message "Offline cache folder doesn't exist, will try $(10-$OfflineCheckCount) more times" -Indent 5 -Color Yellow
            }
            
            Start-Sleep 5
        }

        if (-not ($OfflineFolderCreated))
        {
            Log -Message "Offlinefolder ($OfflinePath) still not detected, please run script manually again and update Distribution points" -type 3 -LogFile $LogFile -Component HPIA
            Print -Message "Offlinefolder ($OfflinePath) still not detected, please run script manually again and update Distribution points" -Indent 4 -Color Yellow
        }

    }

    #==========Stop Monitoring Changes===================

        Get-EventSubscriber | Unregister-Event

    #====================================================

    Print -Message "Starting ConfigMgr Tasks" -Color Green -Indent 3

    # ConfigMgr part start here    
    Import-Module $ConfigMgrModule
    Set-location "$($SiteCode):\"

    if ((Test-path $CMfolderPath) -eq $false)
    {
        Log -Message "$CMFolderPath does not exists in ConfigMgr, creating folder path" -type 2 -LogFile $LogFile -Component ConfigMgr
        Print -Message "$CMFolderPath does not exists in ConfigMgr, creating folder path" -Color Green -Indent 4
        New-Item -ItemType directory -Path "$CMfolderPath"
        #Log -Message "$CMFolderPath was successfully created in ConfigMgr" -type 2 -LogFile $LogFile -Component ConfigMgr

        if ((Test-path $CMfolderPath\$OS) -eq $false)
        {
            Log -Message "$CMfolderPath\$OS does not exists in ConfigMgr, creating folder path" -type 2 -LogFile $LogFile -Component ConfigMgr
            Print -Message "$CMfolderPath\$OS does not exists in ConfigMgr, creating folder path" -Color Green -Indent 4
            New-Item -ItemType directory -Path "$CMfolderPath\$OS" -Force
            #Log -Message "$CMFolderPath was successfully created in ConfigMgr" -type 2 -LogFile $LogFile -Component ConfigMgr

            if ((Test-path $CMfolderPath\$OS\$WindowsBuild) -eq $false)
            {
                Log -Message "$CMfolderPath\$OS\$WindowsBuild does not exists in ConfigMgr, creating folder path" -type 2 -LogFile $LogFile -Component ConfigMgr
                Print -Message "$CMfolderPath\$OS\$WindowsBuild does not exists in ConfigMgr, creating folder path" -Color Green -Indent 4
                New-Item -ItemType directory -Path "$CMfolderPath\$OS\$WindowsBuild" -Force
                #Log -Message "$CMFolderPath was successfully created in ConfigMgr" -type 2 -LogFile $LogFile -Component ConfigMgr
            }
        }
    }

    $SourcesLocation = $ModelPath # Set Source location
    $PackageName = "HPIA-$OS-$WindowsBuild-" + "$($Model.Model)" + " $($Model.ProdCode)" #Must be below 40 characters, hardcoded variable, will be used inside the ApplyHPIA.ps1 script, Please dont change this.
    $PackageDescription = "$OS $WindowsBuild-" + "$($Model.Model)" + " $($Model.ProdCode)"
    $PackageManufacturer = "HP" # hardcoded variable, will be used inside the ApplyHPIA.ps1 script, Please dont change this.
    $PackageVersion = "$WindowsBuild"
    $SilentInstallCommand = ""
    
    Print -Message "Checking if $PackageName exists in ConfigMgr" -Color Green -Indent 4
    # Check if package exists in ConfigMgr, if not it will be created.
    $PackageExist = Get-CMPackage -Fast -Name $PackageName
    If ([string]::IsNullOrWhiteSpace($PackageExist)){
        #Write-Host "Does not Exist"
        Log -Message "$PackageName does not exists in ConfigMgr" -type 1 -LogFile $LogFile -Component ConfigMgr
        Log -Message "Creating $PackageName in ConfigMgr" -type 1 -LogFile $LogFile -Component ConfigMgr
        #Write-host "Info: $PackageName does not exists in ConfigMgr"
        #Write-host "Info: Creating $PackageName in ConfigMgr"
        Print -Message "$PackageName does not exists in ConfigMgr, creating it." -Color Green -Indent 5

        try
        {
            New-CMPackage -Name $PackageName -Description $PackageDescription -Manufacturer $PackageManufacturer -Version $PackageVersion -Path $SourcesLocation | Out-Null
            Set-CMPackage -Name $PackageName -DistributionPriority Normal -CopyToPackageShareOnDistributionPoints $True -EnableBinaryDeltaReplication $True | Out-Null
            Log -Message "$PackageName is created in ConfigMgr" -LogFile $LogFile -Type 1 -Component ConfigMgr    
            Start-CMContentDistribution -PackageName "$PackageName" -DistributionPointGroupName "$DPGroupName" | Out-Null
            Log -Message "Starting to send out $PackageName to $DPGroupName" -type 1 -LogFile $LogFile -Component ConfigMgr
        
            $MovePackage = Get-CMPackage -Fast -Name $PackageName        
            Move-CMObject -FolderPath "$CMfolderPath\$OS\$WindowsBuild" -InputObject $MovePackage | Out-Null
            Log -Message "Moving ConfigMgr package to $CMfolderPath\$OS\$WindowsBuild" -LogFile $LogFile -Component ConfigMgr -Type 1
        
            Set-Location -Path "$($InstallPath)"
            #Write-host "Info: $PackageName is created in ConfigMgr and distributed to $DPGroupName"
            Print -Message "$PackageName is created in ConfigMgr and distributed to $DPGroupName" -Color Green -Indent 6
        }
        catch
        {
            Print -Message "Failed to create package $PackageName and/or distribute to DPGroup $DPGroupName" -Color Red -Indent 6
        }
    }
    else 
    {
        If ($GLOBAL:UpdatePackage -eq $True){
            Print -Message "$PackageName exists in ConfigMgr and changes was made to the repository, updating content" -Color Green -Indent 5
            #Write-Host "Info: Changes was made when running RepositorySync, updating ConfigMgrPkg: $PackageName" -ForegroundColor Green
            Log -Message "Changes made Updating ConfigMgrPkg: $PackageName on DistributionPoint" -type 2 -Component ConfigMgr -LogFile $LogFile
            Update-CMDistributionPoint -PackageName "$PackageName"
        }
        else
        {
            Print -Message "$PackageName exists in ConfigMgr but no changes was made to the repository during sync, nothing to do." -Color Green -Indent 5
            #Write-Host "Info: No Changes was Made when running RepositorySync, not updating ConfigMgrPkg: $PackageName on DistributionPoint"
            Log -Message "No Changes was Made, not updating ConfigMgrPkg: $PackageName on DistributionPoint" -type 1 -LogFile $LogFile -Component ConfigMgr

        }

        Set-Location -Path $($InstallPath)
        #Write-host "Info: $($Model.Model) is done, continue with next model in the list."  -ForegroundColor Green
        Log -Message "$($Model.Model) is done, continue with next model in the list." -type 1 -LogFile $LogFile
        Print -Message "$($Model.Model) is done, continue with next model (if any) in the list" -Color Green -Indent 2
    }
    
}

Set-Location -Path "$($InstallPath)"
$stopwatch.Stop()
$FinalTime = $stopwatch.Elapsed

Print -Message "Repository update complete. Runtime: $FinalTime" -Color Cyan

#Write-host "Info: Runtime: $FinalTime"
#Write-host "Info: Repository Update Complete" -ForegroundColor Green

Log -Message "Runtime: $FinalTime" -LogFile $Logfile -Type 1 -Component HPIA
Log -Message "Repository Update Complete" -LogFile $LogFile -Type 1 -Component HPIA
Log -Message "----------------------------------------------------------------------------" -LogFile $LogFile
