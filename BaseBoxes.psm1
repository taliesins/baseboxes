function Get-Checksum
{
    Param (
        [string]$File=$(throw("You must specify a filename to get the checksum of.")),
        [ValidateSet("sha1","md5")]
        [string]$Algorithm="sha1"
    )

    $fs = new-object System.IO.FileStream $File, "Open"
    $algo = [type]"System.Security.Cryptography.$Algorithm"
    $crypto = $algo::Create()
    $hash = [BitConverter]::ToString($crypto.ComputeHash($fs)).Replace("-", "")
    $fs.Close()
    $hash
}

function Convert-VhdToVhdx {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vhdPath = "$destinationDrivePath.vhd"
    $vhdxPath = "$destinationDrivePath.vhdx"

    Convert-VHD -Path $vhdPath -DestinationPath $vhdxPath -VHDType Dynamic
    Set-VHD $vhdxPath -PhysicalSectorSizeBytes 4096
    Optimize-VHD -Path $vhdxPath -Mode Full  

    return $vhdxPath         
}

function Convert-VhdxToVhd {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vhdPath = "$destinationDrivePath.vhd"
    $vhdxPath = "$destinationDrivePath.vhdx"

    Convert-VHD -Path $vhdxPath -DestinationPath $vhdPath -VHDType Dynamic
    Set-VHD $vhdPath -PhysicalSectorSizeBytes 4096
    Optimize-VHD -Path $vhdPath -Mode Full  

    return $vhdPath         
}

function Convert-VmdkToVhdx {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $vmdkPath = $sourceFile.Path.FullName
    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vhdPath = "$destinationDrivePath.vhd"

    & VBoxManage clonehd $vmdkPath $vhdPath -format vhd

    return Convert-VhdToVhdx $vhdPath  
}

function Convert-VhdxToVmdk {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $vhdxPath = $sourceFile.Path.FullName
    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vmdkPath = "$destinationDrivePath.vmdk"

    $vhdPath = Convert-VhdxToVhd $vhdxPath

    & VBoxManage clonehd $vhdPath $vmdkPath -format vmdk
    
    return $vhdxPath    
}

function Convert-VdiToVhdx {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $vdiPath = $sourceFile.Path.FullName
    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vhdPath = "$destinationDrivePath.vhd"

    & VBoxManage modifyhd --compact $vdiPath
    & VBoxManage clonehd $vdiPath $vhdPath -format vhd

    return Convert-VhdToVhdx $vhdPath  
}

function Convert-VhdxToVdi {
    Param (
        $source
    )

    $sourceFile = Get-Item $source

    $vhdxPath = $sourceFile.Path.FullName
    $destinationDrivePath = "$destinationPath\$($sourceFile.Path.BaseName)"
    $vdiPath = "$destinationDrivePath.vdi"

    $vhdPath = Convert-VhdxToVhd $vhdxPath

    & VBoxManage clonehd $vhdPath $vdiPath -format vdi
    & VBoxManage modifyhd --compact $vdiPath
    
    return $vhdxPath    
}

function Get-BoxMetaData {
    Param (
        $vmName,
        $description,
        $version,
        $provider,
        $algorithm,
        $checksum,
        $baseUrl
    )

$boxMetdataJson = @"
    {{
      "name": "{0}",
      "description": "{1}",
      "versions": [{{
        "version": "{2}",
        "providers": [{{
          "name": "{3}",
          "url": "{4}{0}-{3}.box",
          "checksum_type": "{5}",
          "checksum": "{6}"
        }}]
      }}]
    }}
"@ -f $vmName, $description, $version, $provider, $baseUrl, $algorithm, $checksum

    return $boxMetdataJson
}

function Get-BoxMetaData {
    Param (
        $provider
    )

$metadataJson = @"
    {{
        "provider": "{0}"
    }}
"@ -f $provider

    return $metadataJson
}

function Export-HyperVBaseBox {
    Param (
        $vmName,
        $description,
        $version,
        $baseUrl
    )

    $provider = "hyperv"
    $algorithm = "sha1"

    $rootPath = "boxes\$vmName"
    if (!(Test-Path $rootPath))
    {
         mkdir $rootPath
    }
    $rootPath = Resolve-Path $rootPath

    $boxName = "$vmName-$provider.box"
    $boxMetaDataPath = "$rootPath\metadata-$provider.json"
    $boxPath = "$rootPath\$boxName"
    $tempDataPath = "$rootPath\$provider"
    $logPath = "$rootPath\$vmName-$provider.export.log"
    
    if ((Test-Path $tempDataPath))
    {
         rmdir $tempDataPath -Recurse -Force
    }

    mkdir $tempDataPath

    if ((Test-Path $boxMetaDataPath))
    {
        Remove-Item  $boxMetaDataPath -Force
    }

    if ((Test-Path $boxPath))
    {
        Remove-Item  $boxPath -Force
    }

    if ((Test-Path $logPath))
    {
        Remove-Item  $logPath -Force
    }

    if ((Test-Path "$rootPath\$boxName\"))
    {
        Remove-Item  "$rootPath\$boxName\" -Force
    }

    $latestSnapshot = Get-VMSnapshot -VMName @($vmName) | Select-Object -Last 1

    if (!$latestSnapshot)
    {
        $clone = Export-VM -Name $vmName -Path $tempDataPath
    } else {
        $oldName = $latestSnapshot.Name
        Rename-VMSnapshot -VMSnapshot $latestSnapshot -NewName $vmName
        $clone = Export-VMSnapshot -VMSnapshot $latestSnapshot -Path $tempDataPath
        Rename-VMSnapshot -VMSnapshot $latestSnapshot -NewName $oldName
    }

    Get-ChildItem "$rootPath\$provider\$vmName\Virtual Hard Disks\" -Filter *.vhd* | %{
        Optimize-VHD -Path $_.FullName -Mode Full
    }

    #Get-ChildItem "$rootPath\$provider\$vmName\Virtual Hard Disks\" -Filter *.vhdx | %{
    #    Resize-VHD -Path $_.FullName –ToMinimumSize
    #}

    $metadataJson = Get-BoxMetaData -provider $provider
    Set-Content -Path "$tempDataPath\$vmName\metadata.json" -Value $metadataJson

    Push-Location "$tempDataPath\$vmName\"
    $bsdtarPath = "$PSScriptRoot\bsdtar\bsdtar.exe"

    & $bsdtarPath cvzf $boxName ./*
    Pop-Location

    Move-Item "$tempDataPath\$vmName\*.box" "$rootPath\"
    Remove-Item $tempDataPath -Force -Recurse

    $boxPath = "$rootPath\$boxName"
    $checksum = Get-Checksum -File $boxPath -Algorithm $algorithm

    $boxMetdataJson = Get-BoxMetaData -vmName $vmName -description $description -version $version -provider $provider -algorithm $algorithm -checksum $checksum -baseUrl $baseUrl
    Set-Content -Path $boxMetaDataPath -Value $boxMetdataJson
}

function Export-VirtualBoxBaseBox {
    Param (
        $vmName,
        $description,
        $version,
        $baseUrl
    )

    $provider = "virtualbox"
    $algorithm = "sha1"

    $rootPath = "boxes\$vmName"
    if (!(Test-Path $rootPath))
    {
         mkdir $rootPath
    }
    $rootPath = Resolve-Path $rootPath

    $boxMetaDataPath = "$rootPath\metadata-$provider.json"
    $tempDataPath = "$rootPath\$provider"
    $metaDataPath = "$tempDataPath\metadata.json"

    $logPath = "$rootPath\$vmName-$provider.export.log"
    $boxName = "$vmName-$provider.box"


 	if ((Test-Path $boxMetaDataPath))
    {
        Remove-Item  $boxMetaDataPath -Force
    }

    if ((Test-Path $logPath))
    {
        Remove-Item  $logPath -Force
    }

    if ((Test-Path "$rootPath\$boxName"))
    {
        Remove-Item  "$rootPath\$boxName" -Force
    }

    & vagrant package --base "$vmName" --output "$rootPath\$boxName" > "$logPath"

    if (!(Test-Path "$rootPath\$boxName")) {
    	throw "Did not create $rootPath\$boxName please check name"
    }

    $checksum = Get-Checksum -File "$rootPath\$boxName" -Algorithm $algorithm

    $boxMetdataJson = Get-BoxMetaData -vmName $vmName -description $description -version $version -provider $provider -algorithm $algorithm -checksum $checksum -baseUrl $baseUrl
    Set-Content -Path $boxMetaDataPath -Value $boxMetdataJson
}

function Install-HyperVBaseBox {
    Param (
        $vmName
    )

    $provider = "hyperv"
    $rootPath = "boxes\$vmName"
    $boxName = "$vmName-$provider.box"

    & vagrant box add "$vmName" "$rootPath\$boxName" --provider $provider
}

function Install-VirtualBoxBaseBox {
    Param (
        $vmName
    )

    $provider = "virtualbox"
    $rootPath = "boxes\$vmName"
    $boxName = "$vmName-$provider.box"

    & vagrant box add "$vmName" "$rootPath\$boxName" --provider $provider
}

function Uninstall-HyperVBaseBox {
    Param (
        $vmName
    )

    $provider = "hyperv"

    & vagrant box remove "$vmName" --provider $provider
}

function New-HyperVBaseBox {
    Param (
        $vmName
    )

    $provider = "hyperv"
    $rootPath = ".\boxes\$vmName"
    $logPath = "$rootPath\$vmName-$provider.new.log"

    if (!(Test-Path $rootPath))
    {
         mkdir $rootPath
    }

    write-host "vagrant veewee vbox build ""$vmName"" --force --auto --provider $provider > ""$logPath"""
    & veewee hyperv build "$vmName" --force --auto --provider $provider > "$logPath"
}

function Uninstall-VirtualBoxBaseBox {
    Param (
        $vmName
    )

    $provider = "virtualbox"

    & vagrant box remove "$vmName" --provider $provider
}

function New-VirtualBoxBaseBox {
    Param (
        $vmName
    )

    $provider = "virtualbox"
    $rootPath = ".\boxes\$vmName"
    $logPath = "$rootPath\$vmName-$provider.new.log"

    if (!(Test-Path $rootPath))
    {
         mkdir $rootPath
    }

    & veewee vbox build "$vmName" --force --auto --provider $provider > "$logPath"
}

function Get-ValidHyperVVmName {
    Param (
        $vmName
    )

    While(Get-VM -name $vmName -erroraction 'silentlycontinue')
    {
        $vmName = $vmName + "_1"
    }

    return $vmName
}

function Get-ValidVirtualBoxVmName {
    Param (
        $vmName
    )

    $virtualBoxInstances = & vboxmanage list vms | %{
        $_ -replace '"(.*)".*','$1'
    }

    While($virtualBoxInstances -contains $vmName)
    {
        $vmName = $vmName + "_1"
    }

    return $vmName
}

function GetSwitch {
    Param (
        $switches,
        $networkType, 
        $switchName
    )

    switch ($networkType)
    {
        "Internal" {
            if ($switchName)
            {
                $switch = $switches | ?{ $_.SwitchType -eq "Internal" -and $_.Name -eq $switchName } | Select-Object -first 1
                if (!$switch) {
                    throw "There are no internal network switches with a name of $switchName"
                }
            } else {
                $switch = $switches | ?{ $_.SwitchType -eq "Internal" } | Select-Object -first 1
                if ($switch -eq $null) {
                    throw "There are no internal network switches"
                }
            }

            return $switch
        }
        "Private" {
            if ($switchName)
            {
                $switch = $switches | ?{ $_.SwitchType -eq "Private" -and $_.Name -eq $switchName } | Select-Object -first 1
                if ($switch -eq $null) {
                    throw "There are no private network switches with a name of $switchName"
                }
            } else {  
                $switch = $switches | ?{ $_.SwitchType -eq "Private" } | Select-Object -first 1
                if ($switch -eq $null) {
                    throw "There are no private network switches"
                }
            }
            return $switch
        }
        "External" {
            if ($switchName)
            {            
                $switch = $switches | ?{ $_.SwitchType -eq "External" -and ($_.Name -eq $switchName -or $_.NetAdapterInterfaceDescription -eq $switchName) } | Select-Object -first 1
                if ($switch -eq $null) {
                    throw "There are no external network switches with a name of $switchName"
                }  
            } else {
                $switch = $switches | ?{ $_.SwitchType -eq "External" } | Select-Object -first 1
                if (!$switch) {
                    throw "There are no external network switches"
                }                      
            }

            return $switch
        }
        default {
            throw "$networkType is not a known network type"
        }
    }    
}

function New-HyperVInstance {
     Param (
        $vmName,
        $virtualMachinesHomePath = "$env:VAGRANT_HOME\Boxes",
        $memoryStartupBytes = 512MB,
        $numberOfProcessors = 4,
        $networkCards = @("PriceListMan"),
        $hardDrives= @()
    )

    $ErrorActionPreference = "Stop"

    $vmName = Get-ValidHyperVVmName -vmName $vmName

    New-VM -Name $vmName -path $virtualMachinesHomePath -MemoryStartupBytes $MemoryStartupBytes -NoVHD

    Set-VMProcessor -VMName $vmName -Count $numberOfProcessors

    $switches = Get-VMSwitch

    $networkCards | %{
        $networkType = $_.Type

        $switchName = $_.Name

        Write-Host "Network type: $networkType"
        Write-Host "Switch name: $switchName"

        $switch = GetSwitch -switches $switches -networkType $networkType -switchName $switchName

        Write-Host "Switch is $switch"
        Add-VMNetworkAdapter -VMName $vmName -Switchname $switch.Name
    }

    $hardDrives | %{
        $vhdxDestinationDrivePath = $_
        Add-VMHardDiskDrive -VMName $vmName -path $vhdxDestinationDrivePath
    }

    Start-Vm -Name $vmName
}

function New-VirtualBoxInstance {
     Param (
        $vmName,
        $virtualMachinesHomePath = "$env:VAGRANT_HOME\Boxes",
        $memoryStartupBytes = 512MB,
        $numberOfProcessors = 4,
        $networkCards = @("PriceListMan"),
        $hardDrives= @()
    )

    $ErrorActionPreference = "Stop"

    $vmName = Get-ValidVirtualBoxVmName -vmName $vmName
    $memory = $memoryStartupBytes / 1MB

    & VBoxManage createvm --name $vmName --ostype "Windows2008_64" --register
    & VBoxManage modifyvm $vmName --memory $memory
    & VBoxManage modifyvm $vmName --cpus $numberOfProcessors --ioapic on
    & VBoxManage modifyvm $vmName --boot1 disk --boot2 none --boot3 none --boot4 none    
    & VBoxManage modifyvm $vmName --memory $memory --vram 32

    $deviceCount = 65
    $hardDrives | %{
        $vdiDestinationDrivePath = $_
        $driveLetter = [char]$deviceCount
        $hddName = "hd$driveLetter"
        & VBoxManage modifyvm $vmName --$hddName $vhdxDestinationDrivePath

        $deviceCount = $deviceCount + 1
    }

    $networkCount = 1
    $networkCards | %{
        $networkType = $_.Type

        $switchName = $_.Name
        $nicName = "nic$networkCount"
        $cableConnected = "cableconnected$networkCount"

        if ($_.InternalNetwork)
        {
            return @{Type="Internal";Name=$_.InternalNetwork.Name;}
        } elseif ($_.NAT) {
            return @{Type="Private";Name="";}
        } elseif ($_.NATNetwork) {
            return @{Type="Internal";Name=$_.NATNetwork.Name;}
        } elseif ($_.BridgedInterface) {
            return @{Type="External";Name=$_.BridgedInterface.Name;}
        } elseif ($_.HostOnlyInterface) {
            return @{Type="Internal";Name=$_.HostOnlyInterface.Name;}
        }

        switch ($networkType)
        {
            "Internal" {
                $virtualboxNetworkType = "intnet"
                if ($switchName)
                {
                    $switch = & vboxmanage list intnets | %{$_ -replace 'name\:\s*(.*)', '$1'} | ?{$_ -eq $switchName} | Select-Object -First 1

                    if (!$switch) {
                        $virtualboxNetworkType = "natnetwork"
                        $switch = & vboxmanage list natnets | ?{$_ -match 'NetworkName\:'} | %{$_ -replace 'NetworkName\:\s*(.*)', '$1'} | ?{$_ -eq $switchName} | Select-Object -First 1
                    }

                    if (!$switch) {
                        $virtualboxNetworkType = "hostonly"
                        $switch = & vboxmanage list hostonlyifs | ?{$_ -match 'VBoxNetworkName\:'} | %{$_ -replace 'VBoxNetworkName\:\s*(.*)', '$1'} | ?{$_ -eq $switchName} | Select-Object -First 1
                    }

                    if (!$switch){
                        $switch = "none"
                    }

                    if (!$switch) {
                        throw "There are no internal network switches with a name of $switchName"
                    }
                } else {
                    $switch = & vboxmanage list intnets | %{$_ -replace 'name\:\s*(.*)', '$1'} | Select-Object -First 1

                    if (!$switch) {
                        $virtualboxNetworkType = "natnetwork"
                        $switch = & vboxmanage list natnets | ?{$_ -match 'NetworkName\:'} | %{$_ -replace 'NetworkName\:\s*(.*)', '$1'} | Select-Object -First 1
                    }

                    if (!$switch) {
                        $virtualboxNetworkType = "hostonly"
                        $switch = & vboxmanage list hostonlyifs | ?{$_ -match 'VBoxNetworkName\:'} | %{$_ -replace 'VBoxNetworkName\:\s*(.*)', '$1'} | Select-Object -First 1
                    }

                    if (!$switch){
                        $switch = "none"
                    }

                    if ($switch -eq $null) {
                        throw "There are no internal network switches"
                    }
                }

                $adapter = "hostonlyadapter$networkCount"
                $adapterSwitch = "'$switch'"

                &vboxmanage modifyvm --$nicName $virtualboxNetworkType --$adapter $adapterSwitch --$cableConnected on
            }
            "Private" {
                $virtualboxNetworkType = "nat"
                if ($switchName)
                {
                    $switch = $switches | ?{ $_.SwitchType -eq "Private" -and $_.Name -eq $switchName } | Select-Object -first 1

                    if (!$switch){
                        $switch = "none"
                    }

                    if ($switch -eq $null) {
                        throw "There are no private network switches with a name of $switchName"
                    }
                } else {  
                    $switch = $switches | ?{ $_.SwitchType -eq "Private" } | Select-Object -first 1

                    if (!$switch){
                        $switch = "none"
                    }

                    if ($switch -eq $null) {
                        throw "There are no private network switches"
                    }
                }

                $adapter = "hostonlyadapter$networkCount"
                $adapterSwitch = "'$switch'"

                &vboxmanage modifyvm --$nicName $virtualboxNetworkType --$adapter $adapterSwitch --$cableConnected on
            }
            "External" {
                $virtualboxNetworkType = "bridged"
                if ($switchName)
                {            
                    $switch = $switches | ?{ $_.SwitchType -eq "External" -and ($_.Name -eq $switchName -or $_.NetAdapterInterfaceDescription -eq $switchName) } | Select-Object -first 1

                    if (!$switch){
                        $switch = "none"
                    }

                    if ($switch -eq $null) {
                        throw "There are no external network switches with a name of $switchName"
                    }  
                } else {
                    $switch = $switches | ?{ $_.SwitchType -eq "External" } | Select-Object -first 1

                    if (!$switch){
                        $switch = "none"
                    }

                    if (!$switch) {
                        throw "There are no external network switches"
                    }                      
                }

                $adapter = "bridgeadapter$networkCount"
                $adapterSwitch = "'$switch'"

                &vboxmanage modifyvm --$nicName $virtualboxNetworkType --$adapter $adapterSwitch --$cableConnected on
            }
            default {
                throw "$networkType is not a known network type"
            }
        }
        
        $networkCount = $networkCount + 1
    }

    & VBoxManage startvm $vmName
}

function Convert-VirtualBoxBaseBoxToHyperVInstance {
    Param (
        $vmName,
        $vmVersion = 0
    )

    $ErrorActionPreference = "Stop"

    $srcPath = "$env:VAGRANT_HOME\Boxes\$vmName\$vmVersion\virtualbox"

    $ovfPath = "$srcPath\box.ovf"

    $machineConfig = Get-OvfFormat -path $ovfPath

    $validVmName = Get-ValidHyperVVmName $machineConfig.name

    $destinationPath = "$env:VAGRANT_HOME\Boxes\$($machineConfig.name)\Virtual Hard Disks"

    $harddrives = $machineConfig.hardDrives | %{
        return Convert-VmdkToVhdx $_.Path.FullName
    }

    New-HyperVInstance -vmName $machineConfig.name -memoryStartupBytes $machineConfig.memoryStartupBytes -numberOfProcessors $machineConfig.numberOfProcessors -networkCards $machineConfig.networks -hardDrives $harddrives
}

function Convert-HyperVBaseBoxToVirtualBoxInstance {
    Param (
        $vmName,
        $vmVersion = 0
    )

    $ErrorActionPreference = "Stop"

    $srcPath = "$env:VAGRANT_HOME\Boxes\$vmName\$vmVersion\hyperv"

    $hyperVXmlPath = Get-ChildItem "$srcPath\Virtual Machines" -Filter *.xml | Select-Object -First 1

    $machineConfig = Get-HyperVFormat -path $ovfPath -vmName $vmName

    $validVmName = Get-ValidVirtualBoxVmName $machineConfig.name

    $destinationPath = "$env:VAGRANT_HOME\Boxes\$($machineConfig.name)"

    $harddrives = $machineConfig.hardDrives | %{
        return Convert-VhdxToVdi $_.Path.FullName
    }

    New-VirtualBoxInstance -vmName $machineConfig.name -memoryStartupBytes $machineConfig.memoryStartupBytes -numberOfProcessors $machineConfig.numberOfProcessors -networkCards $machineConfig.networks -hardDrives $harddrives}

function Get-RunningHyperVFormat {
    Param (
        $vmName
    )

    $ErrorActionPreference = "Stop"

    $memoryStartupBytes = [int](Get-VMMemory $vmName).StartUp
    $numberOfProcessors = [int](Get-VMProcessor $vmName).Count

    $networks = Get-VMNetworkAdapter $vmName | %{
        $switchName = $_.SwitchName
        $switch = Get-VmSwitch $switchName
        $switchType = $switch.SwitchType
        return @{Type=$switchType;Name=$switchName;}
    }

    $harddrives = Get-VMHardDiskDrive -VMName $vmName | %{
        return $_.Path
    }

    return @{name=$vmName;memoryStartupBytes=$memoryStartupBytes;numberOfProcessors=$numberOfProcessors;networks=$networks;harddrives=$harddrives;}
}



function Get-HyperVFormat {
    Param (
        $path,
        $vmName,
        $switches = (Get-VMSwitch)
    )
    $ErrorActionPreference = "Stop"

    $parentPath = get-item $path
    $hypervXml = [xml] (Get-Content $parentPath.FullName)

    $memoryStartupBytes = [int] $hypervXml.configuration.settings.memory.bank.limit.InnerText
    $numberOfProcessors = [int] $hypervXml.configuration.settings.processors.count.InnerText

    $networks =  $hypervXml.configuration.GetEnumerator() | ? {$_.Connection} | % {
        $switchName = $_.Connection.AltSwitchName.InnerText
        $switch = $switches | ?{ $_.Name -eq $switchName}
        if ($switch) {
            return @{Type=$switch.SwitchType;Name=$switch.Name;}
        } else {
            throw "Switch with name $($switchName) does not exist. Unable to get switch type."
        }
    }

    $harddrives = @()

    $hypervXml.configuration.GetEnumerator() | % {
        for ($i=0; $i -le 5; $i++)
        {
            $controllerName = "controller$i"
            $controller = $_[$controllerName]
            if ($controller)
            {
                for ($j=0; $j -le 5; $j++)
                {
                    $driveName = "drive$j"
                    $drive = $controller[$driveName]

                    if ($drive -and $drive.type.InnerText -eq "VHD") {
                        $harddrives += $drive.pathname.InnerText
                    }
                }
            }
        }
    }

    return @{name=$vmName;memoryStartupBytes=$memoryStartupBytes;numberOfProcessors=$numberOfProcessors;networks=$networks;harddrives=$harddrives;}    
}

function Get-OvfFormat {
    param (
        $path
    )

    $ErrorActionPreference = "Stop"

    $parentPath = get-item $path
    $ovf = [xml] (Get-Content $parentPath.FullName)
    $name = $ovf.Envelope.VirtualSystem.Machine.name
    $memoryStartupBytes = ([int]$ovf.Envelope.VirtualSystem.Machine.Hardware.Memory.RAMSize )* 1mb
    $numberOfProcessors = [int]$ovf.Envelope.VirtualSystem.Machine.Hardware.CPU.count

    $networks = $ovf.Envelope.VirtualSystem.Machine.Hardware.Network.Adapter |?{$_.enabled -eq "true"} | %{
        if ($_.InternalNetwork)
        {
            return @{Type="Internal";Name=$_.InternalNetwork.Name;}
        } elseif ($_.NAT) {
            return @{Type="Private";Name="";}
        } elseif ($_.NATNetwork) {
            return @{Type="Internal";Name=$_.NATNetwork.Name;}
        } elseif ($_.BridgedInterface) {
            return @{Type="External";Name=$_.BridgedInterface.Name;}
        } elseif ($_.HostOnlyInterface) {
            return @{Type="Internal";Name=$_.HostOnlyInterface.Name;}
        }
    }

    $harddrives = $ovf.Envelope.DiskSection.Disk | %{
        $fileRef = $_.fileRef
        $diskPath = $ovf.Envelope.References.File | ?{$_.id -eq $fileRef} | %{$_.href} 

        $diskPath = Get-Item "$($parentPath.Directory.FullName)\$diskPath"

        return @{path=$diskPath;}
    }

    return @{name=$name;memoryStartupBytes=$memoryStartupBytes;numberOfProcessors=$numberOfProcessors;networks=$networks;harddrives=$harddrives;}
}