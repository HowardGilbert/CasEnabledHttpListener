<#
    CasEnabledHttpListener

    In Linux, applications bind to an IP address and port number. This means
    that only one process can use popular ports like 80 and 443. If you want
    to run two or more applications on the same port, you have to assign the 
    port to a "reverse proxy" like ngnix that processes the HTTP protocol, 
    decides which application should receive a given Web request. 

    Windows has a "reverse proxy" built into the kernel. Instead of binding to 
    a port, a .NET application can create an HttpListener object that binds to 
    "https://example.yale.edu/someapp/". The http.sys driver in the Kernel then
    binds to port 443 (if it hasn't already) and uses the SSL Certificate that
    an administrator associated with the port using the netsh command. It 
    accepts incoming connections, reads the HTTP headers, and when it finds
    a Host header with example.yale.edu and a URL with a path beginning "/someapp/"
    then it delivers that stream of bytes to this application.

    It is still necessary to convert the HTTP headers and protocol to objects. This
    is done with the HttpListener class, which parses the byte stream and creates
    the usual Context, Request, and Response objects used by every Web app API.

    Because you need to protect the CAS cookie, this class as written assumes you
    will accept requests on port 443. It binds to port 80, but only to redirect the
    browser to 443. You have to install an SSL certificate into the Windows Certificate
    store and use netsh to bind it to port 443.
    
    A computer can have many network names, and the hostname from the incoming URL 
    can be used as one of the selection parameters. Of course, since we assume SSL
    then the hostname better be the same as the name in the X.509 Certificate you
    just installed. 
    
    It is a common convention of most Web service to treat the first element of the
    path as an application selector. We call it the $appname in this module. 
    
    So given a $hostname of "example.yale.edu" and an $appname of "whatsappdoc", 
    this module will bind to the URL "https://example.yale.edu/whatsappdoc" and any
    arriving https request that starts with that URL will be processed.

    In most cases, applications will require CAS authentication immediately. If you
    comment that out, it is up to you to decide when authentication is needed, and 
    call Get-CasUser at that point, and handle the return when the browser has been
    redirect to login. So authenticating everything is easier.

    The caller imports this module and calls Start-CasEnabledHttpListener
    
    The caller must define a global function named DoSomething which gets called back
    with a context and netid whenever a request arrives.
     

    Thanks to Microsoft for some examples to get started.
#>


<#
    A throwable object to generate an error HttpResponse
#>
class HttpError {
    [System.Net.HttpStatusCode] $Status
    [string] $Message

    HttpError([System.Net.HttpStatusCode] $status,[string] $message) {
        $this.Status=$status
        $this.Message = $message
    }
}

<#
    A function to generate the throwable object, since Powershell 5 
    requires a full path in "using" statements to import them.
    The $Status argument is a member of the System.Net.HttpStatusCode enum class.
    However, to pass it as an enum, you must make it an expression by putting it in parentheses
    Alternately, pass a valid Status Code int value, or the name of the selected Enum values as a string.

    Examples of the same thing: 
        throw New-HttpError ([System.Net.HttpStatusCode]::BadRequest) "Google G Suite Eliapps account not found"
        throw New-HttpError 400 "Google G Suite Eliapps account not found"
        throw New-HttpError "BadRequest" "Google G Suite Eliapps account not found"
#>
function New-HttpError {

    param( 
        [System.Net.HttpStatusCode] $Status,
        [string] $Message
    )

    return [HttpError]::new($Status,$Message)
}



Import-Module "$PSScriptRoot\CasClient.psm1" -Force



function Start-CasEnabledHttpListener {
    [CmdletBinding()]
    param (
        [string] $hostname = 'localhost',
        [string] $appname = 'service' 

    )

    $listener = New-Object System.Net.HttpListener

    $listener.Prefixes.Add("http://$hostname/$appname/")
    $listener.Prefixes.Add("https://$hostname/$appname/")
    $listener.IgnoreWriteExceptions=$true
    $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
    Write-Verbose "Listening on $($listener.Prefixes)"
		
    # Loops until this is set to false.
    $global:ContinueHttpProcessing = $true
    $running = $false
    try {
	    $listener.Start()
        $running = $true
			
:nextContext while ($global:ContinueHttpProcessing) {
				
		    Write-Host "Thread is blocked waiting for the next Web Request."

		    $statusCode = 200

		    [System.Net.HttpListenerContext] $context = $listener.GetContext()
		    [System.Net.HttpListenerContext] $global:CasEnabledHttpListenerContext = $context

            [System.Net.HttpListenerRequest] $request = $context.Request
            [System.Uri] $url = $request.Url

            # A silly switch. The code runs until it generates a response 
            # a break statement generates HTML text output
            # a continue statement is used for a redirect

            switch ('only case') {
                'only case' {

            
                # Any use of port 80 gets redirected to https. 
                if (-not $request.IsSecureConnection) {
                    Write-Verbose "Redirecting user to https"
                    $context.Response.Redirect("https://$hostname/$appname/$($url.PathAndQuery)")
                    $context.Response.Close()
                    continue nextContext;
                }  

                
                # CAS Authenticate
                $netid = Get-CasUser $context
                if (!$netid) {continue nextContext}  # Returned $null, Browser was redirected to the CAS Server
                 
             

                # Static files (end in .html or are in the /html/ subdirectory)
                $filename=$null
                if ($url.Segments.Count -eq 3 -and $url.Segments[2].EndsWith('.html')) {
                    # https://$hostname/$appname/page.html goes to /html/page.html
                    $filename = "$PSScriptRoot\html\$($url.Segments[2])"
                } elseif ($url.Segments.Count -eq 2) {
                    # https://$hostname/$appname goes to /html/index.html
                    $filename = "$PSScriptRoot\html\index.html"
                } elseif ($url.Segments.Count -eq 4 -and $($url.Segments[2] -eq "html")) {
                    # https://$hostname/$appname/html/foo.bar goes to /html/foo.bar
                    $filename = "$PSScriptRoot\html\$($url.Segments[3])"
                }
                if ($filename) {
                    # The URL is a file request
                    if (Test-Path -Path $filename) {
                        $commandOutput=Get-Content -Path $filename |Out-String
                    } else {
                        $StatusCode=404
                        $commandOutput="File not found"
                    }
                    break;
                }

                # We want to allow forms we write to the Browser to post back data
                # But we don't want any other application to Redirect the Browser to a REST Web call
                # that does something using the logged in user's authority. So we check the 
                # Http Referrer header, which must be missing (the user typed the URL in himself) or
                # must be this machine (this data comes from a form we wrote).
                [System.Uri] $referrer = $request.UrlReferrer
                if ($referrer -and $url.Authority -ne $referrer.Authority) {
                    $StatusCode = 403
                    $commandOutput = "You were redirected from another computer. This is a security problem."
                    break;
                } 


                if ($url.Segments.Count -eq 4 -and $url.Segments[2] -eq 'html') {
                    $filename = "$PSScriptRoot\html\$($url.Segments[3])"
                    if (Test-Path -Path $filename) {
                        $commandOutput=Get-Content -Path $filename |Out-String
                    } else {
                        $StatusCode=404
                        $commandOutput="File not found"
                    }
                    break;
                }
               
					
		        try {

                    if ($url.Segments.Count -eq 3 -and $url.Segments[2].EndsWith('.html')) {

                        # the URL designates a file to send back
                        $filename = "$PSScriptRoot\html\$($url.Segments[2])"
                        if (Test-Path -Path $filename) {
                            $commandOutput=Get-Content -Path $filename |Out-String
                        } else {
                            $StatusCode=404
                            $commandOutput="File not found"
                        }
                    } else {
                        # Call the Business Logic function to process the request
			            $commandOutput = DoSomething $context $netid
                    }
		        }
 		        catch {
                    # If you throw an object (an HttpError), then $_ is an ErrorRecord 
                    # and the object you threw is in its TargetObject property
                    if ($_.TargetObject -and $_.TargetObject -is [HttpError]) {
                        [HttpError]$httpErrorObject = $_.TargetObject
                        $StatusCode = $httpErrorObject.Status
                        if ($httpErrorObject.Status -eq [System.Net.HttpStatusCode]::Redirect) {
                            $context.Response.RedirectLocation = $httpErrorObject.Message;
                            $commandOutput = "Redirecting to $($httpErrorObject.Message)"
                        } else {
                        $commandOutput = $httpErrorObject.Message
                        }
                    } else {
			            $commandOutput = $_
                        Write-Host "$commandOutput"
			            $statusCode = 500
                    }
		        }

            } } #end 'only case' of switch
 			
            if ($commandOutput -eq $null) {
                # if DoSomething returns $null, then it put everthing in the Response object
                # already and closed it. We do nothing execept to call GetContext() again.
                continue
            }

		    [System.Net.HttpListenerResponse]$response = $context.Response

		    $response.StatusCode = $statusCode
            $response.ContentType = 'text/html'

		    $buffer = [System.Text.Encoding]::UTF8.GetBytes("$commandOutput")
		    $response.ContentLength64 = $buffer.Length

		    $output = $response.OutputStream
		    $output.Write($buffer, 0, $buffer.Length)
		    $output.Close()
	    }
    } finally {
        # However we exit, stop the listener object if it has been started
	    if ($running) {$listener.Stop()}
    }
}
