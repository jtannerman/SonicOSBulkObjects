####  A script to read a correctly formatted CSV file and add SonicWALL Address Objects in bulk via SonicOS API ###
####  CSV should have headers Name, Zone , IPAddress ####
####  Name values and Zone values are strings.  IPAddress values should be in CIDR notation, even single hosts (/32) 
####  This only works with basic authentication (username/password). 

$ErrorActionPreference = 'Stop'
$Timestamp = get-date -Format "yyyyMMdd_HHmmss"

#Get URL, User, and Password for the SonicWALL
#SonicOSURL = "https://192.168.122.254:443"
$SonicOSURL = Read-Host "Enter full SonicWALL URL (https://<sonicwall-address>:<mgmt-port>)"
$SonicOSUserName = Read-Host "Username"
$SonicOSPass = Read-Host "Password"
$SonicOSAuthString = $SonicOSUserName + ':' + $SonicOSPass
$SonicOSAuthBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($SonicOSAuthString))

#Grab address object data from CSV file.
#$PathToCSV = "c:\scripts\jsontest\test-import.csv"
$PathToCSV = Read-Host "Enter path to CSV file"
try {
    $AddressObjects = Import-CSV $PathToCSV
}
catch {
    write-error "An error occured: $_"
}

$JsonOutputFolder = Split-Path -Parent $PathToCSV

#Create an empty array. We store objects in this before converting to JSON all at once.
$AOArray = @()

# Loop over the content of the CSV. Identify the network prefix length. Determine if object is host or network. Build the appropriate objects using the CSV data.
foreach ($AddressObject in $AddressObjects) {   
    $ObjIP = $AddressObject.IPAddress
    $SlashIndex = $ObjIP.IndexOf("/")
    $PrefixLength = [int]$ObjIP.substring($SlashIndex + 1)
    $RawIP = $ObjIP.substring(0,$SlashIndex)

    # Test if the prefix length is exactly 32, indicating this is a single host.
    if ($PrefixLength -eq 32) {
        write-host $AddressObject.Name "("$AddressObject.IPAddress")" "is a single host."
        # Build key-value pairs from the CSV data and store them in objects. Nest them to match the JSON model for a SonicWALL ip4 host object.
        $hostValue = [PSCustomObject]@{ 
            ip = $RawIP
        }
        $ipv4Value = [PSCustomObject]@{
            name = $AddressObject.Name
            zone = $AddressObject.Zone
            host = $hostValue
        }
        $address_objectsValue = [PSCustomObject]@{
            ipv4 = $ipv4Value
        }
        # Append nested object collection to the array for storage.
        $AOArray += $address_objectsValue
    }

    # If network prefix is not 32, this indicates a network rather than a single host.   
    else {
        #Build the subnet mask from the CIDR network prefix, using math dawg.
        $SubnetMask = [string]::Empty
        $BitMask = ('1' * $PrefixLength).PadRight(32, '0')
        for($i=0;$i -lt 32;$i+=8) {
            $ByteMask = $BitMask.substring($i,8)
            $SubnetMask += "$([Convert]::ToInt32($ByteMask, 2))."
        }
        #Subnet mask last octect ends up with an extra '.' at the end, so we trim that off.
        $CleanSubnetMask = $SubnetMask.TrimEnd('.')
        write-host $AddressObject.Name"("$AddressObject.IPAddress")" "is a network. The subnet mask is"$CleanSubnetMask

        # Build key-value pairs from CSV data and store them in objects. Nest them to match the JSON model for a SonicWALL ip4 network object.
        $networkValue = [PSCustomObject]@{
            subnet = $RawIP
            mask = $CleanSubnetMask
        }
        $ipv4Value = [PSCustomObject]@{
            name = $AddressObject.Name
            zone = $AddressObject.Zone
            network = $networkValue
        }
        $address_objectsValue = [PSCustomObject]@{
            ipv4 = $ipv4Value
        }
        # Append nested object collection to the array.
        $AOArray += $address_objectsValue
    }    
}


# Create another object to hold our array, which holds our nested object collections, which hold our key-value pairs. Woah.
$HostAndNetworkObjects = [PSCustomObject]@{
    address_objects = $AOArray      
}
# Convert the PS Object to JSON and specify the depth.
$FinalJsonToSend = $HostAndNetworkObjects | ConvertTo-JSON -Depth 5

# Write the JSON to the console to have a look-see before we start making API calls.  This will probably not be needed after testing.
$FinalJsonToSend | Out-File $JsonOutputFolder\$Timestamp-request-body.txt
#write-host "Your JSON will Look like this:"
#write-host $FinalJsonToSend

#Connect to SonicOS API, ignoring certificate errors.  Authenticate, enter config mode, submit address objects, write pending config changes, logoff.

add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

$Headers =@{
    'Accept' = 'application/Json'
    'Authorization' = 'Basic ' + $SonicOSAuthBase64
    }

try {
    $APIResponse = Invoke-WebRequest -uri ($SonicOSURL + "/api/sonicos/auth") -Method POST -ContentType 'application/json; charset=utf-8' -Headers $Headers -Body '{"override" : "true"}'
}
catch {
    write-error "An error occurred: $_"
    write-host $APIResponse
}
try {
    $APIResponse = Invoke-WebRequest -uri ($SonicOSURL + "/api/sonicos/config-mode") -Method POST -ContentType 'application/json; charset=utf-8' -Headers $Headers
}
catch {
    write-error "An error occurred: $_"
    write-host $APIResponse
}
try {
    $APIResponse = Invoke-WebRequest -uri ($SonicOSURL + "/api/sonicos/address-objects/ipv4") -Method POST -ContentType 'application/json; charset=utf-8' -Headers $Headers -Body $FinalJsonToSend
}
catch {
    write-error "An error occurred: $_"
    write-host $APIResponse
}
try {
    $APIResponse = Invoke-WebRequest -uri ($SonicOSURL + "/api/sonicos/config/pending") -Method POST -ContentType 'application/json; charset=utf-8' -Headers $Headers
}
catch {
    write-error "An error occurred: $_"
    write-host $APIResponse
}
try {
    $APIResponse = Invoke-WebRequest -uri ($SonicOSURL + "/api/sonicos/auth") -Method DELETE -ContentType 'application/json; charset=utf-8' -Headers $Headers
}
catch {
    write-error "An error occurred: $_"
    write-host $APIResponse
}


write-host "Address Objects Imported!"
#this is the end


