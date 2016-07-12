param(
    $Username,
    $Password,
    $TenantId,
    $SubscriptionName,
    $VMName,
    $VMResourceGroupName,
    $StorageResourceGroupName,
    $StorageAccountName,
    $StorageContainerName,
    $ExtensionFilename,
    $SauceLabsUsername,
    $SauceLabsAccessKey
)

$testsPassed = $true

# Disable-AzureDataCollection stil prompts user. So just set the property manually.
mkdir "$ENV:AppData\Windows Azure Powershell" -Force | Out-Null
"{'enableAzureDataCollection': false}" | Out-File -FilePath "$ENV:AppData\Windows Azure Powershell\AzureDataCollectionProfile.json"

Write-Host "Prepping credentials for Azure login..."
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force;
$credentials = New-Object System.Management.Automation.PSCredential($Username, $securePassword);
Write-Host "Logging into Azure..."
Add-AzureRmAccount -ServicePrincipal -Tenant $TenantId -Credential $credentials | Out-Null

Write-Host "Selecting Azure subscription..."
Get-AzureRmSubscription -SubscriptionName $SubscriptionName | Select-AzureRmSubscription | Out-Null

Write-Host "Starting test VM..."
$vm = Start-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName | Out-Null
$ip = Get-AzureRmPublicIpAddress -ResourceGroupName $VMResourceGroupName -Name $VMName
$octopusUrl = "http://" + $ip.IpAddress

Write-Host "Uploading packed extension for use in browser testing..."
Add-Type -A 'System.IO.Compression.FileSystem'
if(Test-Path .\bluefin.zip) { Remove-Item .\bluefin.zip }
[IO.Compression.ZipFile]::CreateFromDirectory((Resolve-Path(".\src")).Path, (Resolve-Path(".\")).Path + "\bluefin.zip")
Set-AzureRmCurrentStorageAccount -StorageAccountName $StorageAccountName -ResourceGroupName $StorageResourceGroupName | Out-Null
$blob = Set-AzureStorageBlobContent -File ".\bluefin.zip" -Container $StorageContainerName -Force

Write-Host "Uploaded extension located at:"
Write-Host $blob.ICloudBlob.uri.AbsoluteUri
$ENV:ExtensionDownloadUrl = $blob.ICloudBlob.uri.AbsoluteUri

Write-Host "Getting extension verison number"
$manifest = ConvertFrom-Json (GC .\src\manifest.json -raw)
$bluefinVersion = $manifest.version

$failed = 0
$max = 60
$octopusVersion = "0"
do
{
    try
    {
        Write-Host "Waiting for Octopus Deploy ($octopusUrl/api) to be ready ($failed of $max tries)..."
        $response = Invoke-RestMethod -Uri "$octopusUrl/api" -Method GET -TimeoutSec 10
        $response | Format-List *
        $octopusVersion = $response.Version
        break
    } catch { $failed++ }
} while($failed -lt $max)

if($failed -ge $max)
{
    throw "Unable to connect to Octopus Deploy API. Requests timed out."
    exit 1
}

Write-Host "Running browser tests..."
mkdir .\results\browser-tests -force | Out-Null
& .\node_modules\.bin\jasmine-node --captureExceptions --verbose spec/browser-tests --junitreport --output results\browser-tests --config TestIdFilename "results\browser-test-ids.txt" --config OctopusUrl "$octopusUrl" --config OctopusVersion "$octopusVersion" --config BluefinVersion "$bluefinVersion"

if ($LastExitCode -ne 0)
{
    Write-Host "Tests failed"
    $testsPassed = $false
}

if ($ENV:APPVEYOR -eq "true")
{
    Write-Host "Uploading browser test results..."
    $client = New-Object 'System.Net.WebClient'
    dir .\results\browser-tests\*.xml | %{ $client.UploadFile("https://ci.appveyor.com/api/testresults/junit/$($env:APPVEYOR_JOB_ID)", $_) }

    Write-Host "Adding test identifiers to build messages..."
    Add-AppveyorMessage -Message "Browser test result urls"
    $testIds = GC $ENV:TestIdFilename
    $testIds | %{ 
        $id = $_.Split("~")[0]
        $name = $_.Split("~")[1]
        Add-AppveyorMessage -Message "$name = https://saucelabs.com/beta/tests/$id/commands"
    }
}

Write-Host "Stopping test VM..."
if((Test-Path ENV:LeaveVirtualMachineRunning)) {
    Write-Host "Leaving virtual machine running for manuall testing..."
} else {
    Stop-AzureRMVM -ResourceGroupName $VMResourceGroupName -Name $VMName -Force | Out-Null
}