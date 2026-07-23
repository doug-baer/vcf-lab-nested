# vcf-lab-nested
Create vESX host infrastructure and foundational JSON for installing VCF into a lab.

****NOTE****
All of this is very much in progress and shouldn't be used by anyone except as a reference (maybe).
************

This project is evolving form a need to create standardized environments for VCF and VVF test cases. The focus is on the "Day 0" (and "Day -1") configuration of VCF's underlying compute components to facilitate the installation of VCF or VVF on virtual machines in a non-production (lab) environment.

The initial script creates the VMs needed to install ESX since getting all of the parts correct was tedious, especially when nesting vSAN ESA's required virtual NVMe devices. It has evolved to using an http-based build server to stream the ESX image and kickstart it by passing initial boot values into UEFI and powering up the VMs. 

My typical installation is broken into 4 phases based on the requirements to show different aspects of the product. 

Lately, I have been focused on building components required to demonstrate the new "clean room" functionality available in VCF 9.1 with the Advanced Cyber Compliance (ACC) licenses. 

There are two main configurations: "blue" and "green" to represent two virtually identical but separate environments -- one will be "live" while the other will be for test/dev or early access. To that end, the "blue" and "green" environments in this project may loosely model two-site configurations: 

1. Management Domain (Recovery Site VCF)
2. Workload Domain (Recovery Site compute - default is HCI vSAN ESA datastore)
3. (optional) vSAN Storage Cluster hosts for WLD if not using HCI (shrink the disks in the WLD hosts if using Storage Cluster model)
4. Protected Site (VVF deployment)

Each batch of host VMs is created using the "-Build" option to the Manage-vESX.ps1 script and then the VMs are moved to the trunk port using the "-Move" option.
This is to simplify physical-layer networking requirements and not require that the access VLAN on the trunk be the same as the "management" VLAN.

The "yellow" lab environment is a more fluid environment that is intended to follow the main pattern of "blue" and "green," but may be redeployed more frequently as it is repurposed for various teams' use and requirements. For example, it may be a clean room one week and a multi-cluster with VKS and Automation test the next month. 

At this time, "blue" has just been migrated but is untested, so "green" is the most stable while "yellow" is the most up to date.

July 23, 2026