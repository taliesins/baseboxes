Import-Module ".\BaseBoxes"
$vmName = "talifun-windows2012R2-server-amd64"
$description = "This box contains Windows Server 2012 R2 64-bit."
$version = "1.0.0"
$baseUrl = "http://atlas.hashicorp.com/boxes/"

Export-HyperVBaseBox -vmName $vmName -description $description -version $version -baseUrl $baseUrl
