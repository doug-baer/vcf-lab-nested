# vcf-lab-nested
Create vESX host infrastructure and foundational JSON for installing VCF into a lab.

****NOTE****
All of this is very much in progress and shouldn't be used by anyone except maybe as a reference until I get all of the scripts tested and documentation done for all of the environments. 
************


The initial script created the VMs needed to install ESX in a test lab since getting all of the parts correct was tedious, especially when nesting vSAN ESA (virtual NVMe devices), but this also uses an http-based build server to stream the ESX image and kickstart it by passing initial boot values into UEFI. 

An example of that build server may be added here once I have the build scripts done.

My installation is broken into 4 phases based on the requirements to show different aspects of the product. 
The main goal has been to build out components required to demonstrate the new "clean room" functionality available in VCF 9.1 with the Advanced Cyber Compliance (ACC) licenses. 

To that end, ththe blue and green environments in project look to create two-site configurations: 

1. Management Domain (Recovery Site VCF)
2. Workload Domain (Recovery Site compute - default is HCI vSAN ESA datastore)
3. (optional) vSAN Storage Cluster hosts for WLD if not using HCI (shrink the disks in the WLD hosts if using Storage Cluster model)
4. Protected Site (VVF deployment)

Each batch of host VMs is created using the "Build" script and then the VMs are moved to the trunk port using the "Move" option.
This is to simplify physical-layer networking requirements and not require that the access VLAN on the trunk be the same as the "management" VLAN.

There are two configurations: "blue" and "green" to represent two virtually identical but separate environments -- one will be "live" while the other will be for test/dev or early access. In the future, I would like to provide parameters via YAML config files, but I am not there yet, so I have separate versions of the same script(s) in blue/green/yellow directtories for now.


TODO: There is a lot of opportunity to refactor the code to make it more efficient and reduce the duplication of code across files and phases to use parameters rather than completely identical code. The "Manage-vESX.ps1" is a step in this direction but is still in progress. I mostly change the CPU/RAM and disk parameters along with the set of host numbers for each type. This should be simple to build into a config.


May 15, 2026