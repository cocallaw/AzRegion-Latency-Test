# Azure Region Latency Test

## Latency Test

Azure consists of multiple regions across the world, latency and bandwidth is important to understand when designing a network topology that spans across multiple regions in Azure. 

This script provides a simplified way to test the latency between three Azure regions, using a repeatable process to help you understand the approximate latency between the regions.

**requirements:**

* Azure Subscription
* Core quota assigned to the subscription
* Ability to connect to the VMs using SSH (Public IP addresses)
* PowerShell Core 7.2 or newer
* PowerShell modules Posh-SSH and Az

### What the script does

The script creates a virtual network and Linux VM in each of the Azure regions specified. The virtual networks are connected using VNet Peering to allow the VMs deployed to communicate over Azure private network space. Once the resources are deployed, the script will run qperf to test the latency and throughput between the VMs.

You can decide to use qperf or niping (SAP tool) to test the latency and bandwidth.
If you want to use niping please provide a URL to e.g. a BLOB storage which provides direct access to the niping executable.
The output for qperf and niping is the same.

### How to run the Script
`AzRegion-Latency-Test.ps1 -SubscriptionName myAzureSubscription -region1 eastus -region2 eastus2 -region3 westus`
### Sample Output

        Getting Hosts for virtual machines
        VM1 : AMS07XXXXXXXXXX
        VM2 : AMZ07XXXXXXXXXX
        VM3 : AMS21XXXXXXXXXX


        Region1: eastus
        Region2: eastus2
        Region3: westus
        VM Type: Standard_F4s_v2
        Latency:
                 ----------------------------------------------
                 |   region 1   |   region 2   |   region 3   |
        -------------------------------------------------------
        |region 1|              |        xx us |        xx us |
        |region 2|        xx us |              |        xx us |
        |region 3|        xx us |        xx us |              |
        -------------------------------------------------------

        Bandwidth:
                 ----------------------------------------------
                 |   region 1   |   region 2   |   region 3   |
        -------------------------------------------------------
        |region 1|              |   xxx MB/sec |   xxx MB/sec |
        |region 2|   xxx MB/sec |              |   xxx MB/sec |
        |region 3|   xxx MB/sec |   xxx MB/sec |              |
        -------------------------------------------------------

Based on the output you can decide which region and network topology you would like to to use.
To calculate the latency and bandwidth for a multi-region topology, it is recommended to run the test multiple times and average the results.

## Notes
The following items are currently under development and may not work as expected:
- UseExistingVnet option set to $true
- UseExistingVMs option set to $true
- UsePublicIPAddresses set to $false
- Utilizing niping to test the latency instead of qperf
## Acknowledgements
Original concept and code by: [AvZone-Latency-Test.ps1](https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities/tree/main/AvZone-Latency-Test)

https://github.com/Azure/SAP-on-Azure-Scripts-and-Utilities

Copyright (c) Microsoft Corporation.

Licensed under the MIT license.