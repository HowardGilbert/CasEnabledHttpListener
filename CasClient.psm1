<#
    A basic CAS Client written in PowerShell for Web Services based on an HttpListener.

    This is basically the standard CAS Client code expressed in Powershell.
    You can write the same code in any other programming language.

    This code accompanies the CasEnabledHttpListener module, which provides an example
    of binding to a URL, waiting for a context, then calling this code.
    
#>

# Caller can provide required configuration with Import-Module -ArgumentList localhost,myapp
param (
	[string] $hostname, 
	[string] $appname
)

# You can have many applications, but there is only one CAS server on your campus
$property_CasServerUrl = 'https://secure.its.yale.edu/cas'

# More than one app can run on a server, so include the appname in the Cookie name.
# so each application has its own Session.
$CookieName = $appname.toUpper()+'-CASST'

$CookieValue = $null

<# 
    Simple Session Cache
    
    Create two hashtables to map Cookie value to Netid and Netid to a Cookie value.
    The second table is optional, but keeps the number of entries in the Cache low
    if someone drops Cookies all the time. Use the CAS Service Ticket as the Cookie value.
    Expire the cache at midnight each day (feel free to recode for a shorter session time).
#>
$StToNetid = @{}    # given an ST, return the netid
$NetidToSt = @{}    # given an netid, return a previous ST
$today = [DateTime]::Today  # At midnight, flush the cache






<#
.SYNOPSIS
	Get Netid from session or from CAS
.DESCRIPTION
    Get-CasUser is called from a main script after calling HttpListener.getContext().
    It would never be typed into a command prompt. 
    
    The logic is standard "CAS Client"

        If there is a Cookie indicating a session with this browser, return the Netid from the session.
        If there is a ticket=, validate it to the CAS Server and store the Netid returned in a new session
        Otherwise, redirect to CAS login.
.PARAMETER Context
 	[HttpListenerContext] returned by calling $listener.getContext()       
.OUTPUT    
    [string] $Netid, or $null if we set up the Response object to redirect to CAS login.
#>
function Get-CasUser {

    [CmdletBinding()] # Allow -Verbose
    param(
        [Parameter(Mandatory=$true)]
        [System.Net.HttpListenerContext] $context
    )

    # Get the Request object with the URL, Headers, and any transmitted data
    [System.Net.HttpListenerRequest]$request = $context.Request

    # Initialize the return value as null
    $userid = $null

    # Flush the session cache first call after midnight
    if ($today -ne [DateTime]::Today) {
        # first call after midnight, flush the cache
        $script:StToNetid = @{}    
        $script:NetidToSt = @{}
        $script:today = [DateTime]::Today
    }


    # Does the client have a valid Session Cookie 
    $cookie = $request.Cookies[$CookieName]
    if ($cookie) {
        $casst = $cookie.value
        Write-Verbose "Found cookie $casst"

        # Look in the table of valid Cookie values for a previously determined Netid
        if ($StToNetid.containsKey($casst) ){
            $userid = $StToNetid[$casst]
            Write-Verbose "Using session for $userid"
            $script:CookieValue = $casst
            return $userid 
        } else {
            Write-Verbose "Expired cookie (not found in Session table)"
            # This is the only reliable way to set/update/delete Cookies with HttpListener
            $context.Response.Headers.Add('Set-Cookie',"$CookieName=Deleted;Path=/$appname;Secure;HttpOnly;Max-Age=0")
        }
    }

    # You get here if there is no valid Cookie to indicate an existing session. Now we do the
    # CAS protocol part.

    # Does the Request have a ticket= parameter appended to the end of the Http QueryString?
    $casst = $request.QueryString['ticket']
    if ($casst) {
        Write-Verbose "Received CAS Service Ticket $casst"

        # CAS requires us to send a service= parameter that exactly matches the one it got
        # in the redirect. Fortunately, CAS always appends ticket= on the end of the service
        # URL, so all we need to do is strip the ticket= off the end

        # Get the URL from the Request object
        $uristring =$request.Url.AbsoluteUri

        # It is always "&ticket=" or "?ticket=" that need to be stripped off
        $loc = $uristring.LastIndexOf("&ticket=")
        if ($loc -le 0) {$loc = $uristring.LastIndexOf("?ticket=")}
        if ($loc -ge 0) {
            # The URL needs to be escaped before appending it to service=
            $casservice = [System.Uri]::EscapeUriString($uristring.Substring(0,$loc))

            # Invoke-WebRequest opens an SSL connection to the CAS server.
            # The /serviceValidate selects CAS 2.0 protocol where the response will be simple XML
            # The data sent back (and the status and headers) is in an object
            Write-Verbose "$property_CasServerUrl/serviceValidate?service=$casservice&ticket=$casst"
            [Microsoft.PowerShell.Commands.WebResponseObject] $casresp = Invoke-WebRequest -URI "$property_CasServerUrl/serviceValidate?service=$casservice&ticket=$casst" -UseBasicParsing

            if ($casresp.StatusCode -eq 200) { 
                # parse the XML text to Powershell XML objects
                [xml] $casXmlResponse = $casresp.Content

                # sucessful validation is a <cas:serviceRequest><cas:authenticationSuccess><user>username</user></..></..>
                # CAS allows CAS protocol middlemen (proxies), but for security we do not allow them at this time.
                if ($casXmlResponse.serviceResponse -and 
                    $casXmlResponse.serviceResponse.authenticationSuccess -and 
                    !$casXmlResponse.serviceResponse.authenticationSuccess.proxies) {
                    $userid=$casXmlResponse.serviceResponse.authenticationSuccess.user

                    # Got a good login, save it in the Session Cache and write the Cookie
                    Write-Verbose "CAS Login from `'$userid`' with $casst"
                    if ($NetidToSt.ContainsKey($userid)){
                        # If the user already has a Session with a previous CASST, reuse it
                        Write-Verbose "Reusing $($NetidToSt[$userid])"
                        $cookieval = $NetidToSt[$userid]
                    } else {
                        $script:StToNetid[$casst]=$userid
                        $script:NetidToSt[$userid]=$casst
                        $cookieval = $casst
                    }
            		# This is the only reliable way to set/update/delete Cookies with HttpListener
        			$context.Response.Headers.Add('Set-Cookie',"$CookieName=$Cookieval;Path=/$appname;Secure;HttpOnly")

                    # One last Redirect to get rid of the ticket on the command line. 
                    # After a fresh CAS login, we can only display the home page of the application.
                    # Any additional path or querystring information in the service= URL is suspect and could have been provided
                    # in a Redirect by an evil third party site. 
                    $context.Response.Redirect("/$appname/")
                    $context.Response.Close()
                    return $null
                } else {
                    Write-Host "Service Ticket $casst did not validate: $($casXmlResponse.serviceResponse.authenticationFailure.InnerText.Trim())"
                }
            } else {
                Write-Host "CAS /serviceValidate failed, HTTP status was $($casresp.StatusCode)"
            }
        } else {
            Write-Verbose "Cannot parse URL to remove ticket parameter, probably bug in this code"
        }
    }

    # So there is no Session and no valid Service Ticket. Redirect the user to CAS
        if ($request.HttpMethod -ne "GET") {throw "Must redirect user to CAS login, but HTTP operation is $($request.HttpMethod) instead of GET"}
        $servicestring = [System.Uri]::EscapeUriString($request.Url.AbsoluteUri)
        $context.Response.Redirect("$property_CasServerUrl/logon?service=$servicestring")
        Write-Verbose "Redirecting user to $property_CasServerUrl/logon?service=$servicestring"
        $context.Response.Close()
        return $null
}




function Test-CSRFTokenValue {

	param ([string] $CSRFToken)

	return ($CSRFToken -eq $CookieValue)
} 

function Get-CSRFTokenValue {

	return $CookieValue
} 

function Get-CSRFTokenElement {

	return @"
	<input type='hidden' name='CSRFToken' value='$CookieValue' />
"@
} 
