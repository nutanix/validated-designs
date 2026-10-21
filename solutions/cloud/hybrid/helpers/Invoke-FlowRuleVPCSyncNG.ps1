<#
.SYNOPSIS
  Use this script to synchronize Nutanix Flow policies between two Prism Central instances.
.DESCRIPTION
  Given a source and target Prism Central, a category and a policy name prefix, script will synchronize Nutanix Flow policies between both Prism Central (from source to target).
.PARAMETER help
  Displays a help message (seriously, what did you think this was?)
.PARAMETER history
  Displays a release history for this script (provided the editors were smart enough to document this...)
.PARAMETER log
  Specifies that you want the output messages to be written in a log file as well as on the screen.
.PARAMETER debugme
  Turns off SilentlyContinue on unexpected error messages.
.PARAMETER sourcePc
  Source Prism Central fully qualified domain name or IP address.
.PARAMETER targetPc
  Target Prism Central fully qualified domain name or IP address.
.PARAMETER prismCreds
  Specifies a custom credentials file name (will look for %USERPROFILE\Documents\WindowsPowerShell\CustomCredentials\$prismCreds.txt). These credentials can be created using the Powershell command 'Set-CustomCredentials -credname <credentials name>'. See https://blog.kloud.com.au/2016/04/21/using-saved-credentials-securely-in-powershell-scripts/ for more details.
.PARAMETER action
  Can be either sync (to synchronize changes from source to target) or delete(to delete all the synced policies).
.PARAMETER prefix
  Prefix of Flow policy names on source to consider (this prevents deleting policy that need to exist only on target).
.PARAMETER rename
  Sync the policies in target PC with an added prefix to the name. Pass the prefix to be added to the name.
  Should be only used once before enabling Entity Sync Multi PC DR feature for Flow.
.EXAMPLE
  .\Invoke-FlowRuleSync.ps1 -sourcePc pc1.local -targetPc pc2.local -prismCreds myadcreds -action sync -prefix flowPc1
  Synchronize all policies starting with flowPc1 from pc1 to pc2
.LINK
  http://www.nutanix.com/services
.NOTES
  Author: Pramod Singh (pramod.singh@nutanix.com) & Stephane Bourdeaud (stephane.bourdeaud@nutanix.com)
  Revision: Jul 28th 2025
#>


#region parameters
    Param
    (
        #[parameter(valuefrompipeline = $true, mandatory = $true)] [PSObject]$myParam1,
        [parameter(mandatory = $false)] [switch]$help,
        [parameter(mandatory = $false)] [switch]$history,
        [parameter(mandatory = $false)] [switch]$log,
        [parameter(mandatory = $false)] [switch]$debugme,
        [parameter(mandatory = $false)] [string]$sourcePc,
        [parameter(mandatory = $false)] [string]$targetPc,
        [parameter(mandatory = $false)] [string]$prefix,
    [parameter(mandatory = $false)][ValidateSet("sync", "delete")] [string]$action,
        [parameter(mandatory = $false)] [string]$rename,
        [parameter(mandatory = $false)] $prismCreds
    )
#endregion


#region functions
    #this function is used to process output to console (timestamped and color coded) and log file
    function Write-LogOutput
    {#used to format output
        <#
        .SYNOPSIS
        Outputs color coded messages to the screen and/or log file based on the category.

        .DESCRIPTION
        This function is used to produce screen and log output which is categorized, time stamped and color coded.

        .PARAMETER Category
        This the category of message being outputed. If you want color coding, use either "INFO", "WARNING", "ERROR" or "SUM".

        .PARAMETER Message
        This is the actual message you want to display.

        .PARAMETER LogFile
        If you want to log output to a file as well, use logfile to pass the log file full path name.

        .NOTES
        Author: Pramod Singh (sbourdeaud@nutanix.com)

        .EXAMPLE
        .\Write-LogOutput -category "ERROR" -message "You must be kidding!"
        Displays an error message.

        .LINK
        https://github.com/sbourdeaud
        #>
        [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

        param
        (
            [Parameter(Mandatory)]
            [ValidateSet('INFO','WARNING','ERROR','SUM','SUCCESS','STEP','DEBUG','DATA')]
            [string]
            $Category,

            [string]
            $Message,

            [string]
            $LogFile
        )

        process
        {
            $Date = get-date #getting the date so we can timestamp the output entry
            $FgColor = "Gray" #resetting the foreground/text color
            switch ($Category) #we'll change the text color depending on the selected category
            {
                "INFO" {$FgColor = "Green"}
                "WARNING" {$FgColor = "Yellow"}
                "ERROR" {$FgColor = "Red"}
                "SUM" {$FgColor = "Magenta"}
                "SUCCESS" {$FgColor = "Cyan"}
                "STEP" {$FgColor = "Magenta"}
                "DEBUG" {$FgColor = "White"}
                "DATA" {$FgColor = "Gray"}
            }

            Write-Host -ForegroundColor $FgColor "$Date [$category] $Message" #write the entry on the screen
            if ($LogFile) #add the entry to the log file if -LogFile has been specified
            {
                Add-Content -Path $LogFile -Value "$Date [$Category] $Message"
                Write-Verbose -Message "Wrote entry to log file $LogFile" #specifying that we have written to the log file if -verbose has been specified
            }
        }

    }#end function Write-LogOutput

    #this function loads a powershell module
    function LoadModule
    {#tries to load a module, import it, install it if necessary
        <#
        .SYNOPSIS
        Tries to load the specified module and installs it if it can't.
        .DESCRIPTION
        Tries to load the specified module and installs it if it can't.
        .NOTES
        Author: Pramod Singh
        .PARAMETER module
        Name of PowerShell module to import.
        .EXAMPLE
        PS> LoadModule -module PSWriteHTML
        #>
        param
        (
            [string] $module
        )

        begin
        {

        }

        process
        {
            Write-LogOutput -Category "INFO" -LogFile $myvar_log_file -Message "Trying to get module $($module)..."
            if (!(Get-Module -Name $module))
            {#we could not get the module, let's try to load it
                try
                {#import the module
                    Import-Module -Name $module -ErrorAction Stop
                    Write-LogOutput -Category "SUCCESS" -LogFile $myvar_log_file -Message "Imported module '$($module)'!"
                }#end try
                catch
                {#we couldn't import the module, so let's install it
                    Write-LogOutput -Category "INFO" -LogFile $myvar_log_file -Message "Installing module '$($module)' from the Powershell Gallery..."
                    try
                    {#install module
                        Install-Module -Name $module -Scope CurrentUser -Force -ErrorAction Stop
                    }
                    catch
                    {#could not install module
                        Write-LogOutput -Category "ERROR" -LogFile $myvar_log_file -Message "Could not install module '$($module)': $($_.Exception.Message)"
                        exit 1
                    }

                    try
                    {#now that it is intalled, let's import it
                        Import-Module -Name $module -ErrorAction Stop
                        Write-LogOutput -Category "SUCCESS" -LogFile $myvar_log_file -Message "Imported module '$($module)'!"
                    }#end try
                    catch
                    {#we couldn't import the module
                        Write-LogOutput -Category "ERROR" -LogFile $myvar_log_file -Message "Unable to import the module $($module).psm1 : $($_.Exception.Message)"
                        Write-LogOutput -Category "WARNING" -LogFile $myvar_log_file -Message "Please download and install from https://www.powershellgallery.com"
                        Exit 1
                    }#end catch
                }#end catch
            }
        }

        end
        {

        }
    }

    function Set-CustomCredentials
    {#creates files to store creds
        #input: path, credname
            #output: saved credentials file
        <#
        .SYNOPSIS
        Creates a saved credential file using DAPI for the current user on the local machine.
        .DESCRIPTION
        This function is used to create a saved credential file using DAPI for the current user on the local machine.
        .NOTES
        Author: Pramod Singh
        .PARAMETER path
        Specifies the custom path where to save the credential file. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
        .PARAMETER credname
        Specifies the credential file name.
        .EXAMPLE
        .\Set-CustomCredentials -path c:\creds -credname prism-apiuser
        Will prompt for user credentials and create a file called prism-apiuser.txt in c:\creds
        #>
        param
        (
            [parameter(mandatory = $false)]
            [string]
            $path,

            [parameter(mandatory = $true)]
            [string]
            $credname
        )

        begin
        {
            if (!$path)
            {
                if ($IsLinux -or $IsMacOS)
                {
                    $path = $home
                }
                else
                {
                    $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
                }
                Write-Host "$(get-date) [INFO] Set path to $path" -ForegroundColor Green
            }
        }
        process
        {
            #prompt for credentials
            $credentialsFilePath = "$path\$credname.txt"
            $credentials = Get-Credential -Message "Enter the credentials to save in $path\$credname.txt"

            #put details in hashed format
            $user = $credentials.UserName
            $securePassword = $credentials.Password

            #convert secureString to text
            try
            {
                $password = $securePassword | ConvertFrom-SecureString -ErrorAction Stop
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not convert password : $($_.Exception.Message)"
            }

            #create directory to store creds if it does not already exist
            if(!(Test-Path $path))
            {
                try
                {
                    $result = New-Item -type Directory $path -ErrorAction Stop
                }
                catch
                {
                    throw "$(get-date) [ERROR] Could not create directory $path : $($_.Exception.Message)"
                }
            }

            #save creds to file
            try
            {
                Set-Content $credentialsFilePath $user -ErrorAction Stop
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not write username to $credentialsFilePath : $($_.Exception.Message)"
            }

            try
            {
                Add-Content $credentialsFilePath $password -ErrorAction Stop
            }
            catch
            {
                throw "$(get-date) [ERROR] Could not write password to $credentialsFilePath : $($_.Exception.Message)"
            }

            Write-Host "$(get-date) [SUCCESS] Saved credentials to $credentialsFilePath" -ForegroundColor Cyan
        }
        end
        {}
    }

    #this function is used to retrieve saved credentials for the current user
    function Get-CustomCredentials
    {#retrieves creds from files
        #input: path, credname
            #output: credential object
        <#
        .SYNOPSIS
        Retrieves saved credential file using DAPI for the current user on the local machine.
        .DESCRIPTION
        This function is used to retrieve a saved credential file using DAPI for the current user on the local machine.
        .NOTES
        Author: Pramod Singh
        .PARAMETER path
        Specifies the custom path where the credential file is. By default, this will be %USERPROFILE%\Documents\WindowsPowershell\CustomCredentials.
        .PARAMETER credname
        Specifies the credential file name.
        .EXAMPLE
        .\Get-CustomCredentials -path c:\creds -credname prism-apiuser
        Will retrieve credentials from the file called prism-apiuser.txt in c:\creds
        #>
        param
        (
            [parameter(mandatory = $false)]
            [string]
            $path,

            [parameter(mandatory = $true)]
            [string]
            $credname
        )

        begin
        {
            if (!$path)
            {
                if ($IsLinux -or $IsMacOS)
                {
                    $path = $home
                }
                else
                {
                    $path = "$Env:USERPROFILE\Documents\WindowsPowerShell\CustomCredentials"
                }
                Write-Host "$(get-date) [INFO] Retrieving credentials from $path" -ForegroundColor Green
            }
        }

        process
        {
            $credentialsFilePath = "$path\$credname.txt"
            if(!(Test-Path $credentialsFilePath))
            {
                throw "$(get-date) [ERROR] Could not access file $credentialsFilePath : $($_.Exception.Message)"
            }

            $credFile = Get-Content $credentialsFilePath
            $user = $credFile[0]
            $securePassword = $credFile[1] | ConvertTo-SecureString

            $customCredentials = New-Object System.Management.Automation.PSCredential -ArgumentList $user, $securePassword

            Write-Host "$(get-date) [SUCCESS] Returning credentials from $credentialsFilePath" -ForegroundColor Cyan
        }

        end
        {
            return $customCredentials
        }
    }

    #this function is used to make sure we use the proper Tls version (1.2 only required for connection to Prism)
    function Set-PoshTls
    {#disables unsecure Tls protocols
        <#
        .SYNOPSIS
        Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

        .DESCRIPTION
        Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

        .NOTES
        Author: Pramod Singh (sbourdeaud@nutanix.com)

        .EXAMPLE
        .\Set-PoshTls
        Makes sure we use the proper Tls version (1.2 only required for connection to Prism).

        .LINK
        https://github.com/sbourdeaud
        #>
        [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

        param
        (

        )

        begin
        {
        }

        process
        {
            Write-Host "$(Get-Date) [INFO] Adding Tls12 support" -ForegroundColor Green
            [Net.ServicePointManager]::SecurityProtocol = `
            ([Net.ServicePointManager]::SecurityProtocol -bor `
            [Net.SecurityProtocolType]::Tls12)
        }

        end
        {

        }
    }

    #this function is used to configure posh to ignore invalid ssl certificates
    function Set-PoSHSSLCerts
    {#configures posh to ignore self-signed certs
        <#
        .SYNOPSIS
        Configures PoSH to ignore invalid SSL certificates when doing Invoke-RestMethod
        .DESCRIPTION
        Configures PoSH to ignore invalid SSL certificates when doing Invoke-RestMethod
        #>

        begin
        {

        }#endbegin

        process
        {
            Write-Host "$(Get-Date) [INFO] Ignoring invalid certificates" -ForegroundColor Green
            if (-not ([System.Management.Automation.PSTypeName]'ServerCertificateValidationCallback').Type) {
                $certCallback = @"
using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public class ServerCertificateValidationCallback
{
public static void Ignore()
{
    if(ServicePointManager.ServerCertificateValidationCallback ==null)
    {
        ServicePointManager.ServerCertificateValidationCallback +=
            delegate
            (
                Object obj,
                X509Certificate certificate,
                X509Chain chain,
                SslPolicyErrors errors
            )
            {
                return true;
            };
    }
}
}
"@
                Add-Type $certCallback
            }#endif
            [ServerCertificateValidationCallback]::Ignore()
        }#endprocess

        end
        {

        }#endend
    }#end function Set-PoSHSSLCerts

    #Builds a basic-auth header and frees the unmanaged password buffer.
    function Get-BasicAuthHeaderValue
    {
        param
        (
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $Credential
        )

        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        try
        {
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            $token = "{0}:{1}" -f $Credential.UserName, $plain
            $encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($token))
            return "Basic $encoded"
        }
        finally
        {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    function Get-HttpHeaderValue
    {
        param
        (
            $Headers,
            [Parameter(Mandatory = $true)][string] $Name
        )

        if ($null -eq $Headers) { return $null }
        $value = $null
        try { $value = $Headers[$Name] } catch { $value = $null }
        if (-not $value -and $Headers.PSObject.Properties[$Name])
        {
            $value = $Headers.PSObject.Properties[$Name].Value
        }
        if ($value -is [System.Array]) { $value = $value[0] }
        if ($null -eq $value) { return $null }
        return [string]$value
    }

    #OData string literals escape a single quote by doubling it. The query is then URL-encoded.
    function ConvertTo-ODataStringLiteral
    {
        param
        (
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string] $Value
        )

        return "'" + ($Value -replace "'", "''") + "'"
    }

    function ConvertTo-ODataFilterQuery
    {
        param
        (
            [Parameter(Mandatory = $true)][string] $Expression
        )

        return '$filter=' + [uri]::EscapeDataString($Expression)
    }

    #this function is used to make a REST api call to Prism
    function Invoke-PrismAPICall
    {#makes a REST API call to Prism
        <#
        .SYNOPSIS
        Makes api call to prism based on passed parameters. Returns the json response.
        .DESCRIPTION
        Makes api call to prism based on passed parameters. Returns the json response.
        .NOTES
        Author: Pramod Singh
        .PARAMETER method
        REST method (POST, GET, DELETE, or PUT)
        .PARAMETER credential
        PSCredential object to use for authentication.
        PARAMETER url
        URL to the api endpoint.
        PARAMETER payload
        JSON payload to send.
        .EXAMPLE
        .\Invoke-PrismAPICall -credential $MyCredObject -url https://myprism.local/api/v3/vms/list -method 'POST' -payload $MyPayload
        Makes a POST api call to the specified endpoint with the specified payload.
        #>
        param
        (
            [parameter(mandatory = $true)]
            [ValidateSet("POST","GET","DELETE","PUT")]
            [string]
            $method,

            [parameter(mandatory = $true)]
            [string]
            $url,

            [parameter(mandatory = $false)]
            [string]
            $payload,

            [parameter(mandatory = $false)]
            [string]
            $ntnx_req_id,

            [parameter(mandatory = $false)]
            [string]
            $if_match,

            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential,

            [parameter(mandatory = $false)]
            [switch]
            $ReturnETag
        )

        begin
        {
            $headers = @{
                "Content-Type" = "application/json"
                "Accept" = "application/json"
            }
            if ($if_match) { $headers["If-Match"] = $if_match }
            if ($ntnx_req_id) { $headers["NTNX-Request-Id"] = $ntnx_req_id }
            # Windows PowerShell 5 has no -Authentication parameter. Always send basic auth,
            # including when NTNX-Request-Id or If-Match is set, and free the password BSTR.
            $useBasicParameter = $PSVersionTable.PSVersion.Major -gt 5
            if (-not $useBasicParameter) {
                $headers["Authorization"] = Get-BasicAuthHeaderValue -Credential $credential
            }
        }

        process
        {
            if ($debugme) { Write-Host "$(Get-Date) [INFO] Making a $method call to $url" -ForegroundColor Green }
            try {
                if ($ReturnETag)
                {
                    if ($useBasicParameter)
                    {
                        $web = Invoke-WebRequest -Method $method -Uri $url -Headers $headers -SkipHeaderValidation -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
                    }
                    else
                    {
                        $web = Invoke-WebRequest -Method $method -Uri $url -Headers $headers -ErrorAction Stop
                    }
                    $resp = Get-HttpHeaderValue -Headers $web.Headers -Name "ETag"
                    if ([string]::IsNullOrEmpty($resp))
                    {
                        Throw "$(Get-Date) [ERROR] No ETag returned from $url"
                    }
                }
                elseif ($useBasicParameter)
                {
                    if ($payload)
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -SkipHeaderValidation -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
                    }
                    else
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -SkipHeaderValidation -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
                    }
                }
                else
                {
                    if ($payload)
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
                    }
                    else
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ErrorAction Stop
                    }
                }
                if ($debugme)
                {
                    Write-Host "$(get-date) [SUCCESS] Call $method to $url succeeded." -ForegroundColor Cyan
                    if (-not $ReturnETag -and $resp.metadata) { Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White }
                }
            }
            catch {
                $saved_error = $_.Exception
                $saved_error_message = ($_.ErrorDetails.Message | ConvertFrom-Json).message_list.message
                $resp_return_code = $_.Exception.Response.StatusCode.value__
                # Write-Host "$(Get-Date) [INFO] Headers: $($headers | ConvertTo-Json)"
                if ($resp_return_code -eq 409)
                {
                    Write-Host "$(Get-Date) [WARNING] $saved_error_message" -ForegroundColor Yellow
                    Throw
                }
                else
                {
                    if ($saved_error_message -match 'Policy already exists')
                    {
                        Throw "$(get-date) [WARNING] $saved_error_message"
                    }
                    else
                    {
                        if ($payload) {Write-Host "$(Get-Date) [INFO] Payload: $payload" -ForegroundColor Green}
                        Throw "$(get-date) [ERROR] $resp_return_code $saved_error_message"
                    }
                }
            }
            finally {
                #add any last words here; this gets processed no matter what
            }
        }

        end
        {
            return $resp
        }
    }

    #Applies a per-Prism-Central, per-method rate limit of 5 requests/sec, then calls Prism.
    #Source and target do not share a bucket. When the bucket is full, sleep only the rest of that second.
    function Invoke-RateLimitedApiCall
    {
        [CmdletBinding()]
        param
        (
            [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PUT", "DELETE", "PATCH")][string] $method,
            [Parameter(Mandatory = $true)][string] $url,
            [Parameter(Mandatory = $true)][PSCredential] $credential,
            [Parameter()][string] $payload,
            [Parameter()][string] $ntnx_req_id,
            [Parameter()][string] $if_match,
            [Parameter()][switch] $ReturnETag
        )

        $maxPerSecond = 5
        $pcHost = ([uri]$url).Host
        $rateKey = "{0}|{1}" -f $pcHost, $method

        if (-not $script:RateLimitMap)
        {
            $script:RateLimitMap = @{}
        }

        if (-not $script:RateLimitMap.ContainsKey($rateKey))
        {
            $script:RateLimitMap[$rateKey] = @{
                Counter   = 0
                StartTime = Get-Date
            }
        }

        $rateState = $script:RateLimitMap[$rateKey]
        $now = Get-Date
        $elapsed = ($now - $rateState.StartTime).TotalSeconds

        if ($elapsed -ge 1)
        {
            $rateState.Counter = 0
            $rateState.StartTime = $now
            $elapsed = 0
        }

        if ($rateState.Counter -ge $maxPerSecond)
        {
            $remainingMs = [int][Math]::Ceiling((1 - $elapsed) * 1000)
            if ($remainingMs -lt 1) { $remainingMs = 1 }
            Write-Host "$(Get-Date) [WARNING] [$pcHost $method] Reached $maxPerSecond req/sec. Sleeping $remainingMs ms..." -ForegroundColor Yellow
            Start-Sleep -Milliseconds $remainingMs
            $rateState.Counter = 0
            $rateState.StartTime = Get-Date
        }

        $rateState.Counter++
        $script:RateLimitMap[$rateKey] = $rateState

        return Invoke-PrismAPICall -method $method -url $url -credential $credential -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match -ReturnETag:$ReturnETag
    }


    #helper-function Get-RESTError
    function Help-RESTError
    {#tries to retrieve full REST messages
        $global:helpme = $body
        $global:helpmoref = $moref
        $global:result = $_.Exception.Response.GetResponseStream()
        $global:reader = New-Object System.IO.StreamReader($global:result)
        $global:responseBody = $global:reader.ReadToEnd();

        return $global:responsebody

        break
    }#end function Get-RESTError

    function Get-MicrosegObjectList
    {
        [CmdletBinding(DefaultParameterSetName = 'MicrosegObject')]
        param(
            [Parameter(Mandatory = $true)][string] $pc,
            [Parameter(Mandatory = $true, ParameterSetName = 'MicrosegObject')][string] $object,
            [Parameter(Mandatory = $true, ParameterSetName = 'ApiPath')][string] $apiPath
        )

        begin {
            $page = 0
            $limit = 100
            $totalAvailable = 0
            $results = New-Object System.Collections.Generic.List[object]
            $method = "GET"

            if ($PSCmdlet.ParameterSetName -eq 'ApiPath') {
                $baseUrl = "https://{0}:9440/{1}" -f $pc, $apiPath.TrimStart('/')
            }
            else {
                $baseUrl = "https://{0}:9440/api/microseg/v4.0/config/{1}" -f $pc, $object
            }
        }

        process {
            do {
                try {
                    # Add correct query separator if needed
                    $sep = if ($baseUrl -match '\?') { '&' } else { '?' }

                    # Use encoded parameters %24page and %24limit to substitute $
                    # which is needed in V4 API odata format for limit and page query
                    $url = "$baseUrl${sep}%24page=$page&%24limit=$limit"

                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Calling URL: $url" -ForegroundColor White }
                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    # A one-item page is a single object. @() makes it a one-element collection
                    # so it is not indexed as characters and can be added like a multi-item page.
                    $pageItems = New-Object System.Collections.Generic.List[object]
                    if ($resp -and $resp.data) {
                        foreach ($item in @($resp.data)) {
                            if ($null -ne $item) { $pageItems.Add($item) }
                        }
                    }

                    if ($pageItems.Count -eq 0) {
                        if ($page -eq 0) {
                            Write-Host "$(Get-Date) [WARNING] No data received from $baseUrl." -ForegroundColor Yellow
                        }
                        break
                    }

                    if ($resp.metadata -and $null -ne $resp.metadata.totalAvailableResults) {
                        $totalAvailable = [int]$resp.metadata.totalAvailableResults
                        if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Total available results: $totalAvailable" -ForegroundColor White }
                    }

                    foreach ($item in $pageItems) { $results.Add($item) }
                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Retrieved $($pageItems.Count) objects (Total so far: $($results.Count))" -ForegroundColor White }

                    $page++
                    if ($totalAvailable -gt 0) {
                        $continuePaging = $results.Count -lt $totalAvailable
                    }
                    else {
                        $continuePaging = $pageItems.Count -eq $limit
                    }
                }
                catch {
                    Throw "$(Get-Date) [ERROR] $($_.Exception.Message)"
                }
            }
            while ($continuePaging)
        }

        end {
            return $results
        }
    }

    function Get-PrismCentralTaskStatus
    {#loops on Prism Central task status until completed
        <#
        .SYNOPSIS
        Retrieves the status of a given task uuid from Prism and loops until it is completed.

        .DESCRIPTION
        Retrieves the status of a given task uuid from Prism and loops until it is completed.

        .PARAMETER Task
        Prism task uuid.

        .NOTES
        Author: Pramod Singh (sbourdeaud@nutanix.com)

        .EXAMPLE
        .\Get-PrismCentralTaskStatus -Task $task -cluster $cluster -credential $prismCredentials
        Prints progress on task $task until successfull completion. If the task fails, print the status and error code and details and exits.

        .LINK
        https://github.com/sbourdeaud
        #>
        [CmdletBinding(DefaultParameterSetName = 'None')] #make this function advanced

        param
        (
            [Parameter(Mandatory)]
            $task,

            [parameter(mandatory = $true)]
            [System.Management.Automation.PSCredential]
            $credential,

            [parameter(mandatory = $true)]
            [String]
            $cluster
        )

        begin
        {
            $url = "https://$($cluster):9440/api/prism/v4.0/config/tasks/$task"
            $method = "GET"
        }

        process
        {
            #region get initial task details
                Write-Host "$(Get-Date) [INFO] Retrieving details of task $task..." -ForegroundColor Green
                $taskDetails = Invoke-RateLimitedApiCall -method $method -url $url -credential $credential
                Write-Host "$(Get-Date) [SUCCESS] Retrieved details of task $task" -ForegroundColor Cyan
            #endregion

            if ($taskDetails.percentage_complete -ne "100")
            {
                Do
                {
                    New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                    Sleep 5
                    $taskDetails = Invoke-RateLimitedApiCall -method $method -url $url -credential $credential

                    if ($taskDetails.status -ne "running")
                    {
                        if ($taskDetails.status -ne "succeeded")
                        {
                            Write-Host "$(Get-Date) [WARNING] Task $($taskDetails.operation_type) failed with the following status and error code : $($taskDetails.status) : $($taskDetails.progress_message)" -ForegroundColor Yellow
                        }
                    }
                }
                While ($taskDetails.percentage_complete -ne "100")

                New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                Write-Host "$(Get-Date) [SUCCESS] Task $($taskDetails.operation_type) completed successfully!" -ForegroundColor Cyan
            }
            else
            {
                if ($taskDetails.status -ne "succeeded") {
                    Write-Host "$(Get-Date) [WARNING] Task $($taskDetails.operation_type) status is $($taskDetails.status): $($taskDetails.progress_message)" -ForegroundColor Yellow
                } else {
                    New-PercentageBar -Percent $taskDetails.percentage_complete -DrawBar -Length 100 -BarView AdvancedThin2; "`r"
                    Write-Host "$(Get-Date) [SUCCESS] Task $($taskDetails.operation_type) completed successfully!" -ForegroundColor Cyan
                }
            }
        }

        end
        {
            return $taskDetails.status
        }
    }

    function Get-CategoryByExtId
    {#retrieves Category object v4. Returns the category data (key, value, extId) and caches it for the run.
        [CmdletBinding()]
        param
        (
            [Parameter(mandatory = $true)][string] $pc,
            [Parameter(mandatory = $true)][string] $extId
        )

        begin
        {
            if (-not $script:SourceObjectCache) { $script:SourceObjectCache = @{} }
            $result = $null
            $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories/{1}" -f $pc,$extId
            $method = "GET"
        }

        process
        {
            if ($script:SourceObjectCache.ContainsKey($extId))
            {
                $result = $script:SourceObjectCache[$extId]
            }
            else
            {
                try {
                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}

                    if ($resp.data)
                    {
                        $script:SourceObjectCache[$extId] = $resp.data
                        $result = $resp.data
                    }
                }
                catch {
                    $saved_error = $_.Exception.Message
                    $error_code = ($saved_error -split " ")[3]
                    if ($error_code -eq "404")
                    {
                        Write-Host "$(get-date) [WARNING] The category extId specified ($extId) does not exist in Prism Central $pc" -ForegroundColor Yellow
                    }
                    else
                    {
                        Write-Host "$saved_error" -ForegroundColor Yellow
                    }
                }
                finally {
                    #add any last words here; this gets processed no matter what
                }
            }
        }

        end
        {
            return $result
        }
    }

    function Get-PolicyByExtId
    {#retrieves NSP object v4
        [CmdletBinding()]
        param
        (
            [Parameter(mandatory = $true)][string] $pc,
            [Parameter(mandatory = $true)][string] $extId
        )

        begin
        {
            $url = "https://{0}:9440/api/microseg/v4.0/config/policies/{1}" -f $pc,$extId
            $method = "GET"
        }

        process
        {
            try {
                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
            }
            catch {
                $saved_error = $_.Exception.Message
                $error_code = ($saved_error -split " ")[3]
                if ($error_code -eq "404")
                {
                    Write-Host "$(get-date) [WARNING] The policy extId specified ($extId) does not exist in Prism Central $pc" -ForegroundColor Yellow
                }
                else
                {
                    Write-Host "$saved_error" -ForegroundColor Yellow
                }
            }
            finally {
                #add any last words here; this gets processed no matter what
            }
        }

        end
        {
            return $resp
        }
    }

    function Get-VpcByExtId
    {#retrieves vpc object v4. Returns the VPC data (name, extId) and caches it for the run.
        [CmdletBinding()]
        param
        (
            [Parameter(mandatory = $true)][string] $pc,
            [Parameter(mandatory = $true)][string] $extId
        )

        begin
        {
            if (-not $script:SourceObjectCache) { $script:SourceObjectCache = @{} }
            $result = $null
            $url = "https://{0}:9440/api/networking/v4.0/config/vpcs/{1}" -f $pc,$extId
            $method = "GET"
        }

        process
        {
            if ($script:SourceObjectCache.ContainsKey($extId))
            {
                $result = $script:SourceObjectCache[$extId]
            }
            else
            {
                try {
                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}

                    if ($resp.data)
                    {
                        $script:SourceObjectCache[$extId] = $resp.data
                        $result = $resp.data
                    }
                }
                catch {
                    $saved_error = $_.Exception.Message
                    $error_code = ($saved_error -split " ")[3]
                    if ($error_code -eq "404")
                    {
                        Write-Host "$(get-date) [WARNING] The vpc extId specified ($extId) does not exist in Prism Central $pc" -ForegroundColor Yellow
                    }
                    else
                    {
                        Write-Host "$saved_error" -ForegroundColor Yellow
                    }
                }
                finally {
                    #add any last words here; this gets processed no matter what
                }
            }
        }

        end
        {
            return $result
        }
    }

    function New-NameIndex
    {
        param($Items)

        $index = @{}
        foreach ($item in @($Items))
        {
            if ($null -eq $item) { continue }
            $name = [string]$item.name
            if ([string]::IsNullOrEmpty($name)) { continue }
            if (-not $index.ContainsKey($name))
            {
                $index[$name] = $item
            }
        }
        return $index
    }

    function Add-CategoryToIndex
    {
        param($Index, $Key, $Value, $ExtId)

        $keyName = [string]$Key
        $valueName = [string]$Value
        if ([string]::IsNullOrEmpty($keyName)) { return }
        if (-not $Index.ContainsKey($keyName))
        {
            $Index[$keyName] = @{}
        }
        if (-not $Index[$keyName].ContainsKey($valueName))
        {
            $Index[$keyName][$valueName] = [string]$ExtId
        }
    }

    function New-CategoryIndex
    {
        param($Categories)

        $index = @{}
        foreach ($category in @($Categories))
        {
            if ($null -eq $category) { continue }
            Add-CategoryToIndex -Index $index -Key $category.key -Value $category.value -ExtId $category.extId
        }
        return $index
    }

    function Get-CachedSourceObject
    {
        param
        (
            [Parameter(Mandatory = $true)][string] $extId,
            [Parameter(Mandatory = $true)][string] $url
        )

        if (-not $script:SourceObjectCache) { $script:SourceObjectCache = @{} }
        if ($script:SourceObjectCache.ContainsKey($extId))
        {
            return $script:SourceObjectCache[$extId]
        }

        $resp = Invoke-RateLimitedApiCall -method GET -url $url -credential $prismCredentials
        if ($resp.data)
        {
            $script:SourceObjectCache[$extId] = $resp.data
        }
        return $resp.data
    }

    #Replaces source extIds using the run map. A single JSON string stays a string; an array stays an array.
    function Update-ReferenceProperty
    {
        param
        (
            $Object,
            [Parameter(Mandatory = $true)][string] $PropertyName,
            $Map
        )

        if ($null -eq $Object -or $null -eq $Map -or $Map.Count -eq 0) { return }
        if ($Object.PSObject.Properties.Name -notcontains $PropertyName) { return }

        $value = $Object.$PropertyName
        if ($null -eq $value) { return }

        $wasScalar = $value -is [string]
        $items = @($value)
        $changed = $false
        for ($i = 0; $i -lt $items.Count; $i++)
        {
            if ($null -eq $items[$i]) { continue }
            $key = [string]$items[$i]
            if ($Map.ContainsKey($key))
            {
                $items[$i] = $Map[$key]
                $changed = $true
            }
        }
        if (-not $changed) { return }
        if ($wasScalar)
        {
            $Object.$PropertyName = $items[0]
        }
        else
        {
            $Object.$PropertyName = $items
        }
    }

    function Update-PolicyRuleReferences
    {
        param
        (
            $Policy,
            [string[]] $PropertyNames,
            [switch] $IncludeIsolationGroups
        )

        if (-not $script:ExtIdMap -or $script:ExtIdMap.Count -eq 0) { return }
        if (-not $Policy.data.rules) { return }

        foreach ($rule in @($Policy.data.rules))
        {
            if (-not $rule.spec) { continue }
            foreach ($propertyName in $PropertyNames)
            {
                Update-ReferenceProperty -Object $rule.spec -PropertyName $propertyName -Map $script:ExtIdMap
            }
            if ($IncludeIsolationGroups -and $rule.spec.spec -and $rule.spec.spec.isolationGroups)
            {
                foreach ($group in @($rule.spec.spec.isolationGroups))
                {
                    Update-ReferenceProperty -Object $group -PropertyName "groupCategoryReferences" -Map $script:ExtIdMap
                }
            }
        }
    }

    function Get-CreatedExtId
    {
        param
        (
            $Response,
            [Parameter(Mandatory = $true)][string] $LookupUrl
        )

        $created = $null
        $objectType = ""
        if ($Response -and $Response.data)
        {
            $objectType = [string]$Response.data.'$objectType'
            $created = $Response.data.extId
            if ($created -is [System.Array]) { $created = $created[0] }
        }

        # A task reference is not the new entity. Look the entity up by the escaped name filter.
        if ($created -and $objectType -notmatch 'Task')
        {
            return [string]$created
        }

        $lookup = Invoke-RateLimitedApiCall -method GET -url $LookupUrl -credential $prismCredentials
        $match = @($lookup.data) | Where-Object { $_ -and $_.extId } | Select-Object -First 1
        if ($match.extId)
        {
            return [string]$match.extId
        }
        Throw "$(Get-Date) [ERROR] Create succeeded but no extId was returned from $LookupUrl"
    }

    function Sync-Categories
    {#syncs Prism categories used in a given network policy
        param
        (
            [Parameter(Mandatory)] $policy,
            [Parameter(Mandatory)] $TargetCategoryIndex
        )

        begin {}

        process
        {
            if (-not $script:ExtIdMap) { $script:ExtIdMap = @{} }

            Write-Host "$(get-date) [INFO] Examining categories..." -ForegroundColor Green
            $sourceIds = @{}
            $usedPairs = New-Object System.Collections.Generic.List[string]

            if ($policy.data.type -eq "ISOLATION")
            {
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Isolation policy..." -ForegroundColor Green
                foreach ($rule in @($policy.data.rules))
                {
                    if (-not $rule.spec) { continue }
                    foreach ($categoryExtId in @($rule.spec.firstIsolationGroup)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                    foreach ($categoryExtId in @($rule.spec.secondIsolationGroup)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                    if ($rule.spec.spec -and $rule.spec.spec.isolationGroups)
                    {
                        foreach ($group in @($rule.spec.spec.isolationGroups))
                        {
                            foreach ($categoryExtId in @($group.groupCategoryReferences)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                        }
                    }
                }
            }
            elseif ($policy.data.type -eq "APPLICATION")
            {
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Application policy..." -ForegroundColor Green
                foreach ($rule in @($policy.data.rules))
                {
                    if (-not $rule.spec) { continue }
                    foreach ($categoryExtId in @($rule.spec.securedGroupCategoryReferences)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                    foreach ($categoryExtId in @($rule.spec.srcCategoryReferences)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                    foreach ($categoryExtId in @($rule.spec.destCategoryReferences)) { if ($categoryExtId) { $sourceIds[[string]$categoryExtId] = $true } }
                }
            }
            else
            {
                Write-Host "$(get-date) [WARNING] Policy $($policy.data.name) is not a supported policy type for replication!" -ForegroundColor Yellow
                return
            }

            $missing = New-Object System.Collections.Generic.List[object]
            foreach ($sourceExtId in @($sourceIds.Keys))
            {
                $sourceCategory = Get-CategoryByExtId -pc $sourcePc -extId $sourceExtId
                if (-not $sourceCategory) { continue }
                $usedPairs.Add("$($sourceCategory.key):$($sourceCategory.value)")

                if ($script:ExtIdMap.ContainsKey($sourceExtId))
                {
                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Reusing mapped category $($sourceCategory.key):$($sourceCategory.value)" -ForegroundColor White }
                    continue
                }

                $targetExtId = $null
                if ($TargetCategoryIndex.ContainsKey([string]$sourceCategory.key) -and $TargetCategoryIndex[[string]$sourceCategory.key].ContainsKey([string]$sourceCategory.value))
                {
                    $targetExtId = $TargetCategoryIndex[[string]$sourceCategory.key][[string]$sourceCategory.value]
                }

                if ($targetExtId)
                {
                    Write-Host "$(Get-Date) [SUCCESS] Found the category:value pair $($sourceCategory.key):$($sourceCategory.value) in $targetPc" -ForegroundColor Cyan
                    $script:ExtIdMap[$sourceExtId] = [string]$targetExtId
                }
                else
                {
                    Write-Host "$(get-date) [WARNING] The category:value pair specified ($($sourceCategory.key):$($sourceCategory.value)) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                    $missing.Add($sourceCategory)
                }
            }

            Write-Host "$(get-date) [DATA] Flow policy $($policy.data.name) uses the following category:value pairs:" -ForegroundColor White
            $usedPairs | Select-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor White }

            if ($missing.Count -gt 0)
            {
                Write-Host "$(get-date) [DATA] The following category:value pairs need to be added on $($targetPc):" -ForegroundColor White
                foreach ($sourceCategory in $missing) { Write-Host "$($sourceCategory.key):$($sourceCategory.value)" -ForegroundColor White }
            }

            foreach ($sourceCategory in $missing)
            {
                $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories" -f $targetPc
                $content = @{
                    key = $sourceCategory.key
                    description = "added by Invoke-FlowRuleSyncNG.ps1 script"
                    value = [string]$sourceCategory.value
                }
                $payload = (ConvertTo-Json $content -Depth 4)
                try
                {
                    $resp = Invoke-RateLimitedApiCall -method POST -url $url -credential $prismCredentials -payload $payload
                    Write-Host "$(Get-Date) [SUCCESS] Added category $($sourceCategory.key):$($sourceCategory.value) in $targetPc" -ForegroundColor Cyan
                    if ($debugme) { $resp }
                    $filter = ConvertTo-ODataFilterQuery -Expression ("key eq {0} and value eq {1}" -f (ConvertTo-ODataStringLiteral ([string]$sourceCategory.key)), (ConvertTo-ODataStringLiteral ([string]$sourceCategory.value)))
                    $lookupUrl = "https://{0}:9440/api/prism/v4.0.a2/config/categories?{1}" -f $targetPc, $filter
                    $targetExtId = Get-CreatedExtId -Response $resp -LookupUrl $lookupUrl
                    $script:ExtIdMap[[string]$sourceCategory.extId] = $targetExtId
                    Add-CategoryToIndex -Index $TargetCategoryIndex -Key $sourceCategory.key -Value $sourceCategory.value -ExtId $targetExtId
                }
                catch
                {
                    Throw "$($_.Exception.Message)"
                }
            }

            if ($policy.data.type -eq "APPLICATION")
            {
                Update-PolicyRuleReferences -Policy $policy -PropertyNames @('securedGroupCategoryReferences','srcCategoryReferences','destCategoryReferences')
            }
            elseif ($policy.data.type -eq "ISOLATION")
            {
                Update-PolicyRuleReferences -Policy $policy -PropertyNames @('firstIsolationGroup','secondIsolationGroup') -IncludeIsolationGroups
            }
        }

        end {}
    }

    function Sync-AddressGroups
    {#syncs Prism address groups used in a given network policy
        param
        (
            [Parameter(Mandatory)] $policy,
            [Parameter(Mandatory)] $TargetByName
        )

        begin {}

        process
        {
            if (-not $script:ExtIdMap) { $script:ExtIdMap = @{} }
            Write-Host "$(get-date) [INFO] Examining address groups..." -ForegroundColor Green
            if ($policy.data.type -ne "APPLICATION") { return }

            $sourceIds = @{}
            foreach ($rule in @($policy.data.rules))
            {
                if (-not $rule.spec) { continue }
                foreach ($addressGroupExtId in @($rule.spec.srcAddressGroupReferences)) { if ($addressGroupExtId) { $sourceIds[[string]$addressGroupExtId] = $true } }
                foreach ($addressGroupExtId in @($rule.spec.destAddressGroupReferences)) { if ($addressGroupExtId) { $sourceIds[[string]$addressGroupExtId] = $true } }
            }

            $missing = New-Object System.Collections.Generic.List[object]
            foreach ($sourceExtId in @($sourceIds.Keys))
            {
                if ($script:ExtIdMap.ContainsKey($sourceExtId))
                {
                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Reusing mapped address group $sourceExtId" -ForegroundColor White }
                    continue
                }

                $url = "https://{0}:9440/api/microseg/v4.0/config/address-groups/{1}" -f $sourcePc, $sourceExtId
                $sourceAg = Get-CachedSourceObject -extId $sourceExtId -url $url
                if (-not $sourceAg) { continue }

                if ($TargetByName.ContainsKey([string]$sourceAg.name))
                {
                    $target = $TargetByName[[string]$sourceAg.name]
                    $script:ExtIdMap[$sourceExtId] = [string]$target.extId
                    if ($rename)
                    {
                        $newName = $rename + "_" + $sourceAg.name
                        $etagUrl = "https://{0}:9440/api/microseg/v4.0/config/address-groups/{1}" -f $targetPc, $target.extId
                        $if_match = Invoke-RateLimitedApiCall -method GET -url $etagUrl -credential $prismCredentials -ReturnETag
                        $content = @{
                            description = "added by Invoke-FlowRuleSyncNG.ps1 script"
                            name = $newName
                        }
                        if ($sourceAg.ipv4Addresses) { $content.Add("ipv4Addresses", $sourceAg.ipv4Addresses) }
                        if ($sourceAg.ipRanges) { $content.Add("ipRanges", $sourceAg.ipRanges) }
                        $payload = (ConvertTo-Json $content -Depth 10)
                        $ntnx_req_id = New-Guid
                        Write-Host "$(Get-Date) [INFO] Updating address group $($sourceAg.name) to $targetPc with name $newName" -ForegroundColor Green
                        try
                        {
                            $resp = Invoke-RateLimitedApiCall -method PUT -url $etagUrl -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
                            Write-Host "$(Get-Date) [SUCCESS] Updated address group $($sourceAg.name) to $targetPc with name $newName" -ForegroundColor Cyan
                            if ($debugme) { $resp }
                            $TargetByName.Remove([string]$sourceAg.name)
                            $TargetByName[$newName] = $target
                        }
                        catch
                        {
                            Throw "$($_.Exception.Message)"
                        }
                    }
                }
                else
                {
                    $missing.Add($sourceAg)
                }
            }

            if ($missing.Count -gt 0)
            {
                Write-Host "$(get-date) [DATA] The following address groups need to be added on $($targetPc):" -ForegroundColor White
                foreach ($sourceAg in $missing) { Write-Host $sourceAg.name -ForegroundColor White }
            }

            foreach ($sourceAg in $missing)
            {
                $api_server_endpoint = "/api/microseg/v4.0/config/address-groups"
                $url = "https://{0}:9440{1}" -f $targetPc, $api_server_endpoint
                $agname = $sourceAg.name
                if ($rename)
                {
                    $agname = $rename + "_" + $sourceAg.name
                    Write-Host "$(Get-Date) [INFO] Adding address group $($sourceAg.name) to $targetPc with name $($agname)" -ForegroundColor Green
                }
                $content = @{
                    description = "added by Invoke-FlowRuleSyncNG.ps1 script"
                    name = $agname
                }
                if ($sourceAg.ipv4Addresses) { $content.Add("ipv4Addresses", $sourceAg.ipv4Addresses) }
                if ($sourceAg.ipRanges) { $content.Add("ipRanges", $sourceAg.ipRanges) }
                $payload = (ConvertTo-Json $content -Depth 10)
                $ntnx_req_id = New-Guid
                Write-Host "$(Get-Date) [INFO] Adding address group $($sourceAg.name) to $targetPc" -ForegroundColor Green
                try
                {
                    $resp = Invoke-RateLimitedApiCall -method POST -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id
                    Write-Host "$(Get-Date) [SUCCESS] Added address group $($sourceAg.name) to $targetPc" -ForegroundColor Cyan
                    if ($debugme) { $resp }
                    $filter = ConvertTo-ODataFilterQuery -Expression ("name eq {0}" -f (ConvertTo-ODataStringLiteral ([string]$agname)))
                    $lookupUrl = "https://{0}:9440{1}?{2}" -f $targetPc, $api_server_endpoint, $filter
                    $targetExtId = Get-CreatedExtId -Response $resp -LookupUrl $lookupUrl
                    $script:ExtIdMap[[string]$sourceAg.extId] = $targetExtId
                    if (-not $TargetByName.ContainsKey([string]$agname))
                    {
                        $TargetByName[[string]$agname] = [pscustomobject]@{ name = [string]$agname; extId = $targetExtId }
                    }
                }
                catch
                {
                    Throw "$($_.Exception.Message)"
                }
            }

            Update-PolicyRuleReferences -Policy $policy -PropertyNames @('srcAddressGroupReferences','destAddressGroupReferences')
        }

        end {}
    }

    function Sync-ServiceGroups
    {#syncs Prism service groups used in a given network policy
        param
        (
            [Parameter(Mandatory)] $policy,
            [Parameter(Mandatory)] $TargetByName
        )

        begin {}

        process
        {
            if (-not $script:ExtIdMap) { $script:ExtIdMap = @{} }
            Write-Host "$(get-date) [INFO] Examining service groups..." -ForegroundColor Green
            if ($policy.data.type -ne "APPLICATION") { return }

            $sourceIds = @{}
            foreach ($rule in @($policy.data.rules))
            {
                if (-not $rule.spec) { continue }
                foreach ($serviceGroupExtId in @($rule.spec.serviceGroupReferences)) { if ($serviceGroupExtId) { $sourceIds[[string]$serviceGroupExtId] = $true } }
            }

            $missing = New-Object System.Collections.Generic.List[object]
            foreach ($sourceExtId in @($sourceIds.Keys))
            {
                if ($script:ExtIdMap.ContainsKey($sourceExtId))
                {
                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Reusing mapped service group $sourceExtId" -ForegroundColor White }
                    continue
                }

                $url = "https://{0}:9440/api/microseg/v4.0/config/service-groups/{1}" -f $sourcePc, $sourceExtId
                $sourceSg = Get-CachedSourceObject -extId $sourceExtId -url $url
                if (-not $sourceSg) { continue }

                if ($sourceSg.isSystemDefined)
                {
                    if ($TargetByName.ContainsKey([string]$sourceSg.name))
                    {
                        $script:ExtIdMap[$sourceExtId] = [string]$TargetByName[[string]$sourceSg.name].extId
                    }
                    else
                    {
                        Write-Host "$(get-date) [WARNING] System defined service group $($sourceSg.name) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                    }
                    continue
                }

                if ($TargetByName.ContainsKey([string]$sourceSg.name))
                {
                    $target = $TargetByName[[string]$sourceSg.name]
                    $script:ExtIdMap[$sourceExtId] = [string]$target.extId
                    if ($rename)
                    {
                        $newName = $rename + "_" + $sourceSg.name
                        $etagUrl = "https://{0}:9440/api/microseg/v4.0/config/service-groups/{1}" -f $targetPc, $target.extId
                        $if_match = Invoke-RateLimitedApiCall -method GET -url $etagUrl -credential $prismCredentials -ReturnETag
                        $content = @{
                            description = "added by Invoke-FlowRuleSyncNG.ps1 script"
                            name = $newName
                        }
                        if ($sourceSg.tcpServices) { $content.Add("tcpServices", $sourceSg.tcpServices) }
                        if ($sourceSg.udpServices) { $content.Add("udpServices", $sourceSg.udpServices) }
                        if ($sourceSg.icmpServices) { $content.Add("icmpServices", $sourceSg.icmpServices) }
                        $payload = (ConvertTo-Json $content -Depth 10)
                        $ntnx_req_id = New-Guid
                        Write-Host "$(Get-Date) [INFO] Updating service group $($sourceSg.name) to $targetPc with name $newName" -ForegroundColor Green
                        try
                        {
                            $resp = Invoke-RateLimitedApiCall -method PUT -url $etagUrl -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
                            Write-Host "$(Get-Date) [SUCCESS] Updated service group $($sourceSg.name) to $targetPc with name $newName" -ForegroundColor Cyan
                            if ($debugme) { $resp }
                            $TargetByName.Remove([string]$sourceSg.name)
                            $TargetByName[$newName] = $target
                        }
                        catch
                        {
                            Throw "$($_.Exception.Message)"
                        }
                    }
                }
                else
                {
                    $missing.Add($sourceSg)
                }
            }

            if ($missing.Count -gt 0)
            {
                Write-Host "$(get-date) [DATA] The following service groups need to be added on $($targetPc):" -ForegroundColor White
                foreach ($sourceSg in $missing) { Write-Host $sourceSg.name -ForegroundColor White }
            }

            foreach ($sourceSg in $missing)
            {
                $api_server_endpoint = "/api/microseg/v4.0/config/service-groups"
                $url = "https://{0}:9440{1}" -f $targetPc, $api_server_endpoint
                $sgname = $sourceSg.name
                if ($rename)
                {
                    $sgname = $rename + "_" + $sourceSg.name
                    Write-Host "$(Get-Date) [INFO] Adding service group $($sourceSg.name) to $targetPc with name $($sgname)" -ForegroundColor Green
                }
                $content = @{
                    description = "added by Invoke-FlowRuleSyncNG.ps1 script"
                    name = $sgname
                }
                if ($sourceSg.tcpServices) { $content.Add("tcpServices", $sourceSg.tcpServices) }
                if ($sourceSg.udpServices) { $content.Add("udpServices", $sourceSg.udpServices) }
                if ($sourceSg.icmpServices) { $content.Add("icmpServices", $sourceSg.icmpServices) }
                $payload = (ConvertTo-Json $content -Depth 10)
                $ntnx_req_id = New-Guid
                Write-Host "$(Get-Date) [INFO] Adding service group $($sourceSg.name) to $targetPc" -ForegroundColor Green
                try
                {
                    $resp = Invoke-RateLimitedApiCall -method POST -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id
                    Write-Host "$(Get-Date) [SUCCESS] Added service group $($sourceSg.name) to $targetPc" -ForegroundColor Cyan
                    if ($debugme) { $resp }
                    $filter = ConvertTo-ODataFilterQuery -Expression ("name eq {0}" -f (ConvertTo-ODataStringLiteral ([string]$sgname)))
                    $lookupUrl = "https://{0}:9440{1}?{2}" -f $targetPc, $api_server_endpoint, $filter
                    $targetExtId = Get-CreatedExtId -Response $resp -LookupUrl $lookupUrl
                    $script:ExtIdMap[[string]$sourceSg.extId] = $targetExtId
                    if (-not $TargetByName.ContainsKey([string]$sgname))
                    {
                        $TargetByName[[string]$sgname] = [pscustomobject]@{ name = [string]$sgname; extId = $targetExtId }
                    }
                }
                catch
                {
                    Throw "$($_.Exception.Message)"
                }
            }

            Update-PolicyRuleReferences -Policy $policy -PropertyNames @('serviceGroupReferences')
        }

        end {}
    }

    function Sync-Vpc
    {#syncs Prism VPC used in a given network policy
        param
        (
            [Parameter(Mandatory)] $policy,
            [Parameter(Mandatory)] $TargetVpcByName
        )

        begin {}

        process
        {
            if (-not $script:ExtIdMap) { $script:ExtIdMap = @{} }
            Write-Host "$(get-date) [INFO] Examining vpc..." -ForegroundColor Green

            $sourceIds = @{}
            if ($policy.data.type -eq "ISOLATION" -or $policy.data.type -eq "APPLICATION")
            {
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Isolation or Application policy..." -ForegroundColor Green
                foreach ($vpcExtId in @($policy.data.vpcReferences))
                {
                    if ($vpcExtId)
                    {
                        $sourceIds[[string]$vpcExtId] = $true
                        if ($debugme) { Write-Host "$(get-date) [INFO] Policy vpcextId $($vpcExtId) " -ForegroundColor Green }
                    }
                }
            }
            else
            {
                Write-Host "$(get-date) [WARNING] Policy $($policy.data.name) is not a supported policy type for replication!" -ForegroundColor Yellow
                return
            }

            $usedNames = New-Object System.Collections.Generic.List[string]
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($sourceExtId in @($sourceIds.Keys))
            {
                $sourceVpc = Get-VpcByExtId -pc $sourcePc -extId $sourceExtId
                if (-not $sourceVpc) { continue }
                $usedNames.Add([string]$sourceVpc.name)

                if ($script:ExtIdMap.ContainsKey($sourceExtId))
                {
                    if ($debugme) { Write-Host "$(Get-Date) [DEBUG] Reusing mapped VPC $($sourceVpc.name)" -ForegroundColor White }
                    continue
                }

                Write-Host "$(Get-Date) [INFO] Checking VPC $($sourceVpc.name) exists in $targetPc..." -ForegroundColor Green
                if ($TargetVpcByName.ContainsKey([string]$sourceVpc.name))
                {
                    Write-Host "$(Get-Date) [SUCCESS] Found the VPC $($sourceVpc.name) in $targetPc" -ForegroundColor Cyan
                    $script:ExtIdMap[$sourceExtId] = [string]$TargetVpcByName[[string]$sourceVpc.name].extId
                }
                else
                {
                    Write-Host "$(get-date) [WARNING] The VPC ($($sourceVpc.name)) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                    $missing.Add([string]$sourceVpc.name)
                }
            }

            Write-Host "$(get-date) [DATA] Flow policy $($policy.data.name) uses the following VPC :" -ForegroundColor White
            $usedNames | Select-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor White }

            if ($missing.Count -gt 0)
            {
                Write-Host "$(get-date) [DATA] The following VPCs need to be added on $($targetPc):" -ForegroundColor White
                $missing | Select-Object -Unique | ForEach-Object { Write-Host $_ -ForegroundColor White }
            }

            #TODO region create missing vpc on target
            Update-ReferenceProperty -Object $policy.data -PropertyName "vpcReferences" -Map $script:ExtIdMap
        }

        end {}
    }

#endregion


#region prepwork
    $HistoryText = @'
Maintenance Log
Date       By              Updates (newest updates at the top)
---------- -------------   ----------------------------------------------------
10/12/2024 pramod.singh   Initial release (based of PoSH script written by 
                          @nx-sbourdeaud).
07/28/2025 nx-sbourdeaud  Making script compatible with new "Global" scope.
10/21/2026 nx-sbourdeaud  Cache target catalogs and extId maps to avoid repeated Prism lookups.

################################################################################
'@
    $myvarScriptName = ".\Invoke-FlowRuleSyncNG.ps1"

    if ($log)
    {#we want to create a log transcript
        $myvar_output_log_file = (Get-Date -UFormat "%Y_%m_%d_%H_%M_") + "Invoke-FlowRuleSyncNG.log"
        Start-Transcript -Path ./$myvar_output_log_file
    }

    if ($help) {get-help $myvarScriptName; exit}
    if ($History) {$HistoryText; exit}

    #check PoSH version
    if ($PSVersionTable.PSVersion.Major -lt 5) {throw "$(get-date) [ERROR] Please upgrade to Powershell v5 or above (https://www.microsoft.com/en-us/download/details.aspx?id=50395)"}

#endregion


#region variables
    $myvarElapsedTime = [System.Diagnostics.Stopwatch]::StartNew() #used to store script begin timestamp
#endregion


#region parameters validation
    if (!$prismCreds)
    {#we are not using custom credentials, so let's ask for a username and password if they have not already been specified
        $prismCredentials = Get-Credential -Message "Please enter Prism credentials"
    }
    else
    {#we are using custom credentials, so let's grab the username and password from that
        try
        {#retrieve credentials
            $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        }
        catch
        {#could not retrieve credentials
            Set-CustomCredentials -credname $prismCreds
            $prismCredentials = Get-CustomCredentials -credname $prismCreds -ErrorAction Stop
        }
    }
    $username = $prismCredentials.UserName
    $PrismSecurePassword = $prismCredentials.Password
    $prismCredentials = New-Object PSCredential $username, $PrismSecurePassword
#endregion

#region main

    #region GET Flow policies
        Write-Host ""
        Write-Host "$(get-date) [STEP] Getting Flow policies" -ForegroundColor Magenta
        #region process source
            Write-Host "$(get-date) [INFO] Retrieving list of Flow policies from the source Prism Central instance $($sourcePc)..." -ForegroundColor Green
            $source_nsp_response = Get-MicrosegObjectList -pc $sourcePc -object "policies"
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of Flow policies from the source Prism Central instance $($sourcePc)" -ForegroundColor Cyan
            $filtered_source_nsp_response = $source_nsp_response | Where-Object {$_.name -match "^$prefix"}
            Write-Host "$(get-date) [DATA] There are $($filtered_source_nsp_response.count) Flow policies which match prefix $($prefix) on source Prism Central $($sourcePc)..." -ForegroundColor White
        #endregion

        #region process target
            Write-Host "$(get-date) [INFO] Retrieving list of Flow policies from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
            $target_nsp_response = Get-MicrosegObjectList -pc $targetPc -object "policies"
            Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of Flow policies from the target Prism Central instance $($targetPc)" -ForegroundColor Cyan
            $filtered_target_nsp_response = $target_nsp_response | Where-Object {$_.name -match "^$prefix"}
            Write-Host "$(get-date) [DATA] There are $($filtered_target_nsp_response.count) Flow policies which match prefix $($prefix) on target Prism Central $($targetPc)..." -ForegroundColor White
        #endregion

        if (!$filtered_source_nsp_response -and !$filtered_target_nsp_response)
        {#we didn't find any matching policies
            Throw "$(get-date) [ERROR] There are no Flow policies on $($sourcePc) or $($targetPc) which match prefix $($prefix)!"
        }
    #endregion

    #region COMPARE Flow policies
        Write-Host ""
        Write-Host "$(get-date) [STEP] Comparing Flow policies" -ForegroundColor Magenta

        #* Policies to add ($add_nsp_list)
        #* Policies to update ($update_nsp_list)
        $targetPolicyByName = @{}
        foreach ($nsp in @($filtered_target_nsp_response))
        {
            if ($null -eq $nsp -or [string]::IsNullOrEmpty([string]$nsp.name)) { continue }
            if (-not $targetPolicyByName.ContainsKey([string]$nsp.name))
            {
                $targetPolicyByName[[string]$nsp.name] = $nsp
            }
        }
        $sourcePolicyNames = @{}
        foreach ($nsp in @($filtered_source_nsp_response))
        {
            if ($null -eq $nsp -or [string]::IsNullOrEmpty([string]$nsp.name)) { continue }
            $sourcePolicyNames[[string]$nsp.name] = $true
        }

        [System.Collections.ArrayList]$add_nsp_list = New-Object System.Collections.ArrayList($null)
        [System.Collections.ArrayList]$update_nsp_list = New-Object System.Collections.ArrayList($null)
        $seenSourcePolicies = @{}
        foreach ($nsp in @($filtered_source_nsp_response))
        {#compare source with target
            if ($null -eq $nsp -or $seenSourcePolicies.ContainsKey([string]$nsp.name)) { continue }
            $seenSourcePolicies[[string]$nsp.name] = $true
            if ($targetPolicyByName.ContainsKey([string]$nsp.name))
            {#policy exists on source and on target -- UPDATE scenario
                Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) exists on target Prism Central $($targetPc)" -ForegroundColor Green
                [void]$update_nsp_list.Add($nsp)
            }
            else
            {#policy exists on source but not on target -- CREATE scenario
                Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) does not exist yet on target Prism Central $($targetPc)" -ForegroundColor Green
                [void]$add_nsp_list.Add($nsp)
            }
        }
        Write-Host "$(get-date) [DATA] There are $($add_nsp_list.count) Flow policies to be created on target Prism Central $($targetPc)" -ForegroundColor White

        Write-Host "$(get-date) [DATA] There are $($update_nsp_list.count) Flow policies to update on target Prism Central $($targetPc)" -ForegroundColor White

        #* Policies to remove ($remove_nsp_list)
        [System.Collections.ArrayList]$remove_nsp_list = New-Object System.Collections.ArrayList($null)
        $seenTargetPolicies = @{}
        foreach ($nsp in @($filtered_target_nsp_response))
        {#compare target with source
            if ($null -eq $nsp -or $seenTargetPolicies.ContainsKey([string]$nsp.name)) { continue }
            $seenTargetPolicies[[string]$nsp.name] = $true
            if (-not $sourcePolicyNames.ContainsKey([string]$nsp.name))
            {#Policy exists on target but not on source
                Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) no longer exists on source Prism Central $($sourcePc)" -ForegroundColor Green
                [void]$remove_nsp_list.Add($nsp)
            }
        }
        Write-Host "$(get-date) [DATA] There are $($remove_nsp_list.count) Flow policies to remove on target Prism Central $($targetPc)" -ForegroundColor White

    #endregion

    #region ACTION

        if ($action -eq "delete")
        {#delete all address groups, service groups and policies with rename prefix in target, this action must be used with the rename prefix
            if($rename)
            {
                #region delete policies
                    #reuse the target policy list already retrieved above
                    $filtered_target_nsp_response = @($target_nsp_response) | Where-Object { $_ -and $_.name -match "^$rename" }
                    foreach ($nsp in $filtered_target_nsp_response)
                    {
                        #delete policy on target
                        $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                        $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$nsp.extId
                        $method = "DELETE"
                        $ntnx_req_id = New-Guid

                        Write-Host "$(get-date) [STEP] Deleting renamed policy $($nsp.name) on $($targetPc)" -ForegroundColor Green
                        try
                        {#delete the policy
                            $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -ntnx_req_id $ntnx_req_id
                            Write-Host "$(Get-Date) [SUCCESS] Deleted renamed policy $($nsp.name) from $targetPc" -ForegroundColor Cyan

                        }
                        catch
                        {#we couldn't delete the policy
                            Throw "$($_.Exception.Message)"
                        }
                    }
                #endregion

                #region delete address groups
                    #get all address groups
                    $target_address_groups = Get-MicrosegObjectList -pc $targetPc -object "address-groups"
                    $filtered_target_address_groups = $target_address_groups | Where-Object {$_.name -match "^$rename"}
                    foreach ($ag in $filtered_target_address_groups)
                    {
                        #delete ag on target
                        $api_server_endpoint = "/api/microseg/v4.0/config/address-groups"
                        $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$ag.extId
                        $method = "DELETE"
                        $ntnx_req_id = New-Guid

                        Write-Host "$(get-date) [STEP] Deleting renamed address group $($ag.name) on $($targetPc)" -ForegroundColor Green
                        try
                        {#delete the ag
                            $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -ntnx_req_id $ntnx_req_id
                            Write-Host "$(Get-Date) [SUCCESS] Deleted renamed address group $($ag.name) to $targetPc" -ForegroundColor Cyan

                        }
                        catch
                        {#we couldn't delete the ag
                            Throw "$($_.Exception.Message)"
                        }
                    }
                #endregion

                #region delete service groups
                    #get all service groups
                    $serviceGroupFilter = ConvertTo-ODataFilterQuery -Expression "isSystemDefined eq false"
                    $target_service_groups = Get-MicrosegObjectList -pc $targetPc -object ("service-groups?" + $serviceGroupFilter)
                    $filtered_target_service_groups = $target_service_groups | Where-Object {$_.name -match "^$rename"}
                    foreach ($sg in $filtered_target_service_groups)
                    {
                        #delete sg on target
                        $api_server_endpoint = "/api/microseg/v4.0/config/service-groups"
                        $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$sg.extId
                        $method = "DELETE"
                        $ntnx_req_id = New-Guid

                        Write-Host "$(get-date) [STEP] Deleting renamed service group $($sg.name) on $($targetPc)" -ForegroundColor Green
                        try
                        {#delete the sg
                            $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -ntnx_req_id $ntnx_req_id
                            Write-Host "$(Get-Date) [SUCCESS] Deleted renamed service group $($sg.name) to $targetPc" -ForegroundColor Cyan

                        }
                        catch
                        {#we couldn't delete the sg
                            Throw "$($_.Exception.Message)"
                        }
                    }
                #endregion

            }
            else
            {
                Write-Host "$(get-date) [ERROR] Selected delete action without rename" -ForegroundColor Red
            }
        }

        if ($action -eq "sync")
        {#synchronize (ADD, DELETE, UPDATE)
            $script:ExtIdMap = @{}
            $script:SourceObjectCache = @{}
            $targetAgByName = @{}
            $targetSgByName = @{}
            $targetCategoryIndex = @{}
            $targetVpcByName = @{}

            if ($add_nsp_list.Count -gt 0 -or $update_nsp_list.Count -gt 0)
            {
                Write-Host ""
                Write-Host "$(get-date) [STEP] Getting target Flow catalogs" -ForegroundColor Magenta

                Write-Host "$(get-date) [INFO] Retrieving address groups from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                $targetAgByName = New-NameIndex (Get-MicrosegObjectList -pc $targetPc -object "address-groups")
                Write-Host "$(get-date) [DATA] There are $($targetAgByName.Count) address groups on target Prism Central $($targetPc)" -ForegroundColor White

                Write-Host "$(get-date) [INFO] Retrieving service groups from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                $targetSgByName = New-NameIndex (Get-MicrosegObjectList -pc $targetPc -object "service-groups")
                Write-Host "$(get-date) [DATA] There are $($targetSgByName.Count) service groups on target Prism Central $($targetPc)" -ForegroundColor White

                Write-Host "$(get-date) [INFO] Retrieving categories from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                $targetCategoryIndex = New-CategoryIndex (Get-MicrosegObjectList -pc $targetPc -apiPath "api/prism/v4.0.a2/config/categories")
                $categoryCount = 0
                foreach ($categoryKey in @($targetCategoryIndex.Keys)) { $categoryCount += $targetCategoryIndex[$categoryKey].Count }
                Write-Host "$(get-date) [DATA] There are $categoryCount categories on target Prism Central $($targetPc)" -ForegroundColor White

                Write-Host "$(get-date) [INFO] Retrieving VPCs from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                $targetVpcByName = New-NameIndex (Get-MicrosegObjectList -pc $targetPc -apiPath "api/networking/v4.0/config/vpcs")
                Write-Host "$(get-date) [DATA] There are $($targetVpcByName.Count) VPCs on target Prism Central $($targetPc)" -ForegroundColor White
            }

            #region process ADD
                if ($add_nsp_list.Count -gt 0)
                {#there are policies to be added
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Adding Flow policies" -ForegroundColor Magenta
                    foreach ($nsp in $add_nsp_list)
                    {#process each nsp to add

                        #get the complete nsp from source
                        $policy = Get-PolicyByExtId -pc $sourcePc -extId $nsp.extId

                        if ($policy.data.scope -eq "ALL_VLAN")
                        {
                            Write-Host "$(Get-Date) [WARNING] Not Syncing policy $($policy.data.name) as it is a VLAN policy" -ForegroundColor Cyan
                            continue
                        } 
                        elseif ($policy.data.scope -ne "GLOBAL") 
                        {
                            Sync-Vpc -policy $policy -TargetVpcByName $targetVpcByName
                        }
                        Sync-Categories -policy $policy -TargetCategoryIndex $targetCategoryIndex
                        Sync-ServiceGroups -policy $policy -TargetByName $targetSgByName
                        Sync-AddressGroups -policy $policy -TargetByName $targetAgByName


                        #region add nsp on target
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $url = "https://{0}:9440{1}" -f $targetPc,$api_server_endpoint
                            $method = "POST"
                            $policyname = $policy.data.name
                            if($rename)
                            {
                                $policyname = $rename + "_" + $policy.data.name
                                Write-Host "$(Get-Date) [INFO] Adding Flow policy $($nsp.name) to $targetPc with new name $policyname" -ForegroundColor Cyan
                            }
                            if ($policy.data.scope -ne "GLOBAL") {
                                $content = @{
                                    name= $policyname;
                                    type= $policy.data.type;
                                    description= "added by Invoke-FlowRuleSyncNG.ps1 script";
                                    state= $policy.data.state;
                                    rules= $policy.data.rules;
                                    isIpv6TrafficAllowed= $policy.data.isIpv6TrafficAllowed;
                                    isHitlogEnabled= $policy.data.isHitlogEnabled;
                                    vpcReferences= $policy.data.vpcReferences
                                }
                            } 
                            else 
                            {
                                $content = @{
                                    name= $policyname;
                                    type= $policy.data.type;
                                    description= "added by Invoke-FlowRuleSyncNG.ps1 script";
                                    state= $policy.data.state;
                                    rules= $policy.data.rules;
                                    isIpv6TrafficAllowed= $policy.data.isIpv6TrafficAllowed;
                                    isHitlogEnabled= $policy.data.isHitlogEnabled;
                                    scope= $policy.data.scope
                                }
                            }
                            $payload = (ConvertTo-Json $content -Depth 100)
                            $ntnx_req_id = New-Guid
                            try
                            {#create network policy
                                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id
                                Write-Host "$(Get-Date) [SUCCESS] Added Flow policy $($nsp.name) to $targetPc" -ForegroundColor Cyan
                                if ($debugme) {$resp}
                                #Get-PrismCentralTaskStatus -task $resp -credential $prismCredentials -cluster $targetPc
                            }
                            catch
                            {#we couldn't create the network policy
                                if ($_.Exception.Message -match 'Policy already exists')
                                {#the policy already exists, let's just warn about this
                                    Write-Host "$(Get-Date) [WARNING] Could not add policy $($nsp.name) to $targetPc" -ForegroundColor Yellow
                                    Write-Host "$($_.Exception.Message)" -ForegroundColor Yellow
                                }
                                else
                                {
                                    Throw "$($_.Exception.Message)"
                                }
                            }
                        #endregion

                        Write-Host ""
                    }
                }
            #endregion


            #region process DELETE
                if ($remove_nsp_list.Count -gt 0)
                {#there are the policies to be removed
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Removing Flow policies" -ForegroundColor Magenta
                    foreach ($nsp in $remove_nsp_list)
                    {#process each policy to remove
                        #todo: for each category, figure out if it is used anywhere else in policies on source: if not, delete the category
                        #delete policy on target using the extId from the target policy list
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$nsp.extId
                            $method = "DELETE"
                            $ntnx_req_id = New-Guid

                        Write-Host "$(get-date) [STEP] Deleting Flow policy $($nsp.name) on $($targetPc)" -ForegroundColor Green
                        try
                        {#delete the policy
                            $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -ntnx_req_id $ntnx_req_id
                            Write-Host "$(Get-Date) [SUCCESS] Deleted Flow policy $($nsp.name) to $targetPc" -ForegroundColor Cyan

                        }
                        catch
                        {#we couldn't delete the policy
                            Throw "$($_.Exception.Message)"
                        }
                    }
                }
            #endregion


            #region process UPDATE
                if ($update_nsp_list.Count -gt 0)
                {#there are policies to be updated
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Updating Flow policies" -ForegroundColor Magenta
                    foreach ($nsp in $update_nsp_list)
                    {#process each nsp to update

                        #get the complete nsp from source
                        $policy = Get-PolicyByExtId -pc $sourcePc -extId $nsp.extId

                        if ($policy.data.scope -eq "ALL_VLAN")
                        {
                            Write-Host "$(Get-Date) [WARNING] Not Syncing policy $($policy.data.name) as it is a VLAN policy" -ForegroundColor Cyan
                            continue
                        } elseif ($policy.data.scope -ne "GLOBAL") 
                        {
                            Sync-Vpc -policy $policy -TargetVpcByName $targetVpcByName
                        }
                        Sync-Categories -policy $policy -TargetCategoryIndex $targetCategoryIndex
                        Sync-ServiceGroups -policy $policy -TargetByName $targetSgByName
                        Sync-AddressGroups -policy $policy -TargetByName $targetAgByName

                        $targetNsp = $targetPolicyByName[[string]$nsp.name]
                        if (-not $targetNsp)
                        {
                            Throw "$(Get-Date) [ERROR] Flow policy $($nsp.name) was not found on target Prism Central $targetPc"
                        }
                        $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                        $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$targetNsp.extId
                        $if_match = Invoke-RateLimitedApiCall -method GET -url $url -credential $prismCredentials -ReturnETag

                        #region add nsp on target
                            $method = "PUT"
                            $policyname = $policy.data.name
                            if($rename)
                            {
                                $policyname = $rename + "_" + $policy.data.name
                                Write-Host "$(Get-Date) [INFO] Updating Flow policy $($nsp.name) to $targetPc with new name $policyname" -ForegroundColor Cyan
                            }
                            if ($policy.data.scope -ne "GLOBAL") 
                            {
                                $content = @{
                                    name= $policyname;
                                    type= $policy.data.type;
                                    description= "added by Invoke-FlowRuleSyncNG.ps1 script";
                                    state= $policy.data.state;
                                    rules= $policy.data.rules;
                                    isIpv6TrafficAllowed= $policy.data.isIpv6TrafficAllowed;
                                    isHitlogEnabled= $policy.data.isHitlogEnabled;
                                    vpcReferences= $policy.data.vpcReferences
                                }
                            }
                            else 
                            {
                                $content = @{
                                    name= $policyname;
                                    type= $policy.data.type;
                                    description= "added by Invoke-FlowRuleSyncNG.ps1 script";
                                    state= $policy.data.state;
                                    rules= $policy.data.rules;
                                    isIpv6TrafficAllowed= $policy.data.isIpv6TrafficAllowed;
                                    isHitlogEnabled= $policy.data.isHitlogEnabled;
                                    scope= $policy.data.scope
                                }
                            }
                            $payload = (ConvertTo-Json $content -Depth 100)
                            $ntnx_req_id = New-Guid
                            try
                            {#update the network policy
                                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
                                Write-Host "$(Get-Date) [SUCCESS] Updated Flow policy $($nsp.name) to $targetPc" -ForegroundColor Cyan
                            }
                            catch
                            {#we couldn't update the network policy
                                Throw "$($_.Exception.Message)"
                            }
                        #endregion
                    }
                }
            #endregion
        }
    #endregion

#endregion


#region cleanup
    #let's figure out how much time this all took
    Write-Host ""
    Write-Host "$(get-date) [SUM] total processing time: $($myvarElapsedTime.Elapsed.ToString())" -ForegroundColor Magenta

    if ($log)
    {#we had started a transcript to log file, so let's stop it now that we are done
        Stop-Transcript
    }

    #cleanup after ourselves and delete all custom variables
    Remove-Variable myvar* -ErrorAction SilentlyContinue
    Remove-Variable ErrorActionPreference -ErrorAction SilentlyContinue
    Remove-Variable help -ErrorAction SilentlyContinue
    Remove-Variable history -ErrorAction SilentlyContinue
    Remove-Variable log -ErrorAction SilentlyContinue
    Remove-Variable sourcePc -ErrorAction SilentlyContinue
    Remove-Variable targetPc -ErrorAction SilentlyContinue
    Remove-Variable debugme -ErrorAction SilentlyContinue
#endregion