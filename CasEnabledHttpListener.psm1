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
			
	# Add a tag of :nextContext and then code can come back by "continue nextContext"
	# Generally this is done on a Redirect after the Response is filled in and closed
:nextContext while ($global:ContinueHttpProcessing) {
				
			# Calling GetContext() waits for a new Http request to arrive
		    Write-Host "Thread is blocked waiting for the next Web Request."
		    [System.Net.HttpListenerContext] $context = $listener.GetContext()
		    
		    # Prepare the Response for a default HTML text return
		    $statusCode = 200
            $context.Response.ContentType = 'text/html'
            $BinaryFileType=$false
            
            # Create a global variable so the context can be found without being passed as an argument
            # (Not actually used by any code now, but seems like a good idea in the long run)
            # We can do this because Powershell is single threaded so there is only one Context at a time
		    [System.Net.HttpListenerContext] $global:CasEnabledHttpListenerContext = $context

            [System.Uri] $url = $context.Request.Url

 
 
 			# This dummy switch encloses a block of tests. To stop processing
 			# and begin to generate the Response, just "break" out of the block
            switch ('only case') {
                'only case' {

            
                # Any use of port 80 gets redirected to https. 
                if (-not $context.Request.IsSecureConnection) {
                    Write-Verbose "Redirecting user to https"
                    $context.Response.Redirect("https://$hostname/$appname/$($url.PathAndQuery)")
                    $context.Response.Close() # Sends the Redirect back to the Browser
                    continue nextContext; # go to start of loop and wait for next HTTP Request
                }  

                
                # CAS Authenticate
                $netid = Get-CasUser $context -Verbose
                if (!$netid) {
                	# Get-CASUser put Redirect into Response and closed it.
                	# Go back to wait for next HTTP Request.
                    continue nextContext
                }  
                 
             

                <#
                	Handle URLs for static pages (html, css, js, etc.) in the /html/ subdirectory
                	
                	https://$hostname/$appname/html/*.* (any file)
                	https://$hostname/$appname/*.html (file in /html/ subdirectory, but URL appears to be one level up) 
                	https://$hostname/$appname (the home page, actually /html/$appname.html if it exists)
                	
                	Anything else is handled by DoSomething
                #>
                
                # Assume not a static page unless this is set
                $filename=$null
                
                # The Segments property is an array of path elements including any ending / 
                # Segments[0] is always the "/" that follows hostname+port
                # Segments[1] is "$appname" or "$appname/"
                # Segments[2] if it exists is "html/", or the name of an html file, or a verb for DoSomething
                
                if ($url.Segments.Count -eq 3 -and $url.Segments[2].EndsWith('.html')) {
                
                    # https://$hostname/$appname/page.html - we send back .\html\page.html
                    
                    $filename = "$PSScriptRoot\html\$($url.Segments[2])"
                    
                } elseif ($url.Segments.Count -eq 2) {
                
                	if (-not $url.Segments[1].EndsWith('/')) {
                		# If the URL is "https://$hostname/$appname" with no ending "/" then
                        # the Browser thinks we are in the //$hostname/* directory level. We need
                        # the Browser to understand that we are in the //$hostname/$appname/* 
                        # directory level, and the universally accepted way to do this is to
                        # Redirect the browser back here adding the missing "/" on the end
                        # of the URL.
	                    $context.Response.Redirect("https://$hostname/$appname/")
	                    $context.Response.Close() # Sends the Redirect back to the Browser
	                    continue nextContext; # go to start of loop and wait for next HTTP Request
                	}
                
                    # https://$hostname/$appname/ has traditionally been mapped to an index.html file. 
                    # However, more than one $appname can share the same directory. So for us, 
                    # the default home page is \html\$appname.html.
                    # if that file doesn't exist, let DoSomething generate a response
                    
                    $homepage = "$PSScriptRoot\html\$appname.html"
                    if (Test-Path -Path $homepage) {$filename=$homepage}
                    
                } elseif ($url.Segments.Count -eq 4 -and $($url.Segments[2] -eq "html/")) {
                
                	# Any URL in the $appname/html/ directory is what it appears to be
                    # https://$hostname/$appname/html/foo.css goes to .\html\foo.css
                    $filename = "$PSScriptRoot\html\$($url.Segments[3])"
                }


                <#
                    When the URL is https://$hostname/$appname/verb (no ending file type) then
                    the verb is a command to send to DoSomething and let code handle it. The logic
                    has not generated a $filename so this block does nothing. 

                    If there is a $filename, then the ending file type may change the MIME string.

                    There is a poor man's JSP/PHP trick. If a text (html, css, js) file begins with
                    what Powershell calls a HereString delimiter (@") then treat it as an expression
                    and execute it with Invoke-Expression. Just as asp and jsp pages can have embedded
                    java code, this type of html page can have embedded $(...) Powershell expressions.
                #>
                if ($filename) {
                    # If the previous logic produced a filename, send the file if it exists
                    if (Test-Path -Path $filename) {
                        # Special mime types for included files
                        if ($filename.EndsWith('.js')) {
            				$context.Response.ContentType = 'application/javascript'
        				} elseif ($filename.EndsWith('.css')) {
            				$context.Response.ContentType = 'text/css'
        				} elseif ($filename.EndsWith('.jpg')) {
            				$context.Response.ContentType = 'image/jpeg'
                            $BinaryFileType=$true
                        # Leave room here for adding other types
                        # Remember, default is 'text/html'
        				}

                        # Get-Content returns an array of [string] for text files and of [byte] for binary files
                        if ($BinaryFileType) {
                            $commandOutput=Get-Content -Path $filename -Encoding Byte
                        } else {
                            $commandOutput=Get-Content -Path $filename |Out-String
                            if ($commandOutput.StartsWith('@"')) {
                                $commandOutput = Invoke-Expression -Command $commandOutput
                            }
                        }
                    
                    } else {
                        $StatusCode=404
                        $commandOutput="File not found"
                    }
                    break;
                }

                <#
                    A required security check. If any other computer (even CAS) redirects
                    the user to this computer with a command URL 
                    (https://$hostname/$appname/command?parm=value) and we execute that
                    command, then we could be fooled into doing something under the user's
                    authority that the user did not actually intend. We cannot allow CAS
                    any special rights, because then someone simply redirects to CAS with
                    a service= that points to this application and includes the command and parameters.
                    So whenever we get a redirect or form submission from another computer, discard
                    the command and parameters and go to the home page of this application. 
                #>
                [System.Uri] $referrer = $context.Request.UrlReferrer
                if ($referrer -and $url.Authority -ne $referrer.Authority) {
	                $context.Response.Redirect("https://$hostname/$appname/")
	                $context.Response.Close() # Sends the Redirect back to the Browser
	                continue nextContext; # go to start of loop and wait for next HTTP Request
                } 


		        try {

                    # Call the Business Logic function to process the request
			        $commandOutput = DoSomething $context $netid
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
                # already and closed it. We do nothing except to call GetContext() again.
                continue
            }

		    [System.Net.HttpListenerResponse]$response = $context.Response

		    $response.StatusCode = $statusCode
            
            if (-not $BinaryFileType) {
                $responseText = $commandOutput|Out-String
		        $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseText)
            } else {
                $buffer = $commandOutput
            }
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
