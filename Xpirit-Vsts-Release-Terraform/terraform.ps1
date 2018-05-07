Trace-VstsEnteringInvocation $MyInvocation

#region ImportFunctions
$functionFolders = @('Public')
ForEach ($folder in $functionFolders)
{
    $folderPath = Join-Path -Path $PSScriptRoot -ChildPath $folder
    If (Test-Path -Path $folderPath)
    {
        Write-Verbose -Message "Importing from $folder"
        $functions = Get-ChildItem -Path $folderPath -Filter '*.ps1'
        ForEach ($function in $functions)
        {
            Write-Verbose -Message "  Importing $($function.BaseName)"
            . $($function.FullName)
        }
    }
}
#endregion

#region FunctionDefinitions
function Install-Terraform
{
    $version = Get-VstsInput -Name Version

    # Need to force using more up-to-date encryption protocols; Hashicorp is on-point deprecating broken ones.
    [System.Net.ServicePointManager]::SecurityProtocol = `
                [System.Net.SecurityProtocolType]::Tls11 -bor 
                [System.Net.SecurityProtocolType]::Tls12 -bor `
                [System.Net.SecurityProtocolType]::Tls -bor `
                [System.Net.SecurityProtocolType]::Ssl3

    $terraformbaseurl = "https://releases.hashicorp.com/terraform/"
    $path = "c:\terraform-download"

    $regex = """/terraform/([0-9]+\.[0-9]+\.[0-9]+)/"""

    $webpage = (Invoke-WebRequest $terraformbaseurl -UseBasicParsing).Content

    $versions = $webpage -split "`n" | Select-String -pattern $regex -AllMatches | % { $_.Matches | % { $_.Groups[1].Value } }
    if ($version -eq "latest")
    {
        $version = $versions[0]
    }
    else
    {
        if (-not $versions.Contains($version))
        {   
            throw [System.Exception] "$version not found."
        }
    }

    $tempfile = [System.IO.Path]::GetTempFileName()
    $source = "https://releases.hashicorp.com/terraform/"+$version+"/terraform_"+$version+"_windows_amd64.zip"

    Invoke-WebRequest $source -UseBasicParsing -OutFile $tempfile

    if (-not (test-path $path))
    {
        mkdir $path
    }

    $P = [Environment]::GetEnvironmentVariable("PATH")
    if($P -notlike "*"+$path+"*")
    {
        [Environment]::SetEnvironmentVariable("PATH", "$P;$path")
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function Unzip
    {
        param([string]$zipfile, [string]$outpath)
        if (test-path $outpath)
        {
            del "$outpath\*.*"
        }
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outpath)
    }

    Unzip $tempfile $path

    Write-Output "Terraform version:"
    terraform --version
}

function Get-BackendConfig
{
    $tfFiles = Get-ChildItem -Include "*.tf" -File -Recurse
    Foreach ($file in $tfFiles)
    {
        $fileContents = [System.IO.File]::ReadAllText($file)
        if ($fileContents -Match "backend `"azurerm`"")
        {
            $startIndex = $fileContents.IndexOf("backend `"azurerm`"")
            $startIndex = $fileContents.IndexOf('{', $startIndex) + 1            
            $endIndex = $fileContents.IndexOf('}', $startIndex)            
            $keyValues = $fileContents.Substring($startIndex, $endIndex - $startIndex)
            $backendConfig = ConvertFrom-StringData -StringData $keyValues     
            foreach ($key in $($backendConfig.Keys))
            {
                $backendConfig.Item($key) = $backendConfig.Item($key).Trim("`"", " ")                
            }            
            return $backendConfig
        }        
    }    
}

function Initialize-Terraform
{       
    $connectedServiceName = Get-VstsInput -Name ConnectedServiceNameARM -Require
    $endpoint = Get-VstsEndpoint -Name $connectedServiceName -Require

    if ($endpoint.Auth.Scheme -ne 'ServicePrincipal') {        
        throw (New-Object System.Exception((Get-VstsLocString -Key AZ_ServicePrincipalRequired), $_.Exception))
    }

    $remoteStateArguments = "-backend-config=`"arm_subscription_id=$($endpoint.Data.subscriptionId)`" -backend-config=`"arm_tenant_id=$($endpoint.Auth.Parameters.TenantId)`" -backend-config=`"arm_client_id=$($endpoint.Auth.Parameters.ServicePrincipalId)`" -backend-config=`"arm_client_secret=$($endpoint.Auth.Parameters.ServicePrincipalKey)`""

    $specifyStorageAccount = Get-VstsInput -name SpecifyStorageAccount -Require -AsBool
    if ($specifyStorageAccount){
        $resourceGroupName = Get-VstsInput -Name StorageAccountResourceGroup -Require
        $storageAccountName = Get-VstsInput -Name StorageAccountRM -Require
        $storageContainerName = Get-VstsInput -Name StorageContainerName -Require  
        $remoteStateArguments = "$remoteStateArguments -backend-config=`"resource_group_name=$resourceGroupName`" -backend-config=`"storage_account_name=$storageAccountName`" -backend-config=`"container_name=$storageContainerName`""
    }
    
    $additionalArguments = Get-VstsInput -Name InitArguments
    if (-not ([string]::IsNullOrEmpty($additionalArguments)))
    {
        $arguments = $remoteStateArguments + " $($additionalArguments.Trim()) -input=false -no-color"
    } else {
        $arguments = $remoteStateArguments + " -input=false -no-color"
    }
       
    Invoke-VstsTool -FileName terraform -arguments "init $arguments"

    if ($LASTEXITCODE)
    {
        $E = $Error[0]
        Write-Host "##vso[task.logissue type=error;] Terraform init failed to execute. Error: $E" 
        Write-Host "##vso[task.complete result=Failed]"
    }
}

function Invoke-Terraform
{
    $arguments = (Get-VstsInput -Name Arguments -Require) -split '\s+'

    $defaultArgs = "-input=false -no-color " + (Get-VstsInput -Name PlanPath)
    
    Invoke-VstsTool -FileName terraform -arguments "$($arguments.Trim()) $($defaultArgs.TrimEnd())"

    if ($LASTEXITCODE)
    {
        $E = $Error[0]
        Write-Host "##vso[task.logissue type=error;] Terraform failed to execute. Error: $E" 
        Write-Host "##vso[task.complete result=Failed]"
    }
}
#endregion

#region Script

$templatesPath = Get-VstsInput -Name TemplatePath -Require
if (-not (Test-Path $templatesPath)) {
    Write-Host "##vso[task.logissue type=error;] Template Path location ($templatesPath) does not exist, failing out" 
    Write-Host "##vso[task.complete result=Failed]"
    exit(1)
}
Set-Location $templatesPath

$installTerraform = Get-VstsInput -Name InstallTerraform -Require -AsBool
$useAzureSub = Get-VstsInput -Name UseAzureSub -Require -AsBool
$manageTerraformState = Get-VstsInput -Name ManageState -Require -AsBool
$specifyStorageAccount = Get-VstsInput -name SpecifyStorageAccount -Require -AsBool

if ($useAzureSub){
    Import-EnvVars
}

if ($useAzureSub -and $manageTerraformState){
    # Initialize Azure.
    Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
    Initialize-Azure
    if ($specifyStorageAccount){
        $resourceGroupName = Get-VstsInput -Name StorageAccountResourceGroup -Require
        $storageAccountName = Get-VstsInput -Name StorageAccountRM -Require
        $storageContainerName = Get-VstsInput -Name StorageContainerName -Require 
    } else {
        $backendConfig = Get-BackendConfig
        $resourceGroupName = $backendConfig.resource_group_name
        $storageAccountName = $backendConfig.storage_account_name
        $storageContainerName = $backendConfig.container_name
    }     
    Ensure-AzStorageContainerExists -ResourceGroupName $resourceGroupName -StorageAccountName $storageAccountName -StorageContainer $storageContainerName    
}

if ($installTerraform){
    Install-Terraform
}

if ($useAzureSub -and $manageTerraformState){
    Initialize-Terraform
}

Invoke-Terraform

Write-Host "End of Task Terraform" 

#endregion
