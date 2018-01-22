# CasEnabledHttpListener
Powershell Web Service with CAS Authentication

While other operating systems only allow an application to bind to a Port number, Windows allows separate processes to share a port by each binding to a URL prefix like https://hostname/appname (with a different appname for each application). The kernel processes enough of the HTTP headers to figure out which process is to receive a new request, then routes the raw bytes for that request to the process address space. the HttpListner .NET class takes the bytes and turns them into Context, Request, and Response objects that we are used to in all Web application APIs.

Unlike running other scripts in CGI mode under a Web Server, Powershell can do the time consuming initialization to load modules, create sessions, and loging to Cloud services, then create an HttpListener and loop processing incoming Web requests in an already initialized environment. Because it is single threaded, each request must be completely processed and a response sent back to the user before the next request can be fetched.

Microsoft provides its own built in Authentication mechanisms (mostly Windows Integrated login), so one new thing here is to add an authentication mechanism using Apereo CAS. Another is to flesh out the minimal Web Server provided to support Forms and POST, but this is not a substitute for a real Web Server for intense applications.

The purpose is to provide a service that runs under an authorized identity able to configure AD, Azure AD, Google G Suite, and other types of user accounts. Authenticated users can then request through the Web services that can only be performed on their behalf by the authorized userid under which this service runs.

It is probably convenient to run different instances of this code under different /appnames to service different groups of users. One set of services would be provided to the Help Desk and administrators. A more limited set of services under a different name would support self-service requests that end users can make themselves.