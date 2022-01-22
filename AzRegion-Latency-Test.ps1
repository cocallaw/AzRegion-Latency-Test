<#

.SYNOPSIS
    Creates VMs and tests latency between the VMs in differnet Azure locations

.DESCRIPTION
    The script creates VMs in specified Regions 1, 2 and 3, installing qperf and testing latency between the created VMs

.PARAMETER Region
    The Azure region name

.EXAMPLE
    ./AzRegion-Latency-Test.ps1 -Region1 centralus -Region2 eastus -Region3 westus

    Example output:

        Region1:  centralus
        Region2:  eastus
        Region3:  westus
        VM Type:  Standard_E8s_v3
        Latency:
                 ----------------------------------------------
                 |   Region 1   |   Region 2   |   Region 3   |
        -------------------------------------------------------
        |Region 1|              |        xx us |        xx us |
        |Region 2|        xx us |              |        xx us |
        |Region 3|        xx us |        xx us |              |
        -------------------------------------------------------

        Bandwidth:
                 ----------------------------------------------
                 |   Region 1   |   Region 2   |   Region 3   |
        -------------------------------------------------------
        |Region 1|              |   xxx MB/sec |   xxx MB/sec |
        |Region 2|   xxx MB/sec |              |   xxx MB/sec |
        |Region 3|   xxx MB/sec |   xxx MB/sec |              |
        -------------------------------------------------------

.LINK


.NOTES

#>
<#
Original concept and code by: AvZone-Latency-Test.ps1
https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities
Copyright (c) Microsoft Corporation.
Licensed under the MIT license.
#>

#Requires -Modules Posh-SSH
#Requires -Modules Az.Compute
#Requires -Version 5.1
#requires -PSEdition Desktop

param(
    #Azure Subscription Name
    [Parameter(Mandatory=$true)][string]$SubscriptionName,
    #Azure Region 1, use Get-AzLocation to get region names
    [Parameter(Mandatory=$true)][string]$region1 = "centralus", 
    #Azure Region 2, use Get-AzLocation to get region names
    [Parameter(Mandatory=$true)][string]$region2 = "eastus", 
    #Azure Region 3, use Get-AzLocation to get region names
    [Parameter(Mandatory=$true)][string]$region3 = "westus",  
    #Resource Group Name that will be created
    [string]$ResourceGroupName = "AzRegionLatencyTest", 
    #Delete the test environment after test
    [boolean]$DestroyAfterTest = $true, 
    #Use an existing VNET, direct SSH connection to VMs required
    [boolean]$UseExistingVnet = $false, 
    #use existing VMs of a previous test
    [boolean]$UseExistingVMs = $false, 
    #use public IP addresses to connect
    [boolean]$UsePublicIPAddresses = $true, 
    # VM type, recommended Standard_D8s_v3
    [string]$VMSize = "Standard_D8s_v3", 
    #OS provider, for CentOS it is OpenLogic
    [string]$OSPublisher = "OpenLogic", 
    #OS Type
    [string]$OSOffer = "CentOS", 
    #OS Verion
    [string]$OSSku = "8.0", 
    #Latest OS image
    [string]$OSVersion = "latest", 
    #OS username
    [string]$VMLocalAdminUser = "azping", 
    #OS password
    [string]$VMLocalAdminPassword = "P@ssw0rd!", 
    #VM name prefix, 1,2,3 will be added based on zone
    [string]$VMPrefix = "azping-vm0", 
    #VM nic name
    [string]$NICPostfix = "-nic1", 
    #Public IP address postfix
    [string]$pippostfix = "-pip", 
    #Azure Network Security Group (NSG) name
    [string]$NSGName = "azping-nsg", 
    #Azure VNET name, if using existing VNET
    [string]$NetworkName = "azping-vnet", 
    #Azure Subnet name, if using exising
    [string]$SubnetName = "default", 
    #Resource Group Name of existing VNET
    [string]$ResourceGroupNameNetwork = "azping-mgmt", 
    #Azure IP Subnet prefix if using public IP to VNET creation
    [string]$SubnetAddressPrefix = "10.1.1.0/24", 
    #Azure IP VNET prefix if using public IP to VNET creation
    [string]$VnetAddressPrefix = "10.1.1.0/24",
    #decide to use qperf or niping
    [ValidateSet("qperf","niping")][string]$testtool = "qperf",
    #path to niping
    [string]$nipingpath
)

    if ($testtool -eq "niping") {
        if (!$nipingpath) {
            $nipingpath = Read-Host -Prompt "Please enter download path for niping executable: "
        }
           
    }

	# select subscription
	$Subscription = Get-AzSubscription -SubscriptionName $SubscriptionName
    if (-Not $Subscription) {
        Write-Host -ForegroundColor Red -BackgroundColor White "Sorry, it seems you are not connected to Azure or don't have access to the subscription. Please use Connect-AzAccount to connect."
        exit
    }


    Select-AzSubscription -Subscription $SubscriptionName -Force

    $VMLocalAdminSecurePassword = ConvertTo-SecureString $VMLocalAdminPassword -AsPlainText -Force

    $zones = 3

    
    #create the secure credential object
	$Credential = New-Object System.Management.Automation.PSCredential ($VMLocalAdminUser, $VMLocalAdminSecurePassword);

    # initialize the arrays for outputs
    $latency = @(("","",""),("","",""),("","",""))
    $bandwidth = @(("","",""),("","",""),("","",""))

    for ($x=1; $x -le $zones; $x++) {
        for ($y=1; $y -le 3; $y++) {
            $latency[$x-1][$y-1] = "0"
            $bandwidth[$x-1][$y-1] = "0"
        }
    }

    #create information object
    $regionParams = @($region1, $region2, $region3)
    $regionInfo = @()
    for ($y=1; $y -le 3; $y++) {
        $newObject = New-Object -TypeName PSObject -Property @{
            regionCount = $y
            regionLocation = $regionParams[$y-1]
            nsgName = $NSGName+"-"+$y
            SubnetAddressPrefix = "10.1.$y.0/24"
            VnetAddressPrefix = "10.1.$y.0/24"
            NetworkName = $NetworkName+"-"+$y
        }
        $regionInfo += $newObject
    }


    if ($UseExistingVMs) {
        Write-Host "Using existing VMs" -ForegroundColor Green
    }
    else {

        # create resource group
        Write-Host -ForegroundColor Green "Creating resource group $ResourceGroupName"
        $ResourceGroup = New-AzResourceGroup -Location $region1 -Name $ResourceGroupName
    
        # create vNET and Subnet or getting existing
	    if ($UseExistingVnet) {
            Write-Host -ForegroundColor Green "Getting existing vNET and Subnet Config"
            $Vnet = Get-AzVirtualNetwork -Name $NetworkName -ResourceGroupName $ResourceGroupNameNetwork
            $SingleSubnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $Vnet -Name $SubnetName
        }
        else {
            Write-Host -ForegroundColor Green "Creating vNETs, Subnets and NSGs"
            foreach ($r in $regionInfo) {
                $rule1 = New-AzNetworkSecurityRuleConfig -Name ssh-rule -Description "Allow SSH" -Access Allow -Direction Inbound -Protocol Tcp -Priority 100 -SourcePortRange * -SourceAddressPrefix * -DestinationAddressPrefix * -DestinationPortRange 22
                Write-Host -ForegroundColor Green "Creating NSG $($r.nsgName) in $($r.regionLocation)" 
                $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Location $r.regionLocation -Name $r.nsgName -SecurityRules $rule1
                $Subnet = New-AzVirtualNetworkSubnetConfig -Name $SubnetName -AddressPrefix $r.SubnetAddressPrefix -NetworkSecurityGroup $nsg
                Write-Host -ForegroundColor Green "Creating vNet $($r.NetworkName) in $($r.regionLocation)"
                $Vnet = New-AzVirtualNetwork -Name $r.NetworkName -ResourceGroupName $ResourceGroupName -Location $r.regionLocation -AddressPrefix $r.VnetAddressPrefix -Subnet $Subnet
            }
        }

        # create VM
        Write-Host -ForegroundColor Green "Creating VMs"
        foreach ($r in $regionInfo) {
            $ComputerName = $VMPrefix + $r.regionCount
            $NICName = $ComputerName + $NICPostfix
       	    $PIPName = $NICName + $pippostfix
            $vnet = Get-AzVirtualNetwork -Name $r.NetworkName -ResourceGroupName $ResourceGroupName
            $Subnet = Get-AzVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet
            if ($UsePublicIPAddresses) {
                $PIP = New-AzPublicIpAddress -Name $PIPName -ResourceGroupName $ResourceGroupName -Location $r.regionLocation -Sku Standard -AllocationMethod Static -IpAddressVersion IPv4
	            $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -PublicIpAddress $PIP -Primary
            }
            else {
                $IPConfig1 = New-AzNetworkInterfaceIpConfig -Name "IPConfig-1" -Subnet $Subnet -Primary
            }
            Write-Host -ForegroundColor Green "Creating NIC $NicName in $($r.regionLocation)"
            $NIC = New-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -Location $r.regionLocation -IpConfiguration $IpConfig1 -EnableAcceleratedNetworking
            Write-Host -ForegroundColor Green "Creating VM $ComputerName in $($r.regionLocation)"
            
            $VirtualMachine = New-AzVMConfig -VMName $ComputerName -VMSize $VMSize
            $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Linux -ComputerName $ComputerName -Credential $Credential
            $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
            $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $OSPublisher -Offer $OSOffer -Skus $OSSku -Version $OSVersion
            $VirtualMachine = Set-AzVMBootDiagnostic  -VM $VirtualMachine -Disable
            $vm = New-AzVM -ResourceGroupName $ResourceGroupName -Location $r.regionLocation -VM $VirtualMachine -Verbose -AsJob
        }

        # waiting for VM creation jobs to finish
        Write-Host -ForegroundColor Green "All VM creation jobs started, waiting to complete"
        Get-Job | Wait-Job
        Write-Host -ForegroundColor Green "All jobs completed"
        Get-AzVM -ResourceGroupName $ResourceGroupName

        # hold time for VMs to be fully ready
        Write-Host -ForegroundColor Green "Holding for two minute for all VMs to come up ."
        Start-Sleep -Seconds 60
        Write-Host -ForegroundColor Green "60 seconds remaining"
        Start-Sleep -Seconds 60
        Write-Host -ForegroundColor Green "Two minute hold for all VMs to come up complete"
       
    }

    # creating SSH sessions to VMs

    Get-SSHTrustedHost | Remove-SSHTrustedHost

    Write-Host -ForegroundColor Green "Creating SSH sessions"
    For ($zone=1; $zone -le $zones; $zone++) {
        $ComputerName = $VMPrefix + $zone
        $pipname = $VMPrefix + $zone + $NICPostfix + $pippostfix 
        $NICName = $ComputerName + $NICPostfix

        if ($UsePublicIPAddresses) {
			$pipname = $VMPrefix + $zone + $NICPostfix + $pippostfix 
			$PIP = Get-AzPublicIpAddress -Name $pipname
			$ipaddress = $PIP.IpAddress
        }
        else {
			$nic = Get-AzNetworkInterface -Name $NICName
			$networkinterfaceconfig = Get-AzNetworkInterfaceIpConfig -NetworkInterface $nic
            $ipaddress = $networkinterfaceconfig.PrivateIpAddress
        }
        $sshsession = New-SSHSession -ComputerName $ipaddress -Credential $Credential -AcceptKey -Force
    }

    $sshsessions = Get-SSHSession


    Write-Host -ForegroundColor Green "Getting Hosts for virtual machines"
    For ($zone=1; $zone -le $zones; $zone++) {

        $output = Invoke-SSHCommand -Command "cat /var/lib/hyperv/.kvp_pool_3 | sed 's/[^a-zA-Z0-9]//g' | grep -o -P '(?<=HostName).*(?=HostingSystemEditionId)'" -SessionId $sshsessions[$zone-1].SessionId
        Write-Host ("VM$zone : " + $output.Output)

    }


    # run qperf test
    if ($testtool -eq "qperf") {
        # install qperf on all VMs
        Write-Host -ForegroundColor Green "Installing qperf on all VMs"
        For ($zone=1; $zone -le $zones; $zone++) {

            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | sudo -S yum -y install qperf" -SessionId $sshsessions[$zone-1].SessionId
            $output = Invoke-SSHCommand -Command "nohup qperf &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $vmtoping1 = $VMPrefix + (( $zone   %3)+1)
            $vmtopingno2 = ((($zone+1)%3)+1)
            $vmtoping2 = $VMPrefix + ((($zone+1)%3)+1)

            $output = Invoke-SSHCommand -Command "qperf $vmtoping1 tcp_lat" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output[1]
            $latencytemp = $latencytemp.substring($latencytemp.IndexOf("=")+3)
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno1 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "qperf $vmtoping1 tcp_bw" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output[1]
            $bandwidthtemp = $bandwidthtemp.substring($bandwidthtemp.IndexOf("=")+3)
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno1 -1] = $bandwidthtemp

            $output = Invoke-SSHCommand -Command "qperf $vmtoping2 tcp_lat" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output[1]
            $latencytemp = $latencytemp.substring($latencytemp.IndexOf("=")+3)
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno2 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "qperf $vmtoping2 tcp_bw" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output[1]
            $bandwidthtemp = $bandwidthtemp.substring($bandwidthtemp.IndexOf("=")+3)
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno2 -1] = $bandwidthtemp

        }
    }

    if ($testtool -eq "niping") {

        # download niping on all hosts and run niping server
        Write-Host -ForegroundColor Green "Installing niping on all VMs"
        For ($zone=1; $zone -le $zones; $zone++) {

            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | wget $nipingpath -O /tmp/niping" -SessionId $sshsessions[$zone-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | chmod +x /tmp/niping" -SessionId $sshsessions[$zone-1].SessionId
            $output = Invoke-SSHCommand -Command "echo $VMLocalAdminPassword | nohup /tmp/niping -s -I 0 &" -SessionId $sshsessions[$zone-1].SessionId -TimeOut 3 -ErrorAction silentlycontinue

        }

        # run performance tests
        Write-Host -ForegroundColor Green "Running bandwidth and latency tests"
        For ($zone=1; $zone -le $zones; $zone++) {

            $vmtopingno1 = (( $zone   %3)+1)
            $vmtoping1 = $VMPrefix + (( $zone   %3)+1)
            $vmtopingno2 = ((($zone+1)%3)+1)
            $vmtoping2 = $VMPrefix + ((($zone+1)%3)+1)

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 10 -L 100 -H $vmtoping1 | grep av2" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output
            $latencytemp = $latencytemp -replace '\s+', ' '
            $latencytemp = $latencytemp.Split(" ")
            $latencytemp = [string]$latencytemp[1] + " " + $latencytemp[2]
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno1 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 100000 -L 100 -H $vmtoping1 | grep tr2" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output
            $bandwidthtemp = $bandwidthtemp -replace '\s+', ' '
            $bandwidthtemp = $bandwidthtemp.Split(" .")
            $bandwidthtemp = [int]$bandwidthtemp[1] / 1024
            $bandwidthtemp = [string]([math]::ceiling($bandwidthtemp)) + " MB/s"
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno1 -1] = $bandwidthtemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 10 -L 100 -H $vmtoping2 | grep av2" -SessionId $sshsessions[$zone-1].SessionId
            $latencytemp = [string]$output.Output
            $latencytemp = $latencytemp -replace '\s+', ' '
            $latencytemp = $latencytemp.Split(" ")
            $latencytemp = [string]$latencytemp[1] + " " + $latencytemp[2]
            $latencytemp = $latencytemp.PadLeft(12)
            $latency[$zone -1][$vmtopingno2 -1] = $latencytemp

            $output = Invoke-SSHCommand -Command "/tmp/niping -c -B 100000 -L 100 -H $vmtoping2 | grep tr2" -SessionId $sshsessions[$zone-1].SessionId
            $bandwidthtemp = [string]$output.Output
            $bandwidthtemp = $bandwidthtemp -replace '\s+', ' '
            $bandwidthtemp = $bandwidthtemp.Split(" .")
            $bandwidthtemp = [int]$bandwidthtemp[1] / 1024
            $bandwidthtemp = [string]([math]::ceiling($bandwidthtemp)) + " MB/s"
            $bandwidthtemp = $bandwidthtemp.PadLeft(12)
            $bandwidth[$zone -1][$vmtopingno2 -1] = $bandwidthtemp

        }
    }
    
    # Print output
    Write-Host "Region: " $region
    Write-Host "VM Type: " $VMSize

    Write-Host "Latency:"

    Write-Host "         ----------------------------------------------"
    Write-Host "         |    zone 1    |    zone 2    |    zone 3    |"
    Write-Host "-------------------------------------------------------"
    Write-Host "| zone 1 |              |" $latency[0][1] "|" $latency[0][2] "|"
    Write-Host "| zone 2 |" $latency[1][0] "|              |" $latency[1][2] "|"
    Write-Host "| zone 3 |" $latency[2][0] "|" $latency[2][1] "|              |"
    Write-Host "-------------------------------------------------------"

    Write-Host ""
    Write-Host "Bandwidth:"

    Write-Host "         ----------------------------------------------"
    Write-Host "         |    zone 1    |    zone 2    |    zone 3    |"
    Write-Host "-------------------------------------------------------"
    Write-Host "| zone 1 |              |" $bandwidth[0][1] "|" $bandwidth[0][2] "|"
    Write-Host "| zone 2 |" $bandwidth[1][0] "|              |" $bandwidth[1][2] "|"
    Write-Host "| zone 3 |" $bandwidth[2][0] "|" $bandwidth[2][1] "|              |"
    Write-Host "-------------------------------------------------------"


    # Removing SSH sessions
    Write-Host -ForegroundColor Green "Removing SSH Sessions"
    Get-SSHSession | Remove-SSHSession -ErrorAction SilentlyContinue
    
    #destroy resource group
    if ($DestroyAfterTest) {
        Write-Host -ForegroundColor Green "Deleting Resource Group"
        Remove-AzResourceGroup -Name $ResourceGroupName -Force
    }
    else
    {
        Write-Host -ForegroundColor Green "Resource group will NOT be deleted"
    }