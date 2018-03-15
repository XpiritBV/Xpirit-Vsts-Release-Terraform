<#
.SYNOPSIS
Ensures the azure storage container exists
#>
function Ensure-AzStorageContainerExists {
    [CmdletBinding()]
    param (
        $ResourceGroupName,
        $StorageAccountName,
        $StorageContainer
    )
    
    Write-Host "Storage account is: " $StorageAccountName
    Write-Host "Container account is: " $StorageContainer

    $account = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    $containerNotFound = $true

    try {
        $account | Get-AzureStorageContainer -Name $StorageContainer -ErrorAction Stop
        $containerNotFound = $false
    }
    catch [Microsoft.WindowsAzure.Commands.Storage.Common.ResourceNotFoundException] {
        Write-Host "container $StorageContainer not found"
    }

    if ($containerNotFound) {
        $account | New-AzureStorageContainer -Name $storageContainer
     }
}