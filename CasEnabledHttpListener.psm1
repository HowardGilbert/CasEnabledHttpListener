<#
    CasEnabledHttpListener
    
    Create an HttpListener object.
    Bind to https://$hostname/$appname using Windows http.sys driver. 
    Multiple copies of this logic can be running as different Powershell instances
    under the same or different users by selecting a different $appname for each one. 
    
    Loop waiting for an HTTP request to generate an HttpListenerContext object
    with an associated Request and Response object. If this is a POST, parse 
    the Form parameters in the body while GET puts them in the QueryString.

    The caller imports this module and calls Start-CasEnabledHttpListener
    
    The caller must define a global function named DoSomething which gets called back
    with a context and netid whenever a request arrives.
    
    Files (.html, .css, .js) are in the \http\* subdirectory and are sent back
    by this code. The default home page is \http\$appname.html so multiple 
    instances of this code with different appnames can share the same directory.
    
    Text objects returned from DoSomething are turned into an HTML response.
    If an HttpError object is thrown, it can set a StatusCode and provide an error message.
#>


<#  ################################################################################
	Script variables global to all functions
    ################################################################################ #>

[System.Net.HttpListenerContext]$context




<#  ################################################################################
	Local Classes 
    ################################################################################ #>

# A throwable error object    
class HttpError {
	[System.Net.HttpStatusCode]$Status
	[string]$Message
	
	HttpError([System.Net.HttpStatusCode]$status, [string]$message) {
		$this.Status = $status
		$this.Message = $message
	}
}

<#
.SYNOPSIS
	Return a HttpError object with a provided StatusCode and message to be thrown.
.DESCRIPTION
	It is hard to share a class definition with the DoSomething function, but easy
	to share a function. This function substitutes for a constructor of this
	throwable object.
.PARAMETER Status
	A StatusCode which is natively an [int], but can be expressed as a [string] name or
	a member of the [System.Net.HttpStatusCode] enum.
.PARAMETER Message
	A text error message (or URL on a Redirect).
.OUTPUTS 
	An HttpError object suitable for being thrown 
.EXAMPLE 
    throw New-HttpError ([System.Net.HttpStatusCode]::BadRequest) "Google G Suite Eliapps account not found"
    throw New-HttpError 400 "Google G Suite Eliapps account not found"
    throw New-HttpError "BadRequest" "Google G Suite Eliapps account not found"
#>
function New-HttpError {
	
	param (
		[System.Net.HttpStatusCode]$Status,
		[string]$Message
	)
	
	return [HttpError]::new($Status, $Message)
}







<#  ################################################################################
	Start-CasEnabledHttpListener is called by the main script to start everything up
    ################################################################################ #>

<#
.SYNOPSIS
	Create an HttpListener, loop calling getContext(), handle requests for files, call DoSomething
	to handle all the request for service.
.DESCRIPTION
	This function is called once and when it ends the program ends.
	It creates an HttpListener bound to the default SSL port and receives requests for $appname.
	Requests are authenticated through CAS.
	URLs for files like .html, .css, .js are handled here.
	Everything else is sent to the DoSomething callback function.
.PARAMETER hostname
	The name the Browser uses as hostname to get to this service
.PARAMETER appname
	The top level element in the path. The URL begins with https://$hostname/$appname
#>
function Start-CasEnabledHttpListener {
	[CmdletBinding()]
	param (
		[string]$hostname = 'localhost',
		[string]$appname = 'service'
		
	)
	
	# Add in the CAS Client code for Authentication
	Import-Module "$PSScriptRoot\CasClient.psm1" -Force -ArgumentList $hostname, $appname
	
	
	
	$listener = New-Object System.Net.HttpListener
	
	$listener.Prefixes.Add("http://$hostname/$appname/") # Bind to port 80, but only to redirect to https
	$listener.Prefixes.Add("https://$hostname/$appname/") # Real input comes here.
	$listener.IgnoreWriteExceptions = $true  # Don't want exceptions if user closes Browser while we are writing to it
	$listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous
	Write-Verbose "Listening on $($listener.Prefixes)"
	
	# Allow DoSomething to have a global variable it can set to $false to shut down the service remotely
	$global:ContinueHttpProcessing = $true
		
	$listener.Start()
		
	try {
		# In any other language there would be a try block to close the Listener, so why not here?
		
		while ($global:ContinueHttpProcessing) {
			
		<#  ################################################################################
			The program sits here most of the time, waiting for an incoming HTTP request.
			################################################################################ #>
			Write-Host "Thread is blocked waiting for the next Web Request."
			[System.Net.HttpListenerContext]$script:context = $listener.GetContext()
			
			
			
			
			try {
				# Catch exceptions processing the Context, Request, and Response.  
				# All we can do is discard them and get a new Context. 
				# Can create this failure in debugging by closing the browser while stopped at a breakpoint.
				
				
				# Prepare the Response for a default HTML text return
				$context.Response.StatusCode = 200
				$context.Response.ContentType = 'text/html'
				
				# Get the URL that points to this machine and application
				[System.Uri]$url = $context.Request.Url
				
				# Get the Referer Header information in a Redirect or POST from another computer
				[System.Uri]$referrer = $context.Request.UrlReferrer
				
				# Get the Origin Header, which replaces Referer in newer Browsers
				$originheader = $context.Request.Headers['Origin']
				
				
				if (-not $context.Request.IsSecureConnection) {
					Write-Verbose "Redirecting user to SSL"
					$context.Response.Redirect("https://$hostname/$appname/")
					$context.Response.Close() # Sends the Redirect back to the Browser
					continue # go to start of loop and wait for next HTTP Request
				}
				
				# CAS Authenticate
				$RequestedBy = Get-CasUser $context -Verbose
				if (!$RequestedBy) {
					# Get-CASUser put Redirect into Response and closed it.
					continue
				}
				
				
				try {
					# Try to send a Response message to the user, either normal or error.
					# In this block Exceptions are turned into an Error message.
					# Errors sending the Response are handled by the outer try.
					
					
					if ($url.GetLeftPart('Path') -eq "https://$hostname/$appname/") {
						# Leave Home Page URL alone. It does not require CSRF checks.
						
					}
					elseif ($url.GetLeftPart('Path') -eq "https://$hostname/$appname") {
						Write-Verbose "Redirecting to add / after application name"
						$context.Response.Redirect("https://$hostname/$appname/")
						$context.Response.Close() # Sends the Redirect back to the Browser
						continue # go to start of loop and wait for next HTTP Request
						
					}
					elseif ($originheader -and $originheader -ne "https://$hostname") {
						throw New-HttpError "BadRequest" "Request originated from another computer $originheader"
						
					}
					elseif ($referrer -and $url.Authority -ne $referrer.Authority) {
						throw New-HttpError "BadRequest" "Request referred from another computer $referrer"
					}
					
					
					
					
					# $filename gets either the path to a file in the \html\ subdirectory or $null
					$filename = Get-FilenameFromUrl($url)
					
					if ($filename) {
						if (!(Test-Path -Path $filename)) {
							throw New-HttpError 404 "File Not Found"
						}
						$commandOutput = Get-ContentFromFile $filename $context
					}
					else {
						# Not a file request, so prepare to call DoSomething
						
						$RequestParameters = @{ } # Start with a new empty HashTable
						if ($context.Request.HttpMethod -eq 'POST') {
							if ($context.Request.HasEntityBody) {
								$Reader = New-Object System.IO.StreamReader($context.Request.InputStream)
								$postdata = $Reader.ReadToEnd()
								# postdata is in the form name1=value1&name2=value2, with values escaped.
								foreach ($x in $postdata -split '&') {
									$y = $x -split '='
									if ($y.Count -eq 2) { $RequestParameters[$y[0]] = [System.Uri]::UnEscapeDataString($y[1]) }
								}
							}
						}
						elseif ($context.Request.HttpMethod -eq 'GET') {
							# HttpListener has parsed the QueryString, so just copy it over
							foreach ($key in $context.Request.QueryString.AllKeys) {
								$RequestParameters[$key] = $context.Request.QueryString[$key]
							}
						}
						
						# Require forms to have the CSRFToken because Referer and Origin don't always work
						$CSRFToken = $RequestParameters['CSRFToken']
						if (!$CSRFToken -or -not (Test-CSRFTokenValue $CSRFToken)) {
							throw New-HttpError "BadRequest" "Form did not contain a CSRFToken from this computer"
						}
						
						$commandOutput = DoSomething -Context $context -RequestedBy $RequestedBy -RequestParameters $RequestParameters
						# returns $null only if it closed the Response
						if (!$commandOutput) { continue }
					}
				}
				catch {
					# If you throw an object (an HttpError), then $_ is an ErrorRecord 
					# and the object you threw is in its TargetObject property
					if ($_.TargetObject -and $_.TargetObject -is [HttpError]) {
						[HttpError]$httpErrorObject = $_.TargetObject
						$context.Response.StatusCode = $httpErrorObject.Status
						if ($httpErrorObject.Status -eq [System.Net.HttpStatusCode]::Redirect) {
							$context.Response.RedirectLocation = $httpErrorObject.Message;
							$commandOutput = "Redirecting to $($httpErrorObject.Message)"
						}
						else {
							$commandOutput = $httpErrorObject.Message
						}
					}
					else {
						# It is a real .NET exception, some program bug
						$commandOutput = $_
						Write-Host "$commandOutput"
						$context.Response.StatusCode = 500
					}
				}
				
				
				# Turn the content of $commandOutput to an HTTP response.
				[System.Net.HttpListenerResponse]$response = $context.Response
				
				if ($commandOutput -and $commandOutput -is [array] -and $commandOutput[0] -is [byte]) {
					# We have a byte[] from a binary file like an image
					$buffer = $commandOutput
				}
				else {
					# Everything else is some sort of text file (html, css, js, ..)
					$responseText = $commandOutput | Out-String
					$buffer = [System.Text.Encoding]::UTF8.GetBytes($responseText)
				}
				$response.ContentLength64 = $buffer.Length
				
				$output = $response.OutputStream
				$output.Write($buffer, 0, $buffer.Length)
				$output.Close()
			}
			catch {
				Write-Host "Unspecific logic error in Context processing $_"
			}
		}
	}
	finally {
		$listener.Stop()
	}
}



<#
.SYNOPSIS
	Examine URL for a reference to a file that should be sent back
.DESCRIPTION
	Look for a URL that represents a request for the Home Page, or an HTML Form, or
	a support file (css, js, etc.). All files come from the \html\ subdirectory
.PARAMETER url
	The [System.Uri] object attached to the HttpListnerRequest object.
.OUTPUTS
	String path to file, or $null if this is not a file URL.
#>
function Get-FilenameFromUrl {
    <#
    	Internal function 
    	
    	Convert URL representing a static file to the local fully qualified path of the file.
    	File are all in the \html subdirectory of the directory containing this script.
    	
    	https://$hostname/$appname/html/*.* (any file)
    	https://$hostname/$appname/*.html (file in /html/ subdirectory, but URL appears to be one level up) 
    	https://$hostname/$appname/ (the home page, actually /html/$appname.html if it exists)
    	
    	Anything else is not a file request and is handled by DoSomething
    	
        The Segments property is an array of path elements including any ending / 
        Segments[0] is always the "/" that follows hostname+port
        Segments[1] is "$appname" or "$appname/"
        Segments[2] is a verb for DoSomething,  "html/", or the name of an html file
        Segments[3] is a file name if the previous segment is "html/"
     #>
	
	param ([System.Uri]$url)
	
	$filename = $null # return $null unless URL matches a file pattern
	
	if ($url.Segments.Count -eq 3 -and $url.Segments[2].EndsWith('.html')) {
		# https://$hostname/$appname/*.html
		$filename = "$PSScriptRoot\html\$($url.Segments[2])"
	}
	elseif ($url.Segments.Count -eq 2) {
		# https://$hostname/$appname/
		# Return the home page if it exists, otherwise DoSomething has to respond.
		$homepage = "$PSScriptRoot\html\$appname.html"
		if (Test-Path -Path $homepage) { $filename = $homepage }
	}
	elseif ($url.Segments.Count -eq 4 -and $($url.Segments[2] -eq "html/")) {
		# ttps://$hostname/$appname/*.html
		$filename = "$PSScriptRoot\html\$($url.Segments[3])"
	}
	
	# Anything else goes to DoSomething, but generally it is expected to be $appname/verb
	
	return $filename
	
}

<#
.SYNOPSIS
	Send the content of a file given the path to the file on disk
.DESCRIPTION
	Minimal Web File Server capability to send back the content of files in the \html\ 
	subdirectory of the script directory. Typically used to display HTML Forms so the
	user can enter basic information about a request. There is no optimization, so this
	should never be used for high volume activity.
.PARAMETER filename
	A string containing the full local file path and name of the file to send back. 
	Must not be $null and the file must exist on disk and not be empty.
.OUTPUTS
	A string, array of strings, or byte array (binary file)
.NOTES
	Supports .html, .css, .jsp, and maybe .jpg files. That is good enough. If you try
	to add other stuff you may need to stop and code everything in a real Web Server
	in some other programming language. 
#>
function Get-ContentFromFile {
	
	param (
		[string]$filename
	)
	
	# Image files like jpg are binary, but everything else is text.
	[bool]$BinaryFileType = $false
	
	# Special MIME ContentType based on file extensions (default was text/html)
	if ($filename.EndsWith('.js')) {
		$context.Response.ContentType = 'application/javascript'
	}
	elseif ($filename.EndsWith('.css')) {
		$context.Response.ContentType = 'text/css'
	}
	elseif ($filename.EndsWith('.jpg')) {
		$context.Response.ContentType = 'image/jpeg'
		$BinaryFileType = $true
		# Leave room here for adding other types
	}
	
	if ($BinaryFileType) {
		# JPEG image is an array of bytes 
		$commandOutput = Get-Content -Path $filename -Encoding Byte
	}
	else {
		# PS idiom: Get-Content on text file produces an array of lines, Out-String combines them to one [string]
		$commandOutput = Get-Content -Path $filename | Out-String
		
		if ($commandOutput.StartsWith('@"')) {
			# Allow embedded PS in the file by executing it as a script
			try {
				# Execute the file contents as Powershell. The page will generate one or
				# a list of text items that get sent to the user as output
				$commandOutput = Invoke-Expression -Command $commandOutput
			}
			catch {
				# The page contained a Powershell error. 
				$commandOutput = "Error during execution of the $filename. Report the following error:<br> $_ 
                $($_.ScriptStackTrace)"
			}
		}
		else {
			$commandOutput = $commandOutput -replace '\$\(Get-CSRFTokenValue\)', $(Get-CSRFTokenValue)
		}
	}
	return $commandOutput
}




