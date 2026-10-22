> [!CAUTION]
> You need to use different synchronization scripts depending on which version of Flow Network Security you are using. Please read Nutanix [KB12253](https://portal.nutanix.com/page/documents/kbs/details?targetId=kA07V000000LXXdSAO) for more details.

# Invoke-FlowRulesSync.ps1:

The Invoke-FlowRulesSync.ps1 script can be used to synchronize Nutanix Flow Security policies and their related entities (categories, service groups and addresses) from one Prism Central instance to another.
This is useful when you replicate virtual machines from one availability zone to another and you want the Flow Security policies to apply immediately after failover without having to re-create them manually.

## What the script does

The script starts by retrieving objects from each Prism Central (PC) instance.  One PC instance is the source, and the other PC instance is the target. Synchronization occurs one way, from source to target.

The objects it retrieves in order are:

1. Flow Security policies (aka rules): from the `/api/nutanix/v3/network_security_rules/list` Prism Central v3 API endpoint
2. Flow Security service groups (aliases that contain one or more network ports which are used in rules): from the `/api/nutanix/v3/service_groups/list` Prism Central v3 API endpoint
3. Flow Security address groups (aliases that contain one or more IP addresses which are used in rules): from the `/api/nutanix/v3/address_groups/list` Prism Central v3 API endpoint

Note that to retrieve those objects, the script uses a function (Get-PrismCentralObjectList) which processes correctly pagination in the v3 API.  This means that it is not limited to the first 50 items of each object type but can scale to whatever PC supports.  This function also attempts to retrieve the API error code if the payload is not successfully returned.

Once all objects have been retrieved from both source and target and stored in variables, the script determines which rules must be:

1. _added_: because they exist on the source but not on the target
2. _removed_: because they exist on the target but no longer exist on the source
3. _updated_: because the contents of the rule (apart from object uuids) are different from the source and the target. Note that the reference is the source, so if an update is done manually on the target, it will get overwritten when the script runs.

Note that the only rules which are being considered are the ones that match the prefix specified with the **prefix** parameter.

Once the _add_, _remove_ and _update_ lists have been figured out, it proceeds to do just that in that exact order.

When rules are _added_, the script synchronized _categories_, _services groups_ and _address groups_ in that order by:

1. Figuring out which of those objects are being used in the rule (by looking at its payload content),
2. Finding out if that objects already exists on the target,
3. If the object does not already exist on the target, it creates it and figures out what the uuid of the resulting object is now on the target so that references can be updated in the payload of the rule to be created on that target PC instance.
4. If the object already exists, the uuid reference is also updated in the payload of the rule to be created on that target PC instance.

When rule are _removed_, any categories, service groups and address groups it was using are left behind on the target.

Rules are _updated_ when the source and target payloads do not match (other than uuids), so any type of change should be processed as the payload is updated with the correct uuid references and then applied as it is from source.

Note that thoughout execution, the script display timestamped output entries which are green for informational output, yellow for warning output, red for error output (which usually interrupt script execution), white for data and debug output (debug output can be triggered with the **debugme** script parameter) and light blue for things which are successfull (such as an API call).

## Technical requirements

While technically the script should work on any system running PowerShell 5.1 or above, it is strongly recommended to run PowerShell Core (v6 or above) as many cmdlets the script uses have enhanced functionality in PoSH core.
This means that the script can run on any Windows, Linux or MacOSX system which is running PowerShell core.

In this GitHub repository, the script does not require any external PowerShell module to run correctly. In other GitHub repositories, older versions of the script may require the installation of the _sbourdeaud_ PowerShell gallery module which contains the functions used in the script to make API calls.

## Script syntax

Syntax for the script can be shown using the `Get-Help ./Invoke-FlowRuleSync.ps1` command from a PowerShell prompt.

To handle scheduling and safe storage of credentials, the script uses PowerShell secure strings stored in the user profile directory. The secure string stored in the resulting text file can only be decrypted by the same user on that same workstation and therefore credential files are not transferrable from one workstation to another or from one user to another on the same workstation.
The script output shows where those files are stored (which varies based on the platform your workstation uses).

## Troubleshooting

The script can be ran with the **debugme** parameter to create additional output.
There is also a **log** parameter to create a log file in the working directory with the same output as displayed on the console.

When the script simply won't execute, this can be caused by various things:
1. Running the wrong PowerShell version (suggesting you use PowerShell core v6 or above)
2. Not being able to install dependencies (applies to some versions of the script) from the PowerShell gallery
3. Not being able to accept the Prism Central self-signed certificates (it should by default, but in some rare instances, it may be necessary to re-generate those self-signed certificates as they are perceived as invalid by the dotnet library)

Most of those reasons will be PowerShell or DotNet specific and may require troubleshooting those components.  PowerShell and DotNet troubleshooting is too vast a topic to cover here.

If the script runs correctly but does not produce the expected output, then the steps taken by the script should be reproduced manually to determine if there is an issue with Flow Security (for example, the rules and their objects are created successfully but not applied to virtual machines after failover). If you can create them manually and they still don't work as expected, then it is obviously not a script issue.

Between multiple script executions, it may be necessary to re-initialize your PowerShell session (by closing and re-opening your PowerShell prompt).  The script tries to clear variables once it is done executing, but when execution fails for whatever reason, some variables may be left behind in memory which may affect any subsequent execution.

# Invoke-FlowRuleVPCSyncNG.ps1:

The Invoke-FlowRuleVPCSyncNG.ps1 script synchronizes Nutanix Flow Network Security policies, and the categories, service groups, and address groups those policies use, from one Prism Central instance to another. It calls the Prism Central v4 APIs and supports policies whose scope is Global or a VPC. Use it when virtual machines are replicated to another availability zone and the Flow policies need to exist on the target before failover.

## What the script does

The script reads from a source Prism Central and writes to a target Prism Central. Synchronization is one way.

It lists these objects on both Prism Centrals, following pagination so the result is not limited to the first page:

1. Flow policies, from `/api/microseg/v4.0/config/policies`
2. Service groups, from `/api/microseg/v4.0/config/service-groups`
3. Address groups, from `/api/microseg/v4.0/config/address-groups`
4. Categories, from `/api/prism/v4.0.a2/config/categories`
5. VPCs, from `/api/networking/v4.0/config/vpcs`

Only policies whose names start with the **prefix** parameter are considered. Policies with scope `ALL_VLAN` are skipped.

With **-action sync**, the script then:

1. _Adds_ a policy that exists on the source and not on the target.
2. _Removes_ a policy that exists on the target, matches the prefix, and no longer exists on the source.
3. _Updates_ a policy that exists on both sides when the policy content differs.

Before a policy is created, the script creates any missing categories, service groups, and address groups, then rewrites the policy so it references those objects on the target. A category is matched by its key and value. A service group, address group, or VPC is matched by name. A system-defined service group is mapped when the target already has that name, and is not created. A VPC that is missing on the target is reported and is not created.

An update compares the policy body read from the source with the policy body read from the target. Identity fields such as `extId`, `creationTime`, `lastUpdateTime`, `createdBy`, and `projectExtId` are ignored, and the order of rules and reference lists does not matter. When something still differs, the script prints the field as a `[DATA]` line and updates the target. When the two bodies match, the policy is left unchanged.

On create, a rule named `Outbound default rule` is left out of the new policy when it is the stock rule Prism creates: outbound Allow All and allowed traffic All Traffic, with no service, category, or address selection of its own. Prism adds that rule for each secured group. A rule with the same name and custom entries is copied.

The **rename** parameter adds a prefix to policy, address group, and service group names on the target. Use it once, before enabling Entity Sync for Flow. The **delete** action requires that prefix and removes the renamed policies, address groups, and service groups from the target.

**MaxInFlight** is the number of Prism requests kept in flight for each Prism Central. It defaults to 5. A Prism Central that returns rate-limit responses repeatedly is lowered to 2 for the rest of the run, and that change is printed as a warning.

Console lines are timestamped. `[STEP]` is magenta and marks a section. `[INFO]` is green. `[WARNING]` is yellow. `[ERROR]` is red and stops the script. `[DATA]` and `[DEBUG]` are white. `[SUCCESS]` is light blue. Pass **debugme** for debug lines, and **log** to write the same console output to a transcript in the working directory.

## Technical requirements

The script runs on Windows PowerShell 5.1 and on PowerShell 7. PowerShell 7 is the better choice on Windows, Linux, and macOS. It does not require an external PowerShell module.

## Script syntax

Show the syntax with `Get-Help ./Invoke-FlowRuleVPCSyncNG.ps1`.

```powershell
.\Invoke-FlowRuleVPCSyncNG.ps1 -sourcePc pc1.local -targetPc pc2.local -prismCreds myadcreds -action sync -prefix NVD
```

**sourcePc** and **targetPc** are the IP address or fully qualified domain name of each Prism Central. **prismCreds** is the name of an encrypted credential file. If that file does not exist, the script prompts for credentials and saves them for the next run. If you omit **prismCreds**, the script prompts on every run. The credential file can be decrypted only by the same user on the same workstation. The script prints the directory it uses, which depends on the operating system.

**action** is `sync` or `delete`. **prefix** selects the source policies to synchronize. **rename** is the prefix added on the target. **MaxInFlight** accepts a value from 1 to 5.

## Troubleshooting

Pass **debugme** for additional console output, and **log** to keep a transcript in the working directory.

When the script will not start, check the PowerShell version and confirm the workstation trusts the Prism Central certificate. The script skips certificate validation for the Prism Central connection. A Prism Central certificate that .NET rejects can still stop the connection.

Start a new PowerShell process before running the script again in the same window after the script itself has been updated. The rate-limit gate is loaded once per process and cannot be replaced in that process.

If the script runs and the policies on the target are not what you expect, try and create the same policy manually in Prism Central: a result that fails the same way outside the script is a Flow configuration issue rather than a script issue. Categories, service groups, and address groups used by a removed policy are left on the target. A missing VPC must exist on the target before a VPC-scoped policy can be synchronized.

