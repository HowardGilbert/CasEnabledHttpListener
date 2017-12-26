# CasEnabledHttpListener
Powershell Web Service with CAS Authentication

While other operating systems only allow an application to bind to a Port number, Windows allows separate processes to share a port by each binding to a URL prefix like https://hostname/appname (with a different appname for each application). The kernel processes enough of the HTTP headers to figure out which process is to receive a new request, then routes the raw bytes for that request to the process address space. the HttpListner .NET class takes the bytes and turns them into Context, Request, and Response objects that we are used to in all Web application APIs.

Powershell can create an HttpListener object. This is different from running Powershell as a CGI under a regular Web server, because the script can do the time consuming initialization of loading modules and creating sessions and logging in to cloud services once, then loop fetching HTTP Requests and process them. The only downside is that each request has to finish before the next request can be fetched, so the service is single threaded.

Microsoft provides its own built in Authentication mechanisms (mostly Windows Integrated login), so one new thing here is to add an authentication mechanism using Apereo CAS. Another is to flesh out the minimal Web Server provided to support Forms and POST, but this is not a substitute for a real Web Server for intense applications.

The purpose is to provide a service that runs under an authorized identity able to configure AD, Azure AD, Google G Suite, and other types of user accounts. Authenticated users can then request through the Web services that can only be performed on their behalf by the authorized userid under which this service runs.

Some resources can be automatically allocated, but they have to be requested. Some operations can be authorized by a mechanism that is foreign to the system being managed, like making changes to a Google G Suite account based on AD group members, or making changes to AD based on Grouper membership, or changing anything based on data in the HR system. Powershell is an excellent tool for providing such services on demand to users.