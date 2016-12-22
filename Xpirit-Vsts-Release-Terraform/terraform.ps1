Trace-VstsEnteringInvocation $MyInvocation



function Install-Terraform
{
    $version = Get-VstsInput -Name Version

    $terraformbaseurl = "https://releases.hashicorp.com/terraform/"
    $path = "c:\terraform-download"

    $regex = """/terraform/([0-9]+\.[0-9]+\.[0-9]+)/"""

    $web = New-Object Net.WebClient
    $webpage = $web.DownloadString($terraformbaseurl)


    $versions = $webpage -split "`n" | Select-String -pattern $regex -AllMatches | % { $_.Matches | % { $_.Groups[1].Value } }

    $latest = $versions[0]

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

    Invoke-WebRequest $source -OutFile $tempfile

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
    $argumentents = Get-VstsInput -Name Arguments -Require
    
    Write-Host "Running: terraform $argumentents"
    terraform $argumentents

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
    Set-AzureStorageBlobContent -Force -Context $SourceContext -Container $StorageContainerName  -File "terraform.tfstate" -Blob "terraform.tfstate"
    Set-AzureStorageBlobContent -Force -Context $SourceContext -Container $StorageContainerName  -File "terraform.tfstate.backup" -Blob "terraform.tfstate.backup"
}

function Prepare
{
    $runpath = Get-VstsInput -Name RunPath -Require
    $templatesPath = Get-VstsInput -Name TemplatePath -Require

    Write-Host "Source path $templatesPath, destination path $runpath"
    if (-not (test-path $runpath)){
         mkdir $runpath
    }
    
    $path = "$templatesPath\*"
    Copy-Item $path $runpath  -recurse 

    cd $runpath
}

Prepare

$installTerraform = Get-VstsInput -Name InstallTerraform -Require
$manageTerraformState = Get-VstsInput -Name ManageState -Require 

if ($manageTerraformState){
    # Initialize Azure.
    Import-Module $PSScriptRoot\ps_modules\VstsAzureHelpers_
    Initialize-Azure

   
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
