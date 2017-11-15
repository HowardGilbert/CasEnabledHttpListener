function global:DoSomething {
    [CmdletBinding()]
    param(
        [System.Net.HttpListenerContext] $Context, 
        [string] $RequestedBy
        )
	[System.Net.HttpListenerRequest]$request = $context.Request

	# Example function with only one operation and no parameters (complex Powershell explained later)
	# Return table of 4 properties from the AD entry of the CAS-authenticated user
    return (Get-ADuser $RequestedBy -Properties *| ConvertTo-Html -Property GivenName,Surname,mail,Title -Fragment -As List)

}

Import-Module "$PSScriptRoot\CasEnabledHttpListener.psm1" -Force
Start-CasEnabledHttpListener -appname manageusers -hostname localhost -Verbose
