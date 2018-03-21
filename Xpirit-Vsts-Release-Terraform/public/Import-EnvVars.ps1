<#
.SYNOPSIS
This will load Azure SP endpoint values as environment variables consumable by Terraform
#>
function Import-EnvVars  {
    $connectedServiceName = Get-VstsInput -Name ConnectedServiceNameARM -Require
    $endpoint = Get-VstsEndpoint -Name $connectedServiceName -Require

    if ($endpoint.Auth.Scheme -ne 'ServicePrincipal') {        
        throw (New-Object System.Exception((Get-VstsLocString -Key AZ_ServicePrincipalRequired), $_.Exception))
    }
    $env:ARM_SUBSCRIPTION_ID = $endpoint.Data.subscriptionId
    $env:ARM_TENANT_ID = $endpoint.Auth.Parameters.TenantId
    $env:ARM_CLIENT_ID = $endpoint.Auth.Parameters.ServicePrincipalId
    $env:ARM_CLIENT_SECRET = $endpoint.Auth.Parameters.ServicePrincipalKey
}