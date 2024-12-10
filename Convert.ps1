#Requires -RunAsAdministrator
<#
This powershell app will convert Citrix UPM profiles to FSLogix .vhdx containers
Once executed (assuming you have edited $newprofilepath and $oldprofiles to match the client being converted) it will give you a list of
profiles to convert.  You can then select which profile(s) you wish to convert to FSLogix profiles. You will need to edit the robocopy sections 
near the end to account for where the user redirect data lives currently.
#>
# FSLogix profile path
$newprofilepath = "\\profilestore\path\ProfileContainerTesting" ##### FSLogix Root Profile Path
#UPM Profile Store and selector window. This window allows you to select the profile to convert to a container. First is a test store I used while building this out.
#$oldprofiles = gci \\profilestore\path\Testing | select -Expand fullname | sort | out-gridview -OutputMode Multiple -title "Select profile(s) to convert"
$oldprofiles = gci \\profilestore\path\Users | select -Expand fullname | sort | out-gridview -OutputMode Multiple -title "Select profile(s) to convert"
foreach ($old in $oldprofiles) {
<#
I know that the UPM folder has the username in it. I get that and save it to the sam variable, and use that to get the user's sid
then save that to $sid.
#>
$sam = Split-Path ($old -split "Testing")[1] -leaf
$sid = (New-Object System.Security.Principal.NTAccount($sam)).translate([System.Security.Principal.SecurityIdentifier]).Value
<#
This is to create .reg file located in %localappdata%\FSLogix - last thing the script does is create the .reg file for the profilelist key
#>
$regtext = "Windows Registry Editor Version 5.00
 
[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid]
`"ProfileImagePath`"=`"C:\\Users\\$sam`"
`"FSL_OriginalProfileImagePath`"=`"C:\\Users\\$sam`"
`"Flags`"=dword:00000000
`"State`"=dword:00000000
`"ProfileLoadTimeLow`"=dword:00000000
`"ProfileLoadTimeHigh`"=dword:00000000
`"RefCount`"=dword:00000000
`"RunLogonScriptSync`"=dword:00000000
"
<# Set the new profile container path to \\newprofilepath\sid_username
#>
$nfolder = join-path $newprofilepath ($sid+"_"+$sam)
# If $nfolder doesn't exist - create it
if (!(test-path $nfolder)) {New-Item -Path $nfolder -ItemType directory | Out-Null}
& icacls $nfolder /setowner "$env:userdomain\$sam" /T /C
& icacls $nfolder /grant $env:userdomain\$sam`:`(OI`)`(CI`)F /T
# Sets vhd to \\nfolderpath\profile_username.vhd
$vhd = Join-Path $nfolder ("Profile_"+$sam+".vhd")
# Diskpart commands to create VHD as expandable 100GB max size
$script1 = "create vdisk file=`"$vhd`" maximum 102400 type=expandable"
$script2 = "sel vdisk file=`"$vhd`"`r`nattach vdisk"
$script3 = "sel vdisk file=`"$vhd`"`r`ncreate part prim`r`nselect part 1`r`nformat fs=ntfs quick"
$script4 = "sel vdisk file=`"$vhd`"`r`nsel part 1`r`nassign letter=T"
$script5 = "sel vdisk file`"$vhd`"`r`ndetach vdisk"
$script6 = "sel vdisk file=`"$vhd`"`r`nattach vdisk readonly`"`r`ncompact vdisk"
<#
If the vhd doesn't exist create, attach, wait 5 seconds (Windows has to catch up), create/format the partition,
assigns letter T, and sets the disk label to Profile-username to match what FSLogix looks for when searching for containers at login
#>
if (!(test-path $vhd)) {
$script1 | diskpart
$script2 | diskpart
Start-Sleep -s 5
$script3 | diskpart
$script4 | diskpart
& label T: Profile-$sam
New-Item -Path T:\Profile -ItemType directory | Out-Null
# Set permissions on the profile
start-process icacls "T:\Profile /setowner SYSTEM"
Start-Process icacls -ArgumentList "T:\Profile /inheritance:r"
$cmd1 = "T:\Profile /grant $env:userdomain\$sam`:`(OI`)`(CI`)F"
Start-Process icacls -ArgumentList "T:\Profile /grant SYSTEM`:`(OI`)`(CI`)F"
Start-Process icacls -ArgumentList "T:\Profile /grant Administrators`:`(OI`)`(CI`)F"
Start-Process icacls -ArgumentList $cmd1
} else {
# If the vhd does exist then attach, wait 5 seconds, assign letter T
$script2 | diskpart
Start-Sleep -s 5
$script4 | diskpart
}
 
# Copies in the UPM profile to the Profile directory on the vhd including subfolders
"Copying $old\UPM_Profile to $vhd"
& robocopy $old\UPM_Profile\ T:\Profile\ /E /r:0 | Out-Null
# Creates the %localappdata%\FSLogix path if it doesnt exist
if (!(Test-Path "T:\Profile\AppData\Local\FSLogix")) {
New-Item -Path "T:\Profile\AppData\Local\FSLogix" -ItemType directory | Out-Null
}

# Copies in the user's folder redirection data to the Profile directory on the vhd including subfolders
"Copying \\profilestore\redirects\$sam\ to $vhd"
& robocopy \\profilestore\redirects\$sam T:\Profile /E /r:0 | Out-Null

# Creates the profiledata.reg file if it doesn't exist
if (!(Test-Path "T:\Profile\AppData\Local\FSLogix\ProfileData.reg")) {$regtext | Out-File "T:\Profile\AppData\Local\FSLogix\ProfileData.reg" -Encoding ascii}
$script5 | diskpart
}
