<#
	.SYNOPSIS
        Gives access to AAD User/Group on a Azure SQL database using Service Principal through MSAL authentication.

        !!! DOES NOT SUPPORT SETTING ACCESS TO MORE THAN ONE DB AT A TIME!!!
        !!!         IF NEEDED ADD THIS FEATURE                           !!!

        TODO: More dynamic way of handling setting custom access levels

    .DESCRIPTION
        * For this to work the agent running the tasks public IP must be added to FW exception list for Azure SQL DB
        * The AAD Service Principal tied to AzD service connection set on task must be added as Azure SQL Server Admin either directly
          or through membership in AAD group

    .NOTES
        AUTHOR: Morten Lerudjordet
#>
[CmdletBinding()]
param()

# Use bundled version of task SDK
if ( -not (Get-Module -Name "VSTSTaskSdk") )
{
    Write-Host -Object "##[command]Importing AzD Task SDK"
    Import-Module -Name "$PSScriptRoot\ps_modules\VstsTaskSdk"

}
else
{
    Write-Host -Object "##[command]AzD Task SDK module already imported"
}

try
{
    # Start session tracing
    Trace-VstsEnteringInvocation $MyInvocation

    #region AzD Task inputs
    # Import needed resources
    Write-Host -Object "##[command]Importing all task inputs"
    Import-VstsLocStrings -LiteralPath "$PSScriptRoot\Task.json"

    # Get Task inputs
    [string]$AzSQLServerHostName = Get-VstsInput -Name AzSQLServerHostName -Require
    [string]$AzSQLDBName = Get-VstsInput -Name AzSQLDBName -Require
    [string]$QueryTimeout = Get-VstsInput -Name QueryTimeout
    [string]$Encrypt = Get-VstsInput -Name Encrypt
    [string]$DBrwAADObjectName = Get-VstsInput -Name DBrwAADObjectName -Require
    [string]$DBrwAADObjectID = Get-VstsInput -Name DBrwAADObjectID -Require
    [string]$DBownerAADObjectName = Get-VstsInput -Name DBownerAADObjectName -Require
    [string]$DBownerAADObjectID = Get-VstsInput -Name DBownerAADObjectID -Require

    # Get task service connection details
    $serviceName = Get-VstsInput -Name AzDConnectedServiceNameARM -Require
    Write-Host -Object "##[command]Retrieving service connection details from AzD"
    $endPoint = Get-VstsEndpoint -Name $serviceName -Require

    Write-Host -Object "Service Connection Endpoint type: $($endPoint.Auth.Scheme)"
    # Get service principal id and secret
    if ( $endPoint.Auth.Scheme -eq 'ServicePrincipal' )
    {
        Write-Host -Object "##[command]Building Credential object from service connection details"
        $psCredential = New-Object System.Management.Automation.PSCredential(
            $EndPoint.Auth.Parameters.ServicePrincipalId,
            (ConvertTo-SecureString $endPoint.Auth.Parameters.ServicePrincipalKey -AsPlainText -Force))
    }
    else
    {
        Write-Error -Message "This task only support ARM service principal to authenticate against Azure SQL" -ErrorAction Stop
    }
    #endregion
    #region Verify variable content
    if (-not $QueryTimeout)
    {
        Write-Host -Object "##[command]Setting QueryTimeout to default 30s"
        $QueryTimeout = "30"
    }
    if (-not $Encrypt)
    {
        Write-Host -Object "##[command]Setting Encrypt to default true"
        $Encrypt = "true"
    }
    if(-not $AzSQLServerHostName)
    {
        Write-Error -Message "Missing Azure SQL Server Host Name from input" -ErrorAction Continue -ErrorVariable oErr
    }
    if(-not $AzSQLDBName)
    {
        Write-Error -Message "Missing Azure SQL Server DB Name from input" -ErrorAction Continue -ErrorVariable oErr
    }
    if(-not $DBrwAADObjectName)
    {
        Write-Error -Message "Missing AAD User/Group Name from input to be given Read/Write Access" -ErrorAction Continue -ErrorVariable oErr
    }
    if(-not $DBrwAADObjectID)
    {
        Write-Error -Message "Missing AAD User/Group ID from input to be given Read/Write Access" -ErrorAction Continue -ErrorVariable oErr
    }
    if(-not $DBownerAADObjectName)
    {
        Write-Error -Message "Missing AAD User/Group Name from input to be given DBowner Access" -ErrorAction Continue -ErrorVariable oErr
    }
    if(-not $DBownerAADObjectID)
    {
        Write-Error -Message "Missing AAD User/Group ID from input to be given DBowner Access" -ErrorAction Continue -ErrorVariable oErr
    }
    if($oErr)
    {
        Write-Error -Message "One or more required input variables are missing" -ErrorAction Stop
    }
    #endregion

    #region Internal Variables
    $PSGalleryRepositoryName = "PSGallery"
    $ModuleName = "MSAL.PS"
    $MSALScope = "https://database.windows.net//.default"
    $SQLConnectionString = "Data Source=$AzSQLServerHostName;Initial Catalog=$AzSQLDBName;Encrypt=$Encrypt;Connect Timeout=$QueryTimeout"

    $AllAADobjects = @(
        [pscustomobject]@{  ObjectName     = $DBrwAADObjectName;
                            ObjectID       = $DBrwAADObjectID ;
                            DBAccessLevel     = "rw"
                        },
        [pscustomobject]@{  ObjectName     = $DBownerAADObjectName;
                            ObjectID       = $DBownerAADObjectID;
                            DBAccessLevel     = "dbowner"
                        }
    )
    #endregion

    Write-Host -Object "===================================TaskInPuts==================================="
    Write-Host -Object "Connecting to Azure SQL using:"
    Write-Host -Object "Azure SQL Server Host Name:             $AzSQLServerHostName"
    Write-Host -Object "Azure SQL DB Name:                      $AzSQLDBName"
    Write-Host -Object "Query timeout:                          $QueryTimeout"
    Write-Host -Object "Encrypt connection:                     $Encrypt"
    Write-Host -Object "AAD User/Group Name RW Access:          $DBrwAADObjectName"
    Write-Host -Object "AAD User/Group Object ID RW Access:     $DBrwAADObjectID"
    Write-Host -Object "AAD User/Group Name Owner Access:       $DBownerAADObjectName"
    Write-Host -Object "AAD User/Group Object ID Owner Access:  $DBownerAADObjectID"
    Write-Host -Object "=================================EndTaskInputs================================="

    #region Powershell Module Repository Verification
    $Repositories = Get-PSRepository -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed to get registered repository information" -ErrorAction Stop
    }
    # Checking if PSGallery repository is available
    if(-not ($Repositories.Name -match $PSGalleryRepositoryName) )
    {
        Write-Host -Object "Adding $PSGalleryRepositoryName repository and setting it to trusted"
        Register-PSRepository -Name $PSGalleryRepositoryName -SourceLocation $PSGalleryRepositoryURL -PublishLocation $PSGalleryRepositoryURL -InstallationPolicy 'Trusted' -ErrorAction Continue -ErrorVariable oErr
        if($oErr)
        {
            Write-Host -Object "##vso[task.logissue type=error;]Failed to add $PSGalleryRepositoryName as trusted"
            Write-Error -Message "Failed to add $PSGalleryRepositoryName as trusted" -ErrorAction Stop
        }
    }
    else
    {
        if( (Get-PSRepository -Name $PSGalleryRepositoryName).InstallationPolicy -eq "Untrusted" )
        {
            Write-Host -Object "Trusting $PSGalleryRepositoryName repository"
            Set-PSRepository -Name $PSGalleryRepositoryName -InstallationPolicy 'Trusted' -ErrorAction Continue -ErrorVariable oErr
            if($oErr)
            {
                Write-Host -Object "##vso[task.logissue type=error;]Failed to set $PSGalleryRepositoryName as trusted"
                Write-Error -Message "Failed to set $PSGalleryRepositoryName as trusted" -ErrorAction Stop
            }
        }
        else
        {
            Write-Host -Object "$PSGalleryRepositoryName is already Trusted"
        }
    }
    #endregion

    # TODO: Clean up old version of a module

    #region Module version check
    $ModulesToCheck = @(
        [pscustomobject]@{ModuleName = $MSALModuleName;Update = "";NewVersion= "";CurrentVersion = "NA"}
    )
    foreach($Module in $ModulesToCheck)
    {
        if(-not (Get-Module -Name $($Module.ModuleName) -ListAvailable -ErrorAction Stop) )
        {
            # Force install of module as it does not exist on agent
            $Module.Update = $true
            $Module.NewVersion = (Find-Module -Name $($Module.ModuleName) -ErrorAction Stop).Version
        }
        else
        {
            $Module.Update = [version]($NewModuleVersion = Find-Module -Name $($Module.ModuleName) -ErrorAction Stop).Version -gt `
                             [version]($CurrentModuleVersion = Get-Module -Name $($Module.ModuleName) -ListAvailable -ErrorAction Stop | Sort-Object -Property Version -Descending | Select-Object -First 1).Version
            if($NewModuleVersion)
            {
                $Module.NewVersion = $NewModuleVersion.Version.ToString()
            }
            if($CurrentModuleVersion)
            {
                $Module.CurrentVersion = $CurrentModuleVersion.Version.ToString()
            }
        }
    }
    #endregion
    #region Install Modules
    foreach($Module in $ModulesToCheck)
    {
        Write-Host -Object "Current version: $($Module.CurrentVersion) of module: $($Module.ModuleName)"

        if($Module.Update)
        {
            Write-Host -Object "Installing latest version: $($Module.NewVersion) of module: $($Module.ModuleName)"
            Write-Host -Object "##[command]Install-Module -Name $($Module.ModuleName) -Scope CurrentUser -AllowClobber -Force -Repository $PSGalleryRepositoryName -AcceptLicense"
            Install-Module -Name $($Module.ModuleName) -Scope CurrentUser -AllowClobber -Force -Repository $PSGalleryRepositoryName -AcceptLicense -ErrorAction Continue -ErrorVariable oErr
            if ($oErr)
            {
                if ($oErr -like "*No match was found for the specified search criteria and module name*")
                {
                    Write-Error -Message "Failed to find $($Module.ModuleName) in repository: $PSGalleryRepositoryName" -ErrorAction Continue
                }
                else
                {
                    Write-Error -Message "Failed to install module: $($Module.ModuleName) from $PSGalleryRepositoryName" -ErrorAction Continue
                }
                $oErr = $Null
            }
            else
            {
                Write-Host -Object "Installed new version: $($Module.NewVersion) of module: $($Module.ModuleName)"
            }
        }
        else
        {
            Write-Host -Object "Latest version: $($Module.NewVersion) of $($Module.ModuleName) already installed"
        }
    }
    #endregion

    #region Import Modules
    foreach($Module in $ModulesToCheck)
    {
        Write-Host -Object "##[command]Import-Module -Name $($Module.ModuleName) -Global"
        Import-Module -Name $($Module.ModuleName) -Global -ErrorAction Continue -ErrorVariable oErr
        if ($oErr)
        {
            Write-Error -Message "Failed to import module: $($Module.ModuleName)" -ErrorAction Stop
        }
    }
    #endregion

    #region Get MSAL access token
    Write-Verbose -Message "##[command]Constructing MSAL token from AAD service principal: $($psCredential.UserName) targeting Tenant: $($Endpoint.Auth.Parameters.TenantId)"
    $MSALtoken = Get-MsalToken -ClientId $($psCredential.UserName) -ClientSecret $psCredential.Password `
        -TenantId $($Endpoint.Auth.Parameters.TenantId) -Scopes $MSALScope -ErrorAction Continue -ErrorVariable oErr
    if ($oErr)
    {
        Write-Error -Message "Failed get MSAL token from endpoint" -ErrorAction Stop
    }
    #endregion

    #region SQL Connection
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $SQLConnectionString
    $SqlConnection.AccessToken = $MSALtoken.AccessToken

    try
    {
        Write-Host -Object "##[command]Opening DB connection to DB: $AzSQLDBName on server: $AzSQLServerHostName"
        $SqlConnection.Open()
    }
    catch
    {
        Write-Error -Message "Failed to open connection to DB: $AzSQLDBName on server: $AzSQLServerHostName" -ErrorAction Stop
    }
    #endregion
    #region Set access
    foreach($AADobject in $AllAADobjects)
    {
        if($AADobject.ObjectName -and $AADobject.ObjectID)
        {
            #region SQL Queries
            # NOTE: do not indent strings below or query will break
            $ExistQuery = @"
SELECT name
FROM sys.database_principals
WHERE name = '$($AADobject.ObjectName)'
"@

            $GetSIDQuery = @"
DECLARE @sid
uniqueidentifier=cast('$($AADobject.ObjectID)' as uniqueidentifier)
select cast(@sid as varbinary(max))
"@

            # Set RW or db_owner
            switch ($AADobject.DBAccessLevel)
            {
                "rw"
                {
                $AccessQuery = @"
ALTER ROLE db_datareader ADD MEMBER [$($AADobject.ObjectName)];
ALTER ROLE db_datawriter ADD MEMBER [$($AADobject.ObjectName)];
"@
                }
                "dbowner"
                {
                    $AccessQuery = "ALTER ROLE db_owner ADD MEMBER [$($AADobject.ObjectName)];"
                }
            }
            #endregion

            $Result = $null
            # Reuse connection if already created
            if(-not $SqlCommand)
            {
                $SqlCommand = New-Object -TypeName System.Data.SqlClient.SqlCommand($ExistQuery, $SqlConnection)
            }
            else
            {
                $SqlCommand.CommandText = $ExistQuery
            }
            # Check first if user/group already created in DB
            try
            {
                Write-Host -Object "##[command]Executing Query to check if object is already in DB"
                $Result = $SqlCommand.ExecuteScalar()
            }
            catch
            {
                Write-Error -Message "Failed to query DB if user/group already exists" -ErrorAction Stop
            }
            if (-not $Result)
            {
                $SqlCommand.CommandText = $GetSIDQuery
                try
                {
                    Write-Host -Object "##[command]Executing Query to get SID from DB to use when creating user/group object in DB"
                    $Result = $SqlCommand.ExecuteScalar()
                }
                catch
                {
                    Write-Error -Message "Failed to query for SID identifier from database" -ErrorAction Stop
                }
                if ($Result)
                {
                    # Flatten array and convert values to HEX
                    $hexSID = -join $Result.ForEach( { $_.ToString("X2") })
                    $hexSID = "0x$hexSID"
                }
                else
                {
                    Write-Error -Message "Failed to query for SID identifier from database" -ErrorAction Stop
                }
                if ($hexSid)
                {
                    # SID needs to be populated before query is constructed
                    $CreateUserQuery = @"
IF NOT EXISTS(SELECT name FROM sys.database_principals WHERE name = N'$($AADobject.ObjectName)')
BEGIN
CREATE USER [$($AADobject.ObjectName)] WITH SID = $hexSID, type = E;
END ELSE BEGIN
    SELECT name FROM sys.database_principals WHERE name = N'$($AADobject.ObjectName)'
END
"@
                    $SqlCommand.CommandText = $CreateUserQuery
                    try
                    {
                        Write-Host -Object "##[command]Executing Query to create object in DB"
                        # Create query from SID value to create user in DB with type AAD
                        $Result = $SqlCommand.ExecuteScalar()
                    }
                    catch
                    {
                        Write-Error -Message "Failed to create AAD user/group from SID" -ErrorAction Stop
                    }
                }
                else
                {
                    Write-Error -Message "Failed to query for SID identifier from database" -ErrorAction Stop
                }
                # If result user / group already exists
                if (-not $Result)
                {
                    Write-Host -Object "AAD User/Group: $($AADobject.ObjectName) added to DB: $AzSQLDBName on SQL Server: $AzSQLServerHostName"
                    $SqlCommand.CommandText = $AccessQuery
                    try
                    {
                        Write-Host -Object "##[command]Executing Query to set access level in DB"
                        $Result = $SqlCommand.ExecuteScalar()
                    }
                    catch
                    {
                        Write-Error -Message "Failed to sett access level: $($AADobject.DBAccessLevel) for AAD User/Group: $($AADobject.ObjectName)" -ErrorAction Stop
                    }
                    Write-Host -Object "AAD User/Group: $($AADobject.ObjectName) access set to: $($AADobject.DBAccessLevel)"
                }
                else
                {
                    Write-Host -Object "AAD User/Group: $($AADobject.ObjectName) already exists in DB."
                }
            }
            else
            {
                Write-Host -Object "AAD User/Group: $($AADobject.ObjectName) already exists in DB. Changing access level on existing object not supported"
            }
        }
        else
        {
            Write-Warning -Message "No AAD object Name and Id from input for access level: $($AADobject.DBAccessLevel)"
        }
        #endregion
    }
}
catch
{
    if ($_.Exception.Message)
    {
        Write-Error -Message "$($_.Exception.Message)" -ErrorAction Continue
        Write-Host -Object "##[error]$($_.Exception.Message)"
    }
    else
    {
        Write-Error -Message "$($_.Exception)" -ErrorAction Continue
        Write-Host -Object "##[error]$($_.Exception)"
    }
}
finally
{
    # Close DB connection
    if ($SqlConnection -and $SqlConnection.State -eq "Open" )
    {
        # dispose connection object
        $SqlConnection.Dispose()
        Write-Host -Object "##[command]DB Connection Disposed"
    }
    # Stop session tracing
    Trace-VstsLeavingInvocation $MyInvocation
}