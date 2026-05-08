# vcf-lab-nested
Create vESX host infrastructure and foundational JSON for installing VCF into a lab.

The initial script created the VMs needed to install ESX in a test lab since getting all of the parts correct was tedious, especially when nesting vSAN ESA (virtual NVMe devices), but this also uses an http-based build server to stream the ESX image and kickstart it by passing initial boot values into UEFI. (that will be a separate project)

Broken into 4 phases:
1. Management Domain (Recovery Site VCF)
2. Workload Domain (Recovery Site compute - default is HCI vSAN ESA datastore)
3. (optional) vSAN Storage Cluster hosts for WLD if not using HCI
4. VVF deployment (Protected Site)

Each batch of host VMs is created using the "Build" script and then the VMs are moved to the trunk port using the Move script.
This is to simplify physical-layer networking requirements.

Note that there will be two configurations: "blue" and "green" to represent two virtually identical environments. 

TODO: Also note that there is a lot of opportunity to refactor the code to make it more efficient and reduce the duplication of code across files and phases to use parameters rather than completely identical code blocks. The "Manage-vESX.ps1" is a step in this direction but is still in progress. 

May 2026