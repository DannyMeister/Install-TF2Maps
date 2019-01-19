[CmdletBinding()]
Param()

function PrintMessageToUser {
    param(
        [Parameter( `
            Mandatory=$True, `
            Valuefrompipeline = $true)]
        [String]$message
    )
    begin {
        $window_private_data = (Get-Host).PrivateData;
        # saving the original colors
        $saved_background_color = $window_private_data.VerboseBackgroundColor
        $saved_foreground_color = $window_private_data.VerboseForegroundColor
        # setting the new colors
        $window_private_data.VerboseBackgroundColor = 'Black';
        $window_private_data.VerboseForegroundColor = 'Red';
    }
    process {
        foreach ($Message in $Message) {
            # Write-Host Considered Harmful - see http://www.jsnover.com/blog/2013/12/07/write-host-considered-harmful/
            # first way how to correctly write it
            #Write-host $message;
            Write-Verbose -Message $message -Verbose;
            # second correct way how to write it
            #$VerbosePreference = "Continue"
            #Write-Verbose $Message;
        }
    }
    end {
      $window_private_data.VerboseBackgroundColor = $saved_background_color;
      $window_private_data.VerboseForegroundColor = $saved_foreground_color;
    }

} # end PrintMessageToUser
Write-Host "Input the location of a public url of a folder listing of maps to download."
$listUrl = Read-Host "URL"

$steamInstall = $null
$tf2DownloadLocation = $null

if (Test-Path HKLM:\SOFTWARE\Valve\Steam) {
    $steamInstall = Get-ItemProperty HKLM:\SOFTWARE\Valve\Steam\InstallPath -Name InstallPath | select -expand InstallPath
}
elseif (Test-Path HKLM:\SOFTWARE\Wow6432Node\Valve\Steam) {
    $steamInstall = Get-ItemProperty HKLM:\SOFTWARE\Wow6432Node\Valve\Steam -Name InstallPath | select -expand InstallPath
}

if(-not ($steamInstall -eq $null)){
    if(Test-Path "$steamInstall\SteamApps\common\Team Fortress 2"){
        $tf2DownloadLocation = "$steamInstall\SteamApps\common\Team Fortress 2\tf\download\maps"
    }
    else {
        Write-Host "Steam install detected at $steamInstall, but Team Fortress not found at $steamInstall\SteamApps\common\Team Fortress 2."
        Write-Host "Multiple Steam library locations not yet supported."
        #todo: parse the SteamApps\libraryfolders.vdf file for alternate game locations
    }
}


if(-not ($steamInstall -eq $null)){
    Write-Host "Team Fortress 2 map location auto-detected at $tf2DownloadLocation"
}
else {
    [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms")|Out-Null

    PrintMessageToUser "Auto-detect failed to location Team Fortress 2's install folder."
    PrintMessageToUser "Browse to select a folder to download to."
    PrintMessageToUser "example: D:\Program Files\Steam\SteamApps\common\Team Fortress 2\tf\download\maps"
    Read-Host "[Enter] key to browse. (warning, sometimes browser dialog pops up behind other windows)"


    $foldername = New-Object System.Windows.Forms.FolderBrowserDialog
    $foldername.Description = "Browse to TF2 map folder"
    $foldername.rootfolder = "MyComputer"

    if($foldername.ShowDialog() -eq "OK") {
        $folder = $foldername.SelectedPath
    }
    else{
        Write-Host "No folder selected. Terminating"
        return
    }

    $tf2DownloadLocation = $folder

    Write-Host "Team Fortress 2 map location set to $tf2DownloadLocation"
}





$listContent = Invoke-WebRequest -uri $listUrl

# group the *.bsp and *.bsp.bz2 maps with the same map name together
$serverMaps = $listContent.Links | %{ $_.href } | select-string -Pattern "(.+\.bsp)(\.bz2)?$" | Group-Object {$_.Matches.Groups[1]}

$installedMaps = Get-ChildItem $tf2DownloadLocation | Select-Object -ExpandProperty Name

$newMaps = $serverMaps | Where-Object {$_.Name -notin $installedMaps}

$serverMapCount = $serverMaps | Measure-Object | Select-Object -ExpandProperty Count
$installedMapCount = $installedMaps | Measure-Object | Select-Object -ExpandProperty Count
$newMapCount = $newMaps | Measure-Object | Select-Object -ExpandProperty Count

Write-Host "Found $serverMapCount maps on download server."

Write-Host "Found $installedMapCount maps on local installation of TF2."

Write-Host "Found $newMapCount maps on server not installed locally."

$continue = $false
if ($newMapCount -gt 0) {
    $reply = Read-Host -Prompt "This script will dowload $newMapCount files and copy to them to your local installation. Continue Y or N?"
    $continue = $reply -match "[Yy]"
} else {
    Write-Host "No new maps found for download. Terminating."
}

if (-Not $continue) { return }

$sw = [Diagnostics.Stopwatch]::StartNew()

# sorting the groups of matching *.bsp/*.bsp.bz2 and taking the last ensures we download the smaller *.bz2
$newDownloadFiles = $newMaps | %{ $_.Group | sort | select -Last 1 | Out-String | %{$_.Trim()} }

# current path of either the executing script file or the current working directory
$currentPath = [System.IO.Path]::GetDirectoryName( (@($script:MyInvocation.MyCommand.Path, "$pwd\tf2mapdownloader.ps1") | select -first 1))

#downloading a c# library for unzipping bz2 files seems more reliable than hoping and searching for 7zip
If (-Not (Test-Path $currentPath\SharpZipLib)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri https://github.com/icsharpcode/SharpZipLib/releases/download/v1.1.0/SharpZipLib.1.1.0.nupkg -OutFile "SharpZipLib.1.1.0.nupkg"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$currentPath\SharpZipLib.1.1.0.nupkg", "$currentPath\SharpZipLib")
}

Add-Type -Path $currentPath\SharpZipLib\lib\net45\ICSharpCode.SharpZipLib.dll

$newDownloadFiles | Foreach {
    If ($_.EndsWith(".bz2")) {
        $extractedFileName = $_ | select-string -Pattern "(.+\.bsp)(\.bz2)?$" | select -Property @{e={$_.Matches.Groups[1].Value};n="v"} | select -ExpandProperty v
        
        Write-Host "Downloading $_"
        Invoke-WebRequest -Uri "$listUrl$($_)" -OutFile $_
        
        Write-Host "Unzipping $_"
        $fileOpen = (Get-ChildItem $_).OpenRead()
        New-Item "$tf2DownloadLocation\$extractedFileName" | Out-Null
        $fileWrite = (Get-ChildItem "$tf2DownloadLocation\$extractedFileName").OpenWrite()
        [ICSharpCode.SharpZipLib.BZip2.BZip2]::Decompress($fileOpen,$fileWrite,$true)

        Write-Host "Copied to $tf2DownloadLocation\$extractedFileName"

        Remove-Item $_
    } Else {
        Write-Host "Downloading $_"
        Invoke-WebRequest -Uri "$listUrl$($_)" -OutFile $_
    }
}
$sw.Stop()

Write-Host "Finished installing $newMapCount"
Write-Host "Total time: $($sw.Elapsed.ToString("g"))"
Read-Host "[Enter] to exit"