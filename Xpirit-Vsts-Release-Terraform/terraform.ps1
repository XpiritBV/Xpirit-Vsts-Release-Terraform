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

function Invoke-Terraform
{
    $arguments = (Get-VstsInput -Name Arguments -Require) -split '\s+'
    
    Write-Host "Running: terraform $arguments"
    & terraform $arguments

    if ($LASTEXITCODE)
    {
        $E = $Error[0]
        Write-Host "##vso[task.logissue type=error;] Terraform failed to execute. Error: $E" 
        Write-Host "##vso[task.complete result=Failed]"
    }
}

function Get-TerraformState
{
    $StorageAccountName = Get-VstsInput -Name StorageAccountRM -Require
    $StorageContainerName = Get-VstsInput -Name StorageContainerName -Require  

    Write-Host "Get-TerraformState: Using StorageAccountName $StorageAccountName and StorageContainerName $StorageContainerName "
    $SourceContext = (Get-AzureRmStorageAccount |  where { $_.StorageAccountName -eq $StorageAccountName}).Context

    if ((Test-Path "terraform.tfstate") -or (Test-Path "terraform.tfstate.backup")){
        Write-Host "##vso[task.logissue type=error;] Terraform state files in run directory, can not override to prevent data lose" 
        Write-Host "##vso[task.complete result=Failed]"
        exit(1)
    }

    $tfstate = Get-AzureStorageBlob -Context  $SourceContext -Container $StorageContainerName | where { $_.Name -eq "terraform.tfstate"}
    if ($tfstate){
        Get-AzureStorageBlobContent -Context  $SourceContext -Container $StorageContainerName -Blob  "terraform.tfstate" -Destination  "terraform.tfstate" -Force -ErrorAction Stop
    }
    
    $tfstatebackup = Get-AzureStorageBlob -Context  $SourceContext -Container $StorageContainerName | where { $_.Name -eq "terraform.tfstate.backup"}
    if ($tfstatebackup){
        Get-AzureStorageBlobContent -Context  $SourceContext -Container $StorageContainerName -Blob  "terraform.tfstate.backup" -Destination  "terraform.tfstate.backup" -Force -ErrorAction Stop
    }
}

function Set-TerraformState
{
    $StorageAccountName = Get-VstsInput -Name StorageAccountRM -Require
    $StorageContainerName = Get-VstsInput -Name StorageContainerName -Require  

    Write-Host "Set-TerraformState: Using StorageAccountName $StorageAccountName and StorageContainerName $StorageContainerName"
    $SourceContext = (Get-AzureRmStorageAccount |  where { $_.StorageAccountName -eq $StorageAccountName}).Context
    if ((Test-Path "terraform.tfstate")){
        Set-AzureStorageBlobContent -Force -Context $SourceContext -Container $StorageContainerName  -File "terraform.tfstate" -Blob "terraform.tfstate"
    }
    else {
        Write-Host "##vso[task.logissue type=warning;] Terraform state not found and not uploaded" 
    }

    if ((Test-Path "terraform.tfstate.backup")){
        Set-AzureStorageBlobContent -Force -Context $SourceContext -Container $StorageContainerName  -File "terraform.tfstate.backup" -Blob "terraform.tfstate.backup"
    }
    else {
        Write-Host "##vso[task.logissue type=warning;] Terraform state backup not found and not uploaded" 
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
$manageTerraformState = Get-VstsInput -Name ManageState -Require -AsBool

if ($manageTerraformState){
    # Initialize Azure.
    Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
    Initialize-Azure
    $resourceGroupName = Get-VstsInput -Name StorageAccountResourceGroup -Require 
    Ensure-AzStorageContainerExists -ResourceGroupName $resourceGroupName -StorageAccountName $StorageAccountName -StorageContainer $StorageContainerName
    Get-TerraformState($StorageAccountName, $StorageContainerName)
}

if ($installTerraform){
    Install-Terraform
}

Invoke-Terraform

if ($manageTerraformState){
    Set-TerraformState
}

Write-Host "End of Task Terraform" 

#endregion
