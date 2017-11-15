<#
    A basic CAS Client written in PowerShell useful for Web Services based on an HttpListener.

    This is basically the textbook standard CAS Client code expressed in Powershell.
    You can write the same code in any other programming language.

    This code functions with any Powershell script that uses the HttpListener class to create
    a Web Server. HttpListener supports other forms of Authentication, but to use CAS you
    disable the .NET authentication options and use this module. 

    The textbook use of HttpListener from Powershell looks something like this:

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("https://*:5150/$appname/")
    $listener.IgnoreWriteExceptions=$true
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
	$listener.Start()
	while ($true) {
		$context = $listener.GetContext()
        $netid = Get-CasUser $context
        if (!$netid) {continue}

        ... # do stuff
    }

    If you want information on the other parameters of $listener, look them up elsewhere
    because this module is only about CAS. Setting the Anonymous AuthenticationScheme 
    tells the Listener to do no authentication itself. Then this code takes over.

    $listener.GetContext() waits for an HTTP request (GET or POST) to arrive. You have
    to decide if the request requires CAS authentication. It is really hard to authenticate
    a POST because you have to save the data somewhere, so typically you only expect to
    authenticate on a GET where the only data is in the URL.

    When you need a netid, call Get-CasUser passing the $context you got back from GetContext().
    If there are some functions that do not require authentication (like an initial greeting page
    or a menu of options) then call Get-CasUser only for requests that need it. 

    However, you have to make up your mind before you start putting data in the Response object. 
    You cannot begin to write stuff back to the user, then change your mind and decide to redirect
    to CAS. 

    In Get-CasUser:
    If you already authenticated, the Netid is passed back from the table of users.
    The first time you authenticate, this code redirects the browser to the CAS login page.
    The next $context that comes back from CAS contains the Service Ticket string that can be
    validated to get the Netid.

    In the middle case, where this code changes the Response object to redirect to CAS, 
    this function returns $null. As shown above, when you get back $null from the function
    call, continue to the end of the loop and go back to GetContext() to receive the 
    Request when CAS redirects the browser back here.
    
    After getting and validating a ticket, this module writes a cookie to the Browser and
    maintains a lookup table associating that cookie to the Netid. 
#>


# CONFIGURE THIS MODULE
# Specify your CAS server URL here
$property_CasServerUrl = 'https://secure.its.yale.edu/cas'





<# 
    Simple Session Cache

    You want to authenticate once a day and then use a Cookie to identity yourself. Security 
    will be provided if you use https encrypted transport of requests. The cookie value should
    be random and unguessable, and the CAS Service Ticket already provides these properties.
    So it is reused as the value of the Session Cookie (named 'CASST').
    This does violate the principal that the ST is a single use value that times out immediately,
    but that was added to allow CAS clients that used plain http (no encryption).
    All sessions expire at midnight and then everyone has to relogin.
    If you want sometime better, replace this code with something bigger. 
#>
$StToNetid = @{}    # given an ST, return the netid
$NetidToSt = @{}    # given an netid, return an existing ST
$today = [DateTime]::Today  # At midnight, flush the cache


<#
    Get-CasUser is called from a main script after calling HttpListener.getContext().
    It would never be typed into a command prompt. 
    
    The argument is the HttpListenerContext object that points to the Request and Response objects.

    The logic is standard "CAS Client"

        If there is a Cookie indicating a session with this browser, return the Netid from the session.
        If there is a ticket=, validate it to the CAS Server and store the Netid returned in a new session
        Otherwise, redirect to CAS login.
    
    The returned value is the Netid, or $null if we set up the Response object to redirect to CAS login.
#>
function Get-CasUser {
    # Adding the CmdletBinding gives us access to -Verbose and other useful tools.
    [CmdletBinding()]
    param(
        # Caller must pass an object returned by $listener.GetContext()
        # The HttpListenerContext contains one Http request (a GET or PUT for example).
        # from the context you can get a Request and Response object just like every other
        # Web application API has. 

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
        $StToNetid = @{}    
        $NetidToSt = @{}
        $today = [DateTime]::Today
    }


    # Does the client have a valid Session Cookie named CASST?
    $cookie = $request.Cookies['CASST']
    if ($cookie) {
        $casst = $cookie.value
        Write-Verbose "Found cookie $casst"

        # Look in the table of valid Cookie values for a previously determined Netid
        if ($StToNetid.containsKey($casst) ){
            $userid = $StToNetid[$casst]
            Write-Verbose "Using session for $userid"
            return $userid 
        } else {
           Write-Verbose "Expired cookie (not found in Session table)"
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
        $uristring =$request.Url.OriginalString

        # It is always "&ticket=" or "?ticket=" that need to be stripped off
        $loc = $uristring.LastIndexOf("&ticket=")
        if ($loc -le 0) {$loc = $uristring.LastIndexOf("?ticket=")}
        if ($loc -ge 0) {
            # The URL needs to be escaped before appending it to service=
            $casservice = [System.Uri]::EscapeUriString($uristring.Substring(0,$loc))

            # Invoke-WebRequest opens an SSL connection to the CAS server.
            # The /serviceValidate selects CAS 2.0 protocol where the response will be simple XML
            # The data sent back (and the status and headers) is in an object
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

                    # Got a good login, save it in the Session Cache and write the CASST Cookie
                    Write-Verbose "CAS Login from `'$userid`' with $casst"
                    if ($NetidToSt.ContainsKey($userid)){
                        # If the user already has a Session with a previous CASST, reuse it
                        $cookieval = $NetidToSt[$userid]
                    } else {
                        $StToNetid[$casst]=$userid
                        $NetidToSt[$userid]=$casst
                        $cookieval = $casst
                    }
                    # Create a new CASST cookie. Will replace an old expired cookie with the same name
                    $cookie = New-Object -TypeName System.Net.Cookie
                    $cookie.Name = 'CASST'
                    $cookie.Value = $cookieval
                    $cookie.Discard = $true
                    $context.Response.AppendCookie($cookie)

                    # The current URL has the ticket, so do one last Redirect so the end user doesn't
                    # end up with the ticket= in the address bar (and worse, possibly in a bookmark).
                    $context.Response.Redirect($casservice)
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
        Write-Verbose "Redirecting user to CAS"
        if ($request.HttpMethod -ne "GET") {throw "Must redirect user to CAS login, but HTTP operation is $($request.HttpMethod) instead of GET"}
        $servicestring = [System.Uri]::EscapeUriString($request.Url.OriginalString)
        $context.Response.Redirect("$property_CasServerUrl/logon?service=$servicestring")
        $context.Response.Close()
        return $null
}
