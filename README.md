# CasEnabledHttpListener
Powershell Web Service with CAS Authentication

Windows has a Web Server built into the Kernel. Http.sys binds to ports, examines the HTTP headers in each incoming request, and routes the bytes to an application address space based on hostname and URL path. The HttpListener .NET class takes the bytes and turns them into Context, Request, and Response objects that we are used to in all Web application APIs.

.NET objects can be created in Powershell. The script can do the slow initialization one time,loading modules and establishing connections to servers and databases, then loop receiving and processing requests. Powershell aleady has excellent support for administrative functions when it runs under a privileged userid. To be useful at Yale, however, we need users to authenticate through CAS.

Then based on eduPersonAffiliation, or AD group membership, or Grouper, ordinary users can make self-service requests for administrative services to which they are automatically entitled, and Help Desk people can authenticate and trigger packaged operations on behalf of user requests that may require some approval or tracking.

This is a very small piece of code to fill in a small gap and turn an often overlooked standard Windows service into a useful tool that can solve lots of small problems quickly, simply, efficiently, and securely. It is oriented toward universities (CAS) but you can read and change the code if you want something else. 