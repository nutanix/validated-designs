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
  Author: Pramod Singh (pramod.singh@nutanix.com)
  Revision: Dec 10th 2024
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
            $credential
        )

        begin
        {

        }

        process
        {
            Write-Host "$(Get-Date) [INFO] Making a $method call to $url" -ForegroundColor Green
            try {
                #check powershell version as PoSH 6 Invoke-RestMethod can natively skip SSL certificates checks and enforce Tls12 as well as use basic authentication with a pscredential object
                if ($PSVersionTable.PSVersion.Major -gt 5)
                {
                    if ($ntnx_req_id)
                    {
                        if ($if_match)
                        {
                            $headers = @{
                                "Content-Type"="application/json"
                                "Accept"="application/json"
                                "If-Match"=$if_match
                                "NTNX-Request-Id"=$ntnx_req_id
                            }
                        }
                        else
                        {
                            $headers = @{
                                "Content-Type"="application/json"
                                "Accept"="application/json"
                                "NTNX-Request-Id"=$ntnx_req_id
                            }
                        }
                    }
                    else
                    {
                        $headers = @{
                            "Content-Type"="application/json"
                            "Accept"="application/json"
                        }
                    }
                    if ($payload)
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -SkipHeaderValidation -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
                    }
                    else
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -SkipCertificateCheck -SslProtocol Tls12 -Authentication Basic -Credential $credential -ErrorAction Stop
                    }
                }
                else
                {
                    $username = $credential.UserName
                    $password = $credential.Password
                    if ($ntnx_req_id)
                    {
                        if ($if_match)
                        {
                            $headers = @{
                                "Content-Type"="application/json"
                                "Accept"="application/json"
                                "If-Match"=$if_match
                                "NTNX-Request-Id"=$ntnx_req_id
                            }
                        }
                        else
                        {
                            $headers = @{
                                "Content-Type"="application/json"
                                "Accept"="application/json"
                                "NTNX-Request-Id"=$ntnx_req_id
                            }
                        }
                    }
                    else
                    {
                        $headers = @{
                            "Authorization" = "Basic "+[System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($username+":"+([System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password))) ))
                            "Content-Type"="application/json"
                            "Accept"="application/json"
                        }
                    }
                    if ($payload)
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
                    }
                    else
                    {
                        $resp = Invoke-RestMethod -Method $method -Uri $url -Headers $headers -ErrorAction Stop
                    }
                }
                Write-Host "$(get-date) [SUCCESS] Call $method to $url succeeded." -ForegroundColor Cyan
                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}
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

    #this function is used to apply rate limiting on each REST method which
    #is 5 Msg/sec and at the end makes a REST api call to Prism
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
            [Parameter()][string] $if_match
        )

        # Hardcoded rate limit per method
        $maxPerSecond = 5

        # Global per-method tracker
        if (-not $script:RateLimitMap)
        {
            $script:RateLimitMap = @{}
        }

        if (-not $script:RateLimitMap.ContainsKey($method))
        {
            $script:RateLimitMap[$method] = @{
                Counter   = 0
                StartTime = Get-Date
            }
        }

        $rateState = $script:RateLimitMap[$method]
        $now = Get-Date
        $elapsed = ($now - $rateState.StartTime).TotalSeconds

        if ($elapsed -ge 1)
        {
            # Reset every 1 second
            $rateState.Counter = 0
            $rateState.StartTime = $now
        }

        if ($rateState.Counter -ge $maxPerSecond)
        {
            Write-Host "$(Get-Date) [INFO] [$method] Reached $maxPerSecond req/sec. Sleeping 1 second..." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            $rateState.Counter = 0
            $rateState.StartTime = Get-Date
        }

        $rateState.Counter++
        $script:RateLimitMap[$method] = $rateState

        return Invoke-PrismAPICall -method $method -url $url -credential $credential -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
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
        [CmdletBinding()]
        param(
            [Parameter(Mandatory = $true)][string] $pc,
            [Parameter(Mandatory = $true)][string] $object
        )

        begin {
            $page = 0
            $limit = 100
            $totalAvailable = 0
            [System.Collections.ArrayList]$results = @()

            $baseUrl = "https://{0}:9440/api/microseg/v4.0/config/{1}" -f $pc, $object
            $method = "GET"
        }

        process {
            do {
                try {
                    # Add correct query separator if needed
                    $sep = if ($baseUrl -match '\?') { '&' } else { '?' }

                    # Use encoded parameters %24page and %24limit to substitute $
                    # which is needed in V4 API odata format for limit and pag query
                    $url = "$baseUrl${sep}%24page=$page&%24limit=$limit"

                    Write-Host "$(Get-Date) [INFO] Calling URL: $url" -ForegroundColor Cyan
                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    if (-not $resp -or -not $resp.data) {
                        Write-Host "$(Get-Date) [INFO] No data received." -ForegroundColor Yellow
                        break
                    }

                    # Get total available policies from metadata
                    if ($totalAvailable -eq 0 -and $resp.metadata.totalAvailableResults) {
                        $totalAvailable = $resp.metadata.totalAvailableResults
                        Write-Host "$(Get-Date) [INFO] Total available results: $totalAvailable" -ForegroundColor Green
                    }

                    # Add current page data
                    $results.AddRange($resp.data)
                    Write-Host "$(Get-Date) [INFO] Retrieved $($resp.data.Count) objects (Total so far: $($results.Count))" -ForegroundColor Green

                    $page++
                }
                catch {
                    Throw "$(Get-Date) [ERROR] $($_.Exception.Message)"
                }
            }
            while ($results.Count -lt $totalAvailable)
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
    {#retrieves Category object v4
        [CmdletBinding()]
        param
        (
            [Parameter(mandatory = $true)][string] $pc,
            [Parameter(mandatory = $true)][string] $extId
        )

        begin
        {
            $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories/{1}" -f $pc,$extId
            $method = "GET"
        }

        process
        {
            try {
                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}

                $category_value_pair = "$($resp.data.key):$($resp.data.value)"
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

        end
        {
            return $category_value_pair
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
    {#retrieves vpc object v4
        [CmdletBinding()]
        param
        (
            [Parameter(mandatory = $true)][string] $pc,
            [Parameter(mandatory = $true)][string] $extId
        )

        begin
        {
            $url = "https://{0}:9440/api/networking/v4.0/config/vpcs/{1}" -f $pc,$extId
            $method = "GET"
        }

        process
        {
            try {
                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                if ($debugme) {Write-Host "$(Get-Date) [DEBUG] Response Metadata: $($resp.metadata | ConvertTo-Json)" -ForegroundColor White}

                $vpc_name = "$($resp.data.name)"
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

        end
        {
            return $vpc_name
        }
    }

    function Sync-Categories
    {#syncs Prism categories used in a given network policy
        param
        (
            [Parameter(Mandatory)]
            $policy
        )

        begin {}

        process
        {
            #region which categories are used?
            #* figure out categories used in this policy
            Write-Host "$(get-date) [INFO] Examining categories..." -ForegroundColor Green
            [System.Collections.ArrayList]$used_categories_list = New-Object System.Collections.ArrayList($null)
            [System.Collections.ArrayList]$used_category_uuids_list = New-Object System.Collections.ArrayList($null)
            #types of Policies (where categories are listed varies depending on the type of policy):
            if ($policy.data.type -eq "ISOLATION")
            {#this is an isolation policy
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Isolation policy..." -ForegroundColor Green
                foreach ($rule in ($policy.data.rules))
                {
                    if ($rule.spec.firstIsolationGroup){
                        foreach ($categoryExtId in $rule.spec.firstIsolationGroup)
                        {#process each category used in first isolation group
                            $used_category_uuids_list.Add($categoryExtId) | Out-Null
                        }
                    }
                    if ($rule.spec.secondIsolationGroup){
                        foreach ($categoryExtId in $rule.spec.secondIsolationGroup)
                        {#process each category used in second isolation group
                            $used_category_uuids_list.Add($categoryExtId) | Out-Null
                        }
                    }
                    if ($rule.spec.spec.isolationGroups){
                        for ($i = 0; $i -lt $rule.spec.spec.isolationGroups.Count; $i++)
                        {
                            foreach ($categoryExtId in $rule.spec.spec.isolationGroups[$i].groupCategoryReferences)
                            {#process each category used in second isolation group
                                $used_category_uuids_list.Add($categoryExtId) | Out-Null
                            }
                        }

                    }
                }
            }
            elseif ($policy.data.type -eq "APPLICATION")
            {#this is an app policy
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Application policy..." -ForegroundColor Green
                foreach ($rule in ($policy.data.rules))
                {
                    if ($rule.spec.securedGroupCategoryReferences){
                        foreach ($categoryExtId in $rule.spec.securedGroupCategoryReferences)
                        {#process each category used in secured group
                            $used_category_uuids_list.Add($categoryExtId) | Out-Null
                        }
                    }
                    if ($rule.spec.srcCategoryReferences){
                        foreach ($categoryExtId in $rule.spec.srcCategoryReferences)
                        {#process each category used in inbound_allow_list
                            $used_category_uuids_list.Add($categoryExtId) | Out-Null
                        }
                    }
                    if ($rule.spec.destCategoryReferences){
                        foreach ($categoryExtId in $rule.spec.destCategoryReferences)
                        {#process each category used in inbound_allow_list
                            $used_category_uuids_list.Add($categoryExtId) | Out-Null
                        }
                    }
                }
            }
            else
            {#we don't know what type of Policy this is
                Write-Host "$(get-date) [WARNING] Policy $($policy.data.name) is not a supported policy type for replication!" -ForegroundColor Yellow
            }
            foreach ($category_uuid in ($used_category_uuids_list | Select-Object -Unique))
            {# Get the category key value for each used category
                $category_value_pair = Get-CategoryByExtId -pc $sourcePc -extId $category_uuid
                $used_categories_list.Add($category_value_pair) | Out-Null
            }

            Write-Host "$(get-date) [DATA] Flow policy $($policy.data.name) uses the following category:value pairs:" -ForegroundColor White
            $used_categories_list | Select-Object -Unique
            #endregion

            #region are all used category:value pairs on target?
                #* check each used category:value pair exists on target
                [System.Collections.ArrayList]$missing_categories_list = New-Object System.Collections.ArrayList($null)
                foreach ($category_value_pair in ($used_categories_list | Select-Object -Unique))
                {#process each used category
                    $category = ($category_value_pair -split ":")[0]
                    $value = ($category_value_pair -split ":")[1]
                    $filter = "`$filter=key eq '$($category)' and value eq '$($value)'"
                    $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories?{1}" -f $targetPc,$filter
                    $method = "GET"

                    Write-Host "$(Get-Date) [INFO] Checking category:value pair $($category):$($value) exists in $targetPc..." -ForegroundColor Green
                    try
                    {
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                        if ($resp.metadata.totalAvailableResults -eq 0)
                        {
                            Write-Host "$(get-date) [WARNING] The category:value pair specified ($($category):$($value)) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                            $missing_categories_list.Add($category_value_pair) | Out-Null
                            Continue
                        }
                        else
                        {
                            Write-Host "$(Get-Date) [SUCCESS] Found the category:value pair $($category):$($value) in $targetPc" -ForegroundColor Cyan
                            #the category already exists on target, let's update the uuid reference in the policy
                            $target_category_uuid = $resp.data.extId
                            #get source category uuid
                            $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories?{1}" -f $sourcePc,$filter
                            $method = "GET"
                            $source_category = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                            if ($policy.data.type -eq "APPLICATION")
                            {
                                foreach ($rule in ($policy.data.rules))
                                {
                                    for ($i = 0; $i -lt $rule.spec.securedGroupCategoryReferences.Count; $i++)
                                    {
                                        if ($rule.spec.securedGroupCategoryReferences[$i] -eq $source_category.data.extId)
                                        {#that address group is used in inbound list
                                            $rule.spec.securedGroupCategoryReferences[$i] = $target_category_uuid
                                        }
                                    }
                                    for ($i = 0; $i -lt $rule.spec.srcCategoryReferences.Count; $i++)
                                    {
                                        if ($rule.spec.srcCategoryReferences[$i] -eq $source_category.data.extId)
                                        {#that address group is used in inbound list
                                            $rule.spec.srcCategoryReferences[$i] = $target_category_uuid
                                        }
                                    }
                                    for ($i = 0; $i -lt $rule.spec.destCategoryReferences.Count; $i++)
                                    {
                                        if ($rule.spec.destCategoryReferences[$i] -eq $source_category.data.extId)
                                        {#that address group is used in outbound list
                                            $rule.spec.destCategoryReferences[$i] = $target_category_uuid
                                        }
                                    }
                                }
                            }
                            elseif (($policy.data.type -eq "ISOLATION"))
                            {
                                foreach ($rule in ($policy.data.rules))
                                {

                                    for ($i = 0; $i -lt $rule.spec.firstIsolationGroup.Count; $i++)
                                    {
                                        if ($rule.spec.firstIsolationGroup[$i] -eq $source_category.data.extId)
                                        {#that address group is used in inbound list
                                            $rule.spec.firstIsolationGroup[$i] = $target_category_uuid
                                        }
                                    }
                                    for ($i = 0; $i -lt $rule.spec.secondIsolationGroup.Count; $i++)
                                    {
                                        if ($rule.spec.secondIsolationGroup[$i] -eq $source_category.data.extId)
                                        {#that address group is used in outbound list
                                            $rule.spec.secondIsolationGroup[$i] = $target_category_uuid
                                        }
                                    }
                                    for ($i = 0; $i -lt $rule.spec.spec.isolationGroups.Count; $i++)
                                    {
                                        for($j = 0; $j -lt $rule.spec.spec.isolationGroups[$i].groupCategoryReferences.Count; $j++)
                                        {
                                            if ($rule.spec.spec.isolationGroups[$i].groupCategoryReferences[$j] -eq $source_category.data.extId)
                                            {#that address group is used in outbound list
                                                $rule.spec.spec.isolationGroups[$i].groupCategoryReferences[$j] = $target_category_uuid
                                             }
                                        }

                                    }

                                }

                            }
                        }
                    }
                    catch
                    {
                        $saved_error = $_.Exception.Message
                        $error_code = ($saved_error -split " ")[3]
                        if ($error_code -eq "404")
                        {
                            Write-Host "$(get-date) [WARNING] The category:value pair specified ($($category):$($value)) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                            $missing_categories_list.Add($category_value_pair) | Out-Null
                            Continue
                        }
                        else
                        {
                            Write-Host "$saved_error" -ForegroundColor Yellow
                            Continue
                        }
                    }
                }
                if ($missing_categories_list)
                {#there are missing categories on target
                    Write-Host "$(get-date) [DATA] The following category:value pairs need to be added on $($targetPc):" -ForegroundColor White
                    $missing_categories_list
                }
            #endregion

            #region create missing category:value pairs on target
                [System.Collections.ArrayList]$processed_categories_list = New-Object System.Collections.ArrayList($null)
                foreach ($category_value_pair in $missing_categories_list)
                {#process all missing categories and values
                    $category = ($category_value_pair -split ":")[0]
                    $value = ($category_value_pair -split ":")[1]

                    #add category key value
                    $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories" -f $targetPc
                    $method = "POST"
                    $content = @{
                        key=$category;
                        description="added by Invoke-FlowRuleSyncNG.ps1 script";
                        value="$value"
                    }
                    $payload = (ConvertTo-Json $content -Depth 4)
                    try
                    {#add the value
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload
                        Write-Host "$(Get-Date) [SUCCESS] Added category $($category):$($value) in $targetPc" -ForegroundColor Cyan
                        if ($debugme) {$resp}
                        #Get-PrismCentralTaskStatus -task $resp -credential $prismCredentials -cluster $targetPc

                        #Let's update the uuid reference in the policy for the newly created category
                        $target_category_uuid = $resp.data.extId
                        #get source category uuid
                        $filter = "`$filter=key eq '$($category)' and value eq '$($value)'"
                        $url = "https://{0}:9440/api/prism/v4.0.a2/config/categories?{1}" -f $sourcePc,$filter
                        $method = "GET"
                        $source_category = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                        if ($policy.data.type -eq "APPLICATION")
                        {
                            foreach ($rule in ($policy.data.rules))
                            {
                                for ($i = 0; $i -lt $rule.spec.securedGroupCategoryReferences.Count; $i++)
                                {
                                    if ($rule.spec.securedGroupCategoryReferences[$i] -eq $source_category.data.extId)
                                    {#that address group is used in inbound list
                                        $rule.spec.securedGroupCategoryReferences[$i] = $target_category_uuid
                                    }
                                }
                                for ($i = 0; $i -lt $rule.spec.srcCategoryReferences.Count; $i++)
                                {
                                    if ($rule.spec.srcCategoryReferences[$i] -eq $source_category.data.extId)
                                    {#that address group is used in inbound list
                                        $rule.spec.srcCategoryReferences[$i] = $target_category_uuid
                                    }
                                }
                                for ($i = 0; $i -lt $rule.spec.destCategoryReferences.Count; $i++)
                                {
                                    if ($rule.spec.destCategoryReferences[$i] -eq $source_category.data.extId)
                                    {#that address group is used in outbound list
                                        $rule.spec.destCategoryReferences[$i] = $target_category_uuid
                                    }
                                }
                            }
                        }
                        elseif (($policy.data.type -eq "ISOLATION"))
                        {
                            foreach ($rule in ($policy.data.rules))
                            {

                                for ($i = 0; $i -lt $rule.spec.firstIsolationGroup.Count; $i++)
                                {
                                    if ($rule.spec.firstIsolationGroup[$i] -eq $source_category.data.extId)
                                    {#that address group is used in inbound list
                                        $rule.spec.firstIsolationGroup[$i] = $target_category_uuid
                                    }
                                }
                                for ($i = 0; $i -lt $rule.spec.secondIsolationGroup.Count; $i++)
                                {
                                    if ($rule.spec.secondIsolationGroup[$i] -eq $source_category.data.extId)
                                    {#that address group is used in outbound list
                                        $rule.spec.secondIsolationGroup[$i] = $target_category_uuid
                                    }
                                }
                                for ($i = 0; $i -lt $rule.spec.spec.isolationGroups.Count; $i++)
                                {
                                    for ($j = 0; $j -lt $rule.spec.spec.isolationGroups[$i].groupCategoryReferences.Count; $j++)
                                    {
                                        if ($rule.spec.spec.isolationGroups[$i].groupCategoryReferences[$j] -eq $source_category.data.extId)
                                        {
                                            #that address group is used in outbound list
                                            $rule.spec.spec.isolationGroups[$i].groupCategoryReferences[$j] = $target_category_uuid
                                        }
                                    }

                                }

                            }

                        }
                    }
                    catch
                    {#we couldn't add the value
                        Throw "$($_.Exception.Message)"
                    }
                }
            #endregion
        }

        end {}
    }

    function Sync-AddressGroups
    {#syncs Prism address groups used in a given network policy
        param
        (
            [Parameter(Mandatory)]
            $policy
        )

        begin {}

        process
        {
            #region GET address groups from target
                Write-Host ""
                Write-Host "$(get-date) [STEP] Getting address groups from target..." -ForegroundColor Magenta

                #region process target
                    Write-Host "$(get-date) [INFO] Retrieving list of address groups from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                    $target_address_groups = Get-MicrosegObjectList -pc $targetPc -object "address-groups"
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of address groups from the target Prism Central instance $($targetPc)" -ForegroundColor Cyan
                    Write-Host "$(get-date) [DATA] There are $($target_address_groups.count) address groups on target Prism Central $($targetPc)..." -ForegroundColor White
                #endregion
            #endregion

            #region which address groups are used?
                #* figure out address groups used in this policy
                Write-Host "$(get-date) [INFO] Examining address groups..." -ForegroundColor Green
                [System.Collections.ArrayList]$used_address_group_list = New-Object System.Collections.ArrayList($null)
                if ($policy.data.type -eq "APPLICATION")
                {#this is an app policy
                    foreach ($rule in ($policy.data.rules))
                    {
                        if ($rule.spec.srcAddressGroupReferences){
                            foreach ($address_group_extId in $rule.spec.srcAddressGroupReferences)
                            {#process each address group used in inbound_allow_list
                                $used_address_group_list.Add($address_group_extId) | Out-Null
                            }
                        }
                        if ($rule.spec.destAddressGroupReferences){
                            foreach ($address_group_extId in $rule.spec.destAddressGroupReferences)
                            {#process each address group used in outbound_allow_list
                                $used_address_group_list.Add($address_group_extId) | Out-Null
                            }
                        }
                    }
                }
            #endregion

            #region are all used address groups on the target?

                [System.Collections.ArrayList]$missing_address_groups_list = New-Object System.Collections.ArrayList($null)
                foreach ($address_group_uuid in ($used_address_group_list | Select-Object -Unique))
                {#process each used address group
                    $api_server_endpoint = "/api/microseg/v4.0/config/address-groups/{0}" -f $address_group_uuid
                    $url = "https://{0}:9440{1}" -f $sourcePc,$api_server_endpoint
                    $method = "GET"

                    $source_address_group = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    if ($source_address_group.data.name -notin $target_address_groups.name)
                    {#based on its name, that address group does not exist on the target
                        $missing_address_groups_list.Add($source_address_group.data) | Out-Null
                    }
                    else
                    {#the address group already exists on target, let's update the uuid reference in the policy
                        $target_address_group_uuid = ($target_address_groups | Where-Object {$_.name -eq $source_address_group.data.name}).extId
                        foreach ($rule in ($policy.data.rules))
                        {
                            for ($i = 0; $i -lt $rule.spec.srcAddressGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.srcAddressGroupReferences[$i] -eq $source_address_group.data.extId)
                                {#that address group is used in inbound list
                                    $rule.spec.srcAddressGroupReferences[$i] = $target_address_group_uuid
                                }
                            }
                            for ($i = 0; $i -lt $rule.spec.destAddressGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.destAddressGroupReferences[$i] -eq $source_address_group.data.extId)
                                {#that address group is used in outbound list
                                    $rule.spec.destAddressGroupReferences[$i] = $target_address_group_uuid
                                }
                            }
                        }
                        if ($rename)
                        {#Using rename option to rename address groups in target before enabling entity sync
                            #Get address group etag
                            $api_server_endpoint = "/api/microseg/v4.0/config/address-groups"
                            $auth = @{ Authorization = "Basic "+ [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($prismCredentials.UserName):$($prismCredentials.GetNetworkCredential().password)")) }
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$target_address_group_uuid
                            $targetAgEtag = Invoke-WebRequest -Uri $url -SkipCertificateCheck -Headers $auth

                            #Update address group
                            $api_server_endpoint = "/api/microseg/v4.0/config/address-groups"
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$target_address_group_uuid
                            $method = "PUT"
                            $content = @{
                                description="added by Invoke-FlowRuleSyncNG.ps1 script";
                                name = $rename + "_" + $source_address_group.data.name
                            }
                            if ($source_address_group.data.ipv4Addresses)
                            {
                                $content.Add("ipv4Addresses",$source_address_group.data.ipv4Addresses)
                            }
                            if ($source_address_group.data.ipRanges)
                            {
                                $content.Add("ipRanges",$source_address_group.data.ipRanges)
                            }
                            $payload = (ConvertTo-Json $content -Depth 10)
                            $ntnx_req_id = New-Guid
                            $if_match = [System.String]($targetAgEtag.Headers.ETag)
                            Write-Host "$(Get-Date) [INFO] Updating address group $($source_address_group.data.name) to $targetPc with name $($rename + "_" + $source_address_group.data.name)" -ForegroundColor Green
                            try
                            {#update address group
                                $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
                                Write-Host "$(Get-Date) [SUCCESS] Updated address group $($source_address_group.data.name) to $targetPc with name $($rename + "_" + $source_address_group.data.name)" -ForegroundColor Cyan
                                if ($debugme) {$resp}
                                #Get-PrismCentralTaskStatus -task $resp -credential $prismCredentials -cluster $targetPc
                            }
                            catch
                            {#we couldn't update the address group
                                Throw "$($_.Exception.Message)"
                            }
                        }
                    }
                }
                if ($missing_address_groups_list)
                {#there are missing address groups
                    Write-Host "$(get-date) [DATA] The following address groups need to be added on $($targetPc):" -ForegroundColor White
                    $missing_address_groups_list.name
                }
            #endregion

            #region create missing address groups on target
                [System.Collections.ArrayList]$processed_address_groups_list = New-Object System.Collections.ArrayList($null)
                foreach ($address_group in $missing_address_groups_list)
                {#process all missing address groups
                    #add address group
                    $api_server_endpoint = "/api/microseg/v4.0/config/address-groups"
                    $url = "https://{0}:9440{1}" -f $targetPc,$api_server_endpoint
                    $method = "POST"
                    $agname = $address_group.name
                    if ($rename)
                    {
                       $agname = $rename + "_" + $address_group.name
                       Write-Host "$(Get-Date) [INFO] Adding address group $($address_group.name) to $targetPc with name $($agname)" -ForegroundColor Green
                    }
                    $content = @{
                        description="added by Invoke-FlowRuleSyncNG.ps1 script";
                        name=$agname
                    }
                    if ($address_group.ipv4Addresses)
                    {
                        $content.Add("ipv4Addresses",$address_group.ipv4Addresses)
                    }
                    if ($address_group.ipRanges)
                    {
                        $content.Add("ipRanges",$address_group.ipRanges)
                    }
                    $payload = (ConvertTo-Json $content -Depth 10)
                    $ntnx_req_id = New-Guid
                    Write-Host "$(Get-Date) [INFO] Adding address group $($address_group.name) to $targetPc" -ForegroundColor Green
                    try
                    {#add address group
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id
                        Write-Host "$(Get-Date) [SUCCESS] Added address group $($address_group.name) to $targetPc" -ForegroundColor Cyan
                        if ($debugme) {$resp}
                        #Get-PrismCentralTaskStatus -task $resp -credential $prismCredentials -cluster $targetPc

                        #Get the address group to get the uuid
                        $api_server_endpoint = "/api/microseg/v4.0/config/address-groups/"
                        $filter = "`$filter=name eq '$($agname)'"
                        $url = "https://{0}:9440{1}?{2}" -f $targetPc,$api_server_endpoint,$filter
                        $method = "GET"
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                        foreach ($rule in ($policy.data.rules))
                        {
                            for ($i = 0; $i -lt $rule.spec.srcAddressGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.srcAddressGroupReferences[$i] -eq $address_group.extId)
                                {#that address group is used in inbound allow list, let's update the uuid with that of the newly created address group
                                    $rule.spec.srcAddressGroupReferences[$i] = $resp.data.extId
                                }
                            }
                            for ($i = 0; $i -lt $rule.spec.destAddressGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.destAddressGroupReferences[$i] -eq $address_group.extId)
                                {#that address group is used in outbound allow list, let's update the uuid with that of the newly created address group
                                    $rule.spec.destAddressGroupReferences[$i] = $resp.data.extId
                                }
                            }
                        }
                    }
                    catch
                    {#we couldn't add the address group
                        Throw "$($_.Exception.Message)"
                    }
                }
            #endregion
        }

        end {}
    }

    function Sync-ServiceGroups
    {#syncs Prism service groups used in a given network policy
        param
        (
            [Parameter(Mandatory)]
            $policy
        )

        begin {}

        process
        {
            #region GET service groups from target
                Write-Host ""
                Write-Host "$(get-date) [STEP] Getting service groups in target PC..." -ForegroundColor Magenta

                #region process target
                    Write-Host "$(get-date) [INFO] Retrieving list of service groups from the target Prism Central instance $($targetPc)..." -ForegroundColor Green
                    $filter = "`$filter=isSystemDefined eq false"
                    $target_service_groups = Get-MicrosegObjectList -pc $targetPc -object "service-groups?$filter"
                    Write-Host "$(get-date) [SUCCESS] Successfully retrieved list of service groups from the target Prism Central instance $($targetPc)" -ForegroundColor Cyan
                    Write-Host "$(get-date) [DATA] There are $($target_service_groups.count) service groups on target Prism Central $($targetPc)..." -ForegroundColor White
                #endregion
            #endregion

            #region which service groups are used?
                #* figure out service groups used in this policy
                Write-Host "$(get-date) [INFO] Examining service groups..." -ForegroundColor Green
                [System.Collections.ArrayList]$used_service_group_list = New-Object System.Collections.ArrayList($null)
                if ($policy.data.type -eq "APPLICATION")
                {#this is an app policy
                    foreach ($rule in ($policy.data.rules))
                    {
                        if ($rule.spec.serviceGroupReferences){
                            foreach ($service_group_extId in $rule.spec.serviceGroupReferences)
                            {#process each service group used in nsp
                                $used_service_group_list.Add($service_group_extId) | Out-Null
                            }
                        }
                    }
                }
            #endregion

            #region are all used service groups on the target?

                [System.Collections.ArrayList]$missing_service_groups_list = New-Object System.Collections.ArrayList($null)
                foreach ($service_group_uuid in ($used_service_group_list | Select-Object -Unique))
                {#process each used service group
                    #find out what the service group name is (only uuid is kept in rule definition)
                    $api_server_endpoint = "/api/microseg/v4.0/config/service-groups/{0}" -f $service_group_uuid
                    $url = "https://{0}:9440{1}" -f $sourcePc,$api_server_endpoint
                    $method = "GET"

                    $source_service_group = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                    #Write-Host "$(Get-Date) [INFO] Checking service group $($source_service_group.service_group.name) exists in $targetPc..." -ForegroundColor Green
                    if (!$source_service_group.data.isSystemDefined)
                    {#there is no need to sync system defined service groups
                        if ($source_service_group.data.name -notin $target_service_groups.name)
                        {#based on its name, that service group does not exist on the target
                            $missing_service_groups_list.Add($source_service_group.data) | Out-Null
                        }
                        else
                        {#the service group already exists on target, let's update the uuid reference in the policy,
                            $target_service_group_uuid = ($target_service_groups | Where-Object {$_.name -eq $source_service_group.data.name}).extId
                            foreach ($rule in ($policy.data.rules))
                            {
                                for ($i = 0; $i -lt $rule.spec.serviceGroupReferences.Count; $i++)
                                {
                                    if ($rule.spec.serviceGroupReferences[$i] -eq $source_service_group.data.extId)
                                    {
                                        $rule.spec.serviceGroupReferences[$i] = $target_service_group_uuid
                                    }
                                }
                            }
                            if ($rename)
                            {#Using rename option to rename address groups in target before enabling entity sync
                                #Get service group etag
                                $api_server_endpoint = "/api/microseg/v4.0/config/service-groups"
                                $auth = @{ Authorization = "Basic "+ [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($prismCredentials.UserName):$($prismCredentials.GetNetworkCredential().password)")) }
                                $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$target_service_group_uuid
                                $targetSgEtag = Invoke-WebRequest -Uri $url -SkipCertificateCheck -Headers $auth

                                #Update service group
                                $api_server_endpoint = "/api/microseg/v4.0/config/service-groups"
                                $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$target_service_group_uuid
                                $method = "PUT"
                                $content = @{
                                    description="added by Invoke-FlowRuleSyncNG.ps1 script";
                                    name = $rename + "_" + $source_service_group.data.name
                                }
                                if ($source_service_group.data.tcpServices)
                                {
                                    $content.Add("tcpServices",$source_service_group.data.tcpServices)
                                }
                                if ($source_service_group.data.udpServices)
                                {
                                    $content.Add("udpServices",$source_service_group.data.udpServices)
                                }
                                if ($source_service_group.data.icmpServices)
                                {
                                    $content.Add("icmpServices",$source_service_group.data.icmpServices)
                                }
                                $payload = (ConvertTo-Json $content -Depth 10)
                                $ntnx_req_id = New-Guid
                                $if_match = [System.String]($targetSgEtag.Headers.ETag)
                                Write-Host "$(Get-Date) [INFO] Updating service group $($source_service_group.data.name) to $targetPc with name $($rename + "_" + $source_service_group.data.name)" -ForegroundColor Green
                                try
                                {#update service group
                                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id -if_match $if_match
                                    Write-Host "$(Get-Date) [SUCCESS] Updated service group $($source_service_group.data.name) to $targetPc with name $($rename + "_" + $source_service_group.data.name)" -ForegroundColor Cyan
                                    if ($debugme) {$resp}
                                    #Get-PrismCentralTaskStatus -task $resp -credential $prismCredentials -cluster $targetPc
                                }
                                catch
                                {#we couldn't update the service group
                                    Throw "$($_.Exception.Message)"
                                }
                            }
                        }
                    }
                    else
                    {#its a system defined service group, but we need to update the uuid reference in the policy
                        $api_server_endpoint = "/api/microseg/v4.0/config/service-groups/"
                        $filter = "`$filter=name eq '$($source_service_group.data.name)'"
                        $url = "https://{0}:9440{1}?{2}" -f $targetPc,$api_server_endpoint,$filter
                        $method = "GET"
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                        $target_service_group_uuid = $resp.data.extId

                        foreach ($rule in ($policy.data.rules))
                        {
                            for ($i = 0; $i -lt $rule.spec.serviceGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.serviceGroupReferences[$i] -eq $source_service_group.data.extId)
                                {
                                    $rule.spec.serviceGroupReferences[$i] = $target_service_group_uuid
                                }
                            }
                        }
                    }
                }

                if ($missing_service_groups_list)
                {#there are missing service groups
                    Write-Host "$(get-date) [DATA] The following service groups need to be added on $($targetPc):" -ForegroundColor White
                    $missing_service_groups_list.name
                }
            #endregion

            #region create missing service groups on target
                [System.Collections.ArrayList]$processed_service_groups_list = New-Object System.Collections.ArrayList($null)
                foreach ($service_group in $missing_service_groups_list)
                {#process all missing service groups
                    #add service group
                    $api_server_endpoint = "/api/microseg/v4.0/config/service-groups"
                    $url = "https://{0}:9440{1}" -f $targetPc,$api_server_endpoint
                    $method = "POST"
                    $sgname=$service_group.name
                    if($rename)
                    {
                        $sgname= $rename + "_" + $service_group.name
                        Write-Host "$(Get-Date) [INFO] Adding service group $($service_group.name) to $targetPc with name $($sgname)" -ForegroundColor Green
                    }
                    $content = @{
                        description="added by Invoke-FlowRuleSyncNG.ps1 script";
                        name=$sgname
                    }
                    if ($service_group.tcpServices)
                    {
                        $content.Add("tcpServices",$service_group.tcpServices)
                    }
                    if ($service_group.udpServices)
                    {
                        $content.Add("udpServices",$service_group.udpServices)
                    }
                    if ($service_group.icmpServices)
                    {
                        $content.Add("icmpServices",$service_group.icmpServices)
                    }
                    $payload = (ConvertTo-Json $content -Depth 10)
                    $ntnx_req_id = New-Guid
                    Write-Host "$(Get-Date) [INFO] Adding service group $($service_group.name) to $targetPc" -ForegroundColor Green
                    try
                    {#add service group
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials -payload $payload -ntnx_req_id $ntnx_req_id
                        Write-Host "$(Get-Date) [SUCCESS] Added service group $($service_group.name) to $targetPc" -ForegroundColor Cyan
                        if ($debugme) {$resp}

                        #Get the service group to get the uuid
                        $api_server_endpoint = "/api/microseg/v4.0/config/service-groups/"
                        $filter = "`$filter=name eq '$($sgname)'"
                        $url = "https://{0}:9440{1}?{2}" -f $targetPc,$api_server_endpoint,$filter
                        $method = "GET"
                        $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                        #let's update the uuid reference of the new service group in the policy
                        foreach ($rule in ($policy.data.rules))
                        {
                            for ($i = 0; $i -lt $rule.spec.serviceGroupReferences.Count; $i++)
                            {
                                if ($rule.spec.serviceGroupReferences[$i] -eq $service_group.extId)
                                {
                                    $rule.spec.serviceGroupReferences[$i] = $resp.data.extId
                                }
                            }
                        }
                    }
                    catch
                    {#we couldn't add the service group
                        Throw "$($_.Exception.Message)"
                    }
                }
            #endregion
        }

        end {}
    }

    function Sync-Vpc
    {#syncs Prism VPC used in a given network policy
        param
        (
            [Parameter(Mandatory)]
            $policy
        )

        begin {}

        process
        {
            #region which vpc are used?
            #* figure out vpc used in this policy
            Write-Host "$(get-date) [INFO] Examining vpc..." -ForegroundColor Green
            [System.Collections.ArrayList]$used_vpc_list = New-Object System.Collections.ArrayList($null)
            [System.Collections.ArrayList]$used_vpc_uuids_list = New-Object System.Collections.ArrayList($null)
            if ($policy.data.type -eq "ISOLATION" -or $policy.data.type -eq "APPLICATION")
            {
                Write-Host "$(get-date) [INFO] Policy $($policy.data.name) is an Isolation or Application policy..." -ForegroundColor Green
                foreach ($vpcExtId in $policy.data.vpcReferences)
                {#process each vpc used in first isolation/application group
                    $used_vpc_uuids_list.Add($vpcExtId) | Out-Null
                    if ($debugme) {Write-Host "$(get-date) [INFO] Policy vpcextId $($vpcExtId) " -ForegroundColor Green}
                }
            }

            else
            {#we don't know what type of Policy this is
                Write-Host "$(get-date) [WARNING] Policy $($policy.data.name) is not a supported policy type for replication!" -ForegroundColor Yellow
            }
            foreach ($vpc_uuid in ($used_vpc_uuids_list | Select-Object -Unique))
            {# add vpc id for each vpc uuid
                $vpc_name = Get-VpcByExtId -pc $sourcePc -extId $vpc_uuid
                $used_vpc_list.Add($vpc_name) | Out-Null
            }

            Write-Host "$(get-date) [DATA] Flow policy $($policy.data.name) uses the following VPC :" -ForegroundColor White
            $used_vpc_list | Select-Object -Unique
            #endregion

            #region are all used vpc on target?
            #* check each used vpc exists on target
            [System.Collections.ArrayList]$missing_vpc_list = New-Object System.Collections.ArrayList($null)
            foreach ($vpc_name in ($used_vpc_list | Select-Object -Unique))
            {#process each used vpc
                $filter = "`$filter=name eq '$($vpc_name)'"
                $url = "https://{0}:9440/api/networking/v4.0/config/vpcs?{1}" -f $targetPc,$filter
                $method = "GET"

                Write-Host "$(Get-Date) [INFO] Checking VPC $($vpc_name) exists in $targetPc..." -ForegroundColor Green
                try
                {
                    $resp = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                    if ($resp.metadata.totalAvailableResults -eq 0)
                    {
                        Write-Host "$(get-date) [WARNING] The VPC ($vpc_name) does not exist in Prism Central $targetPc" -ForegroundColor Yellow
                        $missing_vpc_list.Add($vpc_name) | Out-Null
                        Continue
                    }
                    else
                    {
                        Write-Host "$(Get-Date) [SUCCESS] Found the VPC $($vpc_name) in $targetPc" -ForegroundColor Cyan
                        #the vpc already exists on target, let's update the uuid reference in the policy
                        $target_vpc_uuid = $resp.data.extId
                        #get source vpc uuid
                        $url = "https://{0}:9440/api/networking/v4.0/config/vpcs?{1}" -f $sourcePc,$filter
                        $method = "GET"
                        $source_vpc = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials
                        $source_vpc_extId = $source_vpc.data.extId
                        if ($policy.data.type -eq "ISOLATION" -or $policy.data.type -eq "APPLICATION")
                        {

                            if ($debugme) {Write-Host "$(get-date) [WARNING] inside isolation/application policy with vpc count $($policy.data.vpcReferences.Count)" -ForegroundColor Yellow}
                            for ($i = 0; $i -lt $policy.data.vpcReferences.Count; $i++)
                            {
                                if ($debugme) {Write-Host "$(get-date) [WARNING] inside vpc count loop " -ForegroundColor Yellow}
                                if($policy.data.vpcReferences[$i] -eq $source_vpc_extId)
                                {
                                    $policy.data.vpcReferences[$i] = $target_vpc_uuid
                                    Write-Host "$(get-date) [INFO] The source vpc ($($source_vpc_extId)  and vpc reference vpc ($($policy.data.vpcReferences[$i])) in source spec are the same in $sourcePc" -ForegroundColor Green
                                }
                                else
                                {
                                    Write-Host "$(get-date) [WARNING] The source vpc ($($source_vpc_extId)  and vpc reference ($($policy.data.vpcReferences[$i])) in source spec are not the same in $sourcePc" -ForegroundColor Yellow
                                }

                            }

                        }

                    }
                }
                catch
                {
                    $saved_error = $_.Exception.Message
                    $error_code = ($saved_error -split " ")[3]
                    if ($error_code -eq "404")
                    {
                        Write-Host "$(get-date) [WARNING] The VPC $($vpc_name) does not exists in  Prism Central" -ForegroundColor Yellow
                        $missing_vpc_list.Add($vpc_name) | Out-Null
                        Continue
                    }
                    else
                    {
                        Write-Host "$saved_error" -ForegroundColor Yellow
                        Continue
                    }
                }
            }
            if ($missing_vpc_list)
            {#there are missing VPC on target
                Write-Host "$(get-date) [DATA] The following VPCs need to be added on $($targetPc):" -ForegroundColor White
                $missing_vpc_list
            }
            #endregion

            #TODO region create missing vpc on target
        }

        end {}
    }
#endregion


#region prepwork
    $HistoryText = @'
Maintenance Log
Date       By              Updates (newest updates at the top)
---------- -------------   ----------------------------------------------------
10/12/2024 pramod.singh   Initial release.

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
    $length = 600
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
        [System.Collections.ArrayList]$add_nsp_list = New-Object System.Collections.ArrayList($null)
        [System.Collections.ArrayList]$update_nsp_list = New-Object System.Collections.ArrayList($null)
        $compared_nsps = @()
        foreach ($nsp in $filtered_source_nsp_response)
        {#compare source with target
            if ($nsp.name -notin $compared_nsps)
            {#we haven't processed that policy yet
                if ($nsp.name -notin $filtered_target_nsp_response.name)
                {#policy exists on source but not on target -- CREATE scenario
                    Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) does not exist yet on target Prism Central $($targetPc)" -ForegroundColor Green
                    $add_nsp_list.Add($nsp) | Out-Null
                }
                else
                {#policy exists on source and on target -- UPDATE scenario
                    Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) exists on target Prism Central $($targetPc)" -ForegroundColor Green
                    $update_nsp_list.Add($nsp) | Out-Null
                }
                $compared_nsps += $nsp.name
            }
        }
        Write-Host "$(get-date) [DATA] There are $($add_nsp_list.count) Flow policies to be created on target Prism Central $($targetPc)" -ForegroundColor White

        Write-Host "$(get-date) [DATA] There are $($update_nsp_list.count) Flow policies to update on target Prism Central $($targetPc)" -ForegroundColor White

        #* Policies to remove ($remove_nsp_list)
        [System.Collections.ArrayList]$remove_nsp_list = New-Object System.Collections.ArrayList($null)
        $compared_nsps = @()
        foreach ($nsp in $filtered_target_nsp_response)
        {#compare target with source
            if ($nsp.name -notin $compared_nsps)
            {#we haven't processed that policy yet
                if ($nsp.name -notin $filtered_source_nsp_response.name)
                {#Policy exists on target but not on source
                    Write-Host "$(get-date) [INFO] Flow policy $($nsp.name) no longer exists on source Prism Central $($sourcePc)" -ForegroundColor Green
                    $remove_nsp_list.Add($nsp) | Out-Null
                }
                $compared_nsps += $nsp.name
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
                    #get all policies
                    $target_nsp_response = Get-MicrosegObjectList -pc $targetPc -object "policies"
                    $filtered_target_nsp_response = $target_nsp_response | Where-Object {$_.name -match "^$rename"}
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
                    $filter = "`$filter=isSystemDefined eq false"
                    $target_service_groups = Get-MicrosegObjectList -pc $targetPc -object "service-groups?$filter"
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

            #region process ADD
                if ($add_nsp_list)
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
                        Sync-Vpc -policy $policy
                        Sync-Categories -policy $policy
                        Sync-ServiceGroups -policy $policy
                        Sync-AddressGroups -policy $policy


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
                if ($remove_nsp_list)
                {#there are the policies to be removed
                    Write-Host ""
                    Write-Host "$(get-date) [STEP] Removing Flow policies" -ForegroundColor Magenta
                    foreach ($nsp in $remove_nsp_list)
                    {#process each policy to remove
                        #todo: for each category, figure out if it is used anywhere else in policies on source: if not, delete the category
                        #get policy on target using name to get ext id
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $filter = "`$filter=name eq '$($nsp.name)'"
                            $url = "https://{0}:9440{1}?{2}" -f $targetPc,$api_server_endpoint,$filter
                            $method = "GET"
                            $policy = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                        #delete policy on target
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$policy.data.extId
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
                if ($update_nsp_list)
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
                        }

                        Sync-Vpc -policy $policy
                        Sync-Categories -policy $policy
                        Sync-ServiceGroups -policy $policy
                        Sync-AddressGroups -policy $policy

                        #get policy on target using name to get ext id
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $filter = "`$filter=name eq '$($nsp.name)'"
                            $method = "GET"
                            $url = "https://{0}:9440{1}?{2}" -f $targetPc,$api_server_endpoint,$filter
                            $targetPolicy = Invoke-RateLimitedApiCall -method $method -url $url -credential $prismCredentials

                            $auth = @{ Authorization = "Basic "+ [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($prismCredentials.UserName):$($prismCredentials.GetNetworkCredential().password)")) }
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$targetPolicy.data.extId
                            $targetPolicyEtag = Invoke-WebRequest -Uri $url -SkipCertificateCheck -Headers $auth

                        #region add nsp on target
                            $api_server_endpoint = "/api/microseg/v4.0/config/policies"
                            $url = "https://{0}:9440{1}/{2}" -f $targetPc,$api_server_endpoint,$targetPolicy.data.extId
                            $method = "PUT"
                            $policyname = $policy.data.name
                            if($rename)
                            {
                                $policyname = $rename + "_" + $policy.data.name
                                Write-Host "$(Get-Date) [INFO] Updating Flow policy $($nsp.name) to $targetPc with new name $policyname" -ForegroundColor Cyan
                            }
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
                            $payload = (ConvertTo-Json $content -Depth 100)
                            $ntnx_req_id = New-Guid
                            $if_match = [System.String]($targetPolicyEtag.Headers.ETag)
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