﻿<#
.SYNOPSIS
    Get information about Azure Automation accounts and the content.

.DESCRIPTION
    This script will enumerate Automation accounts and capture information about
    the account as well as the contents under the account.

    - Details about the Automation account.
    - Details about the Module assets.
    - Details about the Variable assets.
    - Details about the Connection assets.
    - Details about the Credential assets.
    - Details about the Schedule assets.
    - Details about the scheduled runbooks (schedules linked to runbooks).
    - Summary details about each runbook.
    - Export of each runbook.
    - Summary details of last N jobs (see NumberOfJobs parameter).
    - Summary details of job stream data for last N jobs.
    - Details of job stream values data (Error streams only by default, see 
      IncludeAllStreamValues parameter).

    Results will be written to $env:TEMP\AzureAutomationDiagnostics\yyyyMMddHHmmss.
    The script will open File Explorer to that location when it has completed.

.PARAMETER AutomationAccountNames
    Optional.  An array of Automation account names to be processed.  By default
    all Automation accounts in the subscription will be included.

.PARAMETER RunbookNames
    Optional.  An array of Runbook names to be processed.  By default all Runbooks
    in each Automation account are included.  Since Runbooks are referenced by
    name, if the same Runbook name exists in more than one Automation account it
    will be processed in each account.

.PARAMETER JobIds
    Optional.  An array of Job identifiers to be processed.  By default the last N
    Jobs in each Automation account are included (see NumberOfJobs parameter).  If
    Job identifiers are provided, then only Jobs matching those identifiers will be
    processed even across all Automation accounts.  Result may be that some 
    Automation accounts have no Jobs included in the results because they didn't 
    have any matching Jobs.

.PARAMETER IncludeAllStreamValues
    Optional.  By default, stream values are only included for "Error" streams.  The
    summary of all job streams is captured, but capturing the full values of streams
    is a very performance intensive process as it has to make a web service call for
    every stream.

    THIS PARAMETER CAN CAUSE THE SCRIPT TO TAKE A VERY LONG TIME TO COMPLETE IF OTHER
    PARAMETERS ARE NOT INCLUDED TO SCOPE DOWN THE RUNBOOKS/JOBS THAT ARE PROCESSED.

.PARAMETER NumberOfJobs
    Optional.  By default, the last 20 jobs for each Automation account are
    processed.  This parameter defines the last N jobs that will be processed.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1

    The above will process all Automation accounts, Runbooks and last N Jobs in the 
    chosen subscription.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1 -AutomationAccounts 'MyAutomationAccount'

    The above will process all Runbooks and last N Jobs in the Automation account
    named 'MyAutomationAccount' only.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1 -AutomationAccounts @('MyFirstAutomationAccount','MySecondAutomationAccount') -NumberOfJobs 20 -IncludeAllStreamValues

    The above will process all Runbooks and last 20 Jobs in the Automation accounts
    'MyFirstAutomationAccount' and 'MySecondAutomationAccount' and will include full
    stream values for all stream types for each of the last 20 Jobs.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1 -RunbookNames 'MyRunbook'

    The above will process only runbooks named 'MyRunbook' in each of the Automation
    accounts and will only include Job results for that runbook.  Summary details
    about all the Automation accounts will still be included such as Module and
    Schedule assets.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1 -AutomationAccountNames 'MyAutomationAccount' -RunbookNames @('MyFirstRunbook','MySecondRunbook')
    
    The above will process only Runbooks named 'MyFirstRunbook' and 'MySecondRunbook'
    in the Automation account 'MyAutomationAccount'.  Summary details about the
    Automation account 'MyAutomationAccount' will also be included.

.EXAMPLE
    .\Get-AutomationDiagnosticResults.ps1 -AutomationAccountNames 'MyAutomationAccount' -RunbookName 'MyRunbook' -JobIds '12345678-9012-3456-7890-123456789012'

    The above will process only the Job with the specified id and will only include
    information about the Runbook named 'MyRunbook' and only the Automation account
    named 'MyAutomationAccount'.

.NOTES
    AUTHOR  : Jeffrey Fanjoy
    LASTEDIT: 12/09/2016

    Requires: AzureRM.profile
    Requires: AzureRM.automation
    Requires: AzureRM.resources
#>

Param (
    [Parameter(Mandatory=$false)]
    [string[]] $AutomationAccountNames,
    [Parameter(Mandatory=$false)]
    [string[]] $RunbookNames,
    [Parameter(Mandatory=$false)]
    [string[]] $JobIds,
    [Parameter(Mandatory=$false)]
    [switch] $IncludeAllStreamValues,
    [Parameter(Mandatory=$false)]
    [int] $NumberOfJobs = 20
)

    Function VerifyModules {
        # Make sure required modules are available
        Write-Host ("Checking for required modules.")
        $RequiredModules = @('AzureRM.profile', 'AzureRM.automation', 'AzureRM.resources')
        $ModuleMissing = $false
        foreach ($Module in $RequiredModules) {
            Write-Host ("Checking for module '{0}'." -f $Module)
            if (Get-Module -Name $Module -ListAvailable) {
                Write-Host ("Importing module '{0}'." -f $Module)
                Import-Module $Module
            } else {
                Write-Host ("Module '{0}' was not found." -f $Module) -ForegroundColor Red
                $ModuleMissing = $true 
            }
        }
    
        if ($ModuleMissing -eq $true) { throw 'At least one required module was not found.  See "https://azure.microsoft.com/en-us/documentation/articles/powershell-install-configure/" for details on how to install Azure modules for PowerShell.' }
    }

    Function CreateFolder {
        Param (
            [Parameter(Mandatory=$true)]
            [string] $FolderName
        )

        if (!(Test-Path -Path $FolderName)) {
            Write-Host ("Creating folder '{0}'." -f $FolderName)
            $null = New-Item -ItemType Directory -Path $FolderName
        }
    }

    Function CreateResultFolder {
        Write-Host ("Creating folders for diagnostic results.")
        $script:BasePath = $env:TEMP
        Write-Host ("Setting BasePath = {0}." -f $BasePath)
        $script:AzureAutomationDiagBasePath = ("{0}\AzureAutomationDiagnostics" -f $BasePath)
        Write-Host ("Setting azure automation base diagnostics path '{0}'." -f $AzureAutomationDiagBasePath)
        CreateFolder $AzureAutomationDiagBasePath
        $script:AzureAutomationDiagResultPath = ("{0}\{1}" -f $AzureAutomationDiagBasePath, (Get-Date -Format 'yyyyMMddHHmmss'))
        Write-Host ("Setting azure automation diagnostics results folder '{0}'." -f $AzureAutomationDiagResultPath)
        CreateFolder $AzureAutomationDiagResultPath
    }

    Function WriteModuleDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of modules imported into Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $ModuleList = Get-AzureRmAutomationModule -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($ModuleList | Measure-Object).Count -eq 0) {
            Write-Host ("No modules found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' module(s) in Automation account '{1}'." -f ($ModuleList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            $Modules = @()
            $ModuleList | ForEach-Object {
                Write-Host ("Getting details for module '{0}'." -f $_.Name)
                $Modules += Get-AzureRmAutomationModule -Name $_.Name -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName
            }
            Write-Host ("Writing module summary to '{0}\ModulesSummary.txt'." -f $ResultsFolder)
            $Modules | Sort-Object Name | Select-Object Name, IsGlobal, ProvisioningState, Version, SizeInBytes, ActivityCount, CreationTime, LastModifiedTime | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\ModulesSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing module summary in CSV to '{0}\ModulesSummary.csv'." -f $ResultsFolder)
            $Modules | Sort-Object Name | Select-Object Name, IsGlobal, ProvisioningState, Version, SizeInBytes, ActivityCount, CreationTime, LastModifiedTime | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\ModulesSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteRunbookDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )
        
        Write-Host ("Retrieving list of runbooks imported into Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        if ($RunbookNames) {
            $RunbookNames | ForEach-Object { Write-Host ("Scoping results to include runbook named '{0}'." -f $_) }
            $RunbooksList = Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName | Where-Object { $RunbookNames -contains $_.Name }
        } else {
            $RunbooksList = Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        }
        if (($RunbooksList | Measure-Object).Count -eq 0) {
            Write-Host ("No runbooks found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' runbook(s) in Automation account '{1}'." -f ($RunbooksList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            $Runbooks = @()
            $RunbooksList | ForEach-Object {
                Write-Host ("Getting details for runbook '{0}'." -f $_.Name)
                $Runbooks += Get-AzureRmAutomationRunbook -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName -Name $_.Name
            }
            Write-Host ("Writing runbook summary to '{0}\RunbooksSummary.txt'." -f $ResultsFolder)
            $Runbooks | Sort-Object Name | Select-Object Name, RunbookType, State, JobCount, Location, CreationTime, LastModifiedTime, LastModifiedBy, LogVerbose, LogProgress | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\RunbooksSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing runbook summary in CSV to '{0}\RunbooksSummary.csv'." -f $ResultsFolder)
            $Runbooks | Sort-Object Name | Select-Object Name, RunbookType, State, JobCount, Location, CreationTime, LastModifiedTime, LastModifiedBy, LogVerbose, LogProgress | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\RunbooksSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing runbook details in JSON to '{0}\RunbooksJSON.txt'." -f $ResultsFolder)
            $Runbooks | Sort-Object Name | ConvertTo-Json -Depth 10 | Out-File ("{0}\RunbooksJSON.txt" -f $ResultsFolder) -Encoding ascii -Force

            # Exporting runbooks
            $RunbookExportsResultFolder = ("{0}\RunbookExports" -f $AutomationAccountResultFolder)
            CreateFolder $RunbookExportsResultFolder
            $RunbookExportsPublishedResultFolder = ("{0}\Published" -f $RunbookExportsResultFolder)
            CreateFolder $RunbookExportsPublishedResultFolder
            $RunbookExportsDraftResultFolder = ("{0}\Draft" -f $RunbookExportsResultFolder)
            CreateFolder $RunbookExportsDraftResultFolder
            Write-Host ("Exporting published runbooks to folder '{0}'." -f $RunbookExportsPublishedResultFolder)
            $Runbooks | Where-Object { $_.State -ne 'New' } | ForEach-Object {
                Write-Host ("Exporting published version of runbook '{0}' to '{1}'." -f $_.Name, $RunbookExportsPublishedResultFolder)
                $null = Export-AzureRmAutomationRunbook -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName -Name $_.Name -Slot Published -OutputFolder $RunbookExportsPublishedResultFolder -Force
            }
            Write-Host ("Exporting draft runbooks to folder '{0}'." -f $RunbookExportsPublishedResultFolder)
            $Runbooks | Where-Object { $_.State -ne 'Published' } | ForEach-Object {
                Write-Host ("Exporting draft version of runbook '{0}' to '{1}'." -f $_.Name, $RunbookExportsDraftResultFolder)
                $null = Export-AzureRmAutomationRunbook -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName -Name $_.Name -Slot Draft -OutputFolder $RunbookExportsDraftResultFolder -Force
            }
        }
    }

    Function WriteScheduleDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of schedules in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $ScheduleList = Get-AzureRmAutomationSchedule -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($ScheduleList | Measure-Object).Count -eq 0) {
            Write-Host ("No schedules found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' schedule(s) in Automation account '{1}'." -f ($ScheduleList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            $Schedules = @()
            $ScheduleList | ForEach-Object {
                Write-Host ("Getting details for schedule '{0}'." -f $_.Name)
                $Schedules += Get-AzureRmAutomationSchedule -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName -Name $_.Name
            }
            Write-Host ("Writing schedule summary to '{0}\SchedulesSummary.txt'." -f $ResultsFolder)
            $Schedules | Sort-Object Name | Select-Object Name, IsEnabled, StartTime, ExpiryTime, NextRun, Interval, Frequency, TimeZone, CreationTime, LastModifiedTime | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\SchedulesSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing schedule summary in CSV to '{0}\SchedulesSummary.csv'." -f $ResultsFolder)
            $Schedules | Sort-Object Name | Select-Object Name, IsEnabled, StartTime, ExpiryTime, NextRun, Interval, Frequency, TimeZone, CreationTime, LastModifiedTime | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\SchedulesSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing schedule details in JSON to '{0}\SchedulesJSON.txt'." -f $ResultsFolder)
            $Schedules | Sort-Object Name | ConvertTo-Json -Depth 10 | Out-File ("{0}\SchedulesJSON.txt" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteScheduledRunbookDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of scheduled runbooks in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $ScheduledRunbookList = Get-AzureRmAutomationScheduledRunbook -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($ScheduledRunbookList | Measure-Object).Count -eq 0) {
            Write-Host ("No scheduled runbooks found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' scheduled runbook(s) in Automation account '{1}'." -f ($ScheduledRunbookList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            $ScheduledRunbooks = @()
            $ScheduledRunbookList | ForEach-Object {
                Write-Host ("Getting details for scheduled runbook job schedule id '{0}' of schedule '{1}' against runbook '{2}'." -f $_.JobScheduleId, $_.ScheduleName, $_.RunbookName)
                $ScheduledRunbooks += Get-AzureRmAutomationScheduledRunbook -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName -JobScheduleId $_.JobScheduleId
            }
            Write-Host ("Writing scheduled job summary to '{0}\ScheduledRunbooksSummary.txt'." -f $ResultsFolder)
            $ScheduledRunbooks | Sort-Object ScheduleName | Select-Object ScheduleName, RunbookName, JobScheduleId, RunOn | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\ScheduledRunbooksSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing scheduled job summary in CSV to '{0}\ScheduledRunbooksSummary.csv'." -f $ResultsFolder)
            $ScheduledRunbooks | Sort-Object ScheduleName | Select-Object ScheduleName, RunbookName, JobScheduleId, RunOn | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\ScheduledRunbooksSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing scheduled job details in JSON to '{0}\ScheduledRunbooksJSON.txt'." -f $ResultsFolder)
            $ScheduledRunbooks | Sort-Object ScheduleName | ConvertTo-Json -Depth 10 | Out-File ("{0}\ScheduledRunbooksJSON.txt" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteVariableDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of variables in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $AutomationVariables = Get-AzureRmAutomationVariable -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($AutomationVariables | Measure-Object).Count -eq 0) {
            Write-Host ("No variables found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' variable(s) in Automation account '{1}'." -f ($AutomationVariables | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            Write-Host ("Writing variables summary to '{0}\VariablesSummary.txt'." -f $ResultsFolder)
            $AutomationVariables | Sort-Object Name | Select-Object Name, Encrypted, Value, CreationTime, LastModifiedTime, Description | Format-Table -AutoSize | Out-String -Width 8000 | Out-File ("{0}\VariablesSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing variables summary in CSV to '{0}\VariablesSummary.csv'." -f $ResultsFolder)
            $AutomationVariables | Sort-Object Name | Select-Object Name, Encrypted, Value, CreationTime, LastModifiedTime, Description | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\VariablesSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteCredentialDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of credentials in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $AutomationCredentials = Get-AzureRmAutomationCredential -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($AutomationCredentials | Measure-Object).Count -eq 0) {
            Write-Host ("No credentials found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' credential(s) in Automation account '{1}'." -f ($AutomationCredentials | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            Write-Host ("Writing credentials summary to '{0}\CredentialsSummary.txt'." -f $ResultsFolder)
            $AutomationCredentials | Sort-Object Name | Select-Object Name, UserName, CreationTime, LastModifiedTime, Description | Format-Table -AutoSize | Out-String -Width 8000 | Out-File ("{0}\CredentialsSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing credentials summary in CSV to '{0}\CredentialsSummary.csv'." -f $ResultsFolder)
            $AutomationCredentials | Sort-Object Name | Select-Object Name, UserName, CreationTime, LastModifiedTime, Description | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\CredentialsSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteCertificateDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of certificates in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $AutomationCertificates = Get-AzureRmAutomationCertificate -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($AutomationCertificates | Measure-Object).Count -eq 0) {
            Write-Host ("No certificates found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' certificate(s) in Automation account '{1}'." -f ($AutomationCertificates | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            Write-Host ("Writing certificates summary to '{0}\CertificatesSummary.txt'." -f $ResultsFolder)
            $AutomationCertificates | Sort-Object Name | Select-Object Name, Exportable, ExpiryTime, Thumbprint, CreationTime, LastModifiedTime, Description | Format-Table -AutoSize | Out-String -Width 8000 | Out-File ("{0}\CertificatesSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing certificates summary in CSV to '{0}\CertificatesSummary.csv'." -f $ResultsFolder)
            $AutomationCertificates | Sort-Object Name | Select-Object Name, Exportable, ExpiryTime, Thumbprint, CreationTime, LastModifiedTime, Description | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\CertificatesSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteConnectionDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of connections in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        $ConnectionList = Get-AzureRmAutomationConnection -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName
        if (($ConnectionList | Measure-Object).Count -eq 0) {
            Write-Host ("No connections found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            Write-Host ("Found '{0}' connection(s) in Automation account '{1}'." -f ($ConnectionList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            $Connections = @()
            $ConnectionList | ForEach-Object {
                Write-Host ("Getting details for connection '{0}'." -f $_.Name)
                $Connections += Get-AzureRmAutomationConnection -ResourceGroupName $_.ResourceGroupName -AutomationAccountName $_.AutomationAccountName -Name $_.Name
            }
            Write-Host ("Writing connection summary to '{0}\ConnectionsSummary.txt'." -f $ResultsFolder)
            $Connections | Sort-Object Name | Select-Object Name, ConnectionTypeName, CreationTime, LastModifiedTime | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\ConnectionsSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing connection summary in CSV to '{0}\ConnectionsSummary.csv'." -f $ResultsFolder)
            $Connections | Sort-Object Name | Select-Object Name, ConnectionTypeName, CreationTime, LastModifiedTime | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\ConnectionsSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing connection details in JSON to '{0}\ConnectionsJSON.txt'." -f $ResultsFolder)
            $Connections | Sort-Object Name | ConvertTo-Json -Depth 10 | Out-File ("{0}\ConnectionsJSON.txt" -f $ResultsFolder) -Encoding ascii -Force
        }
    }

    Function WriteJobDetails {
        Param (
            [Parameter(Mandatory=$true)]
            [object] $AutomationAccount,
            [Parameter(Mandatory=$true)]
            [string] $ResultsFolder
        )

        Write-Host ("Retrieving list of jobs in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        if ($JobIds) {
            $JobIds | ForEach-Object { Write-Host ("Scoping results to include job id '{0}'." -f $_) }
            $JobsList = Get-AzureRmAutomationJob -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName | Where-Object { $JobIds -contains $_.JobId }
        } else {
            if ($RunbookNames) {
                $RunbookNames | ForEach-Object { Write-Host ("Scoping results to include jobs for runbook named '{0}'." -f $_) }
                $JobsList = Get-AzureRmAutomationJob -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName | Where-Object { $RunbookNames -contains $_.RunbookName } | Sort-Object CreationTime | Select-Object -Last $NumberOfJobs | Sort-Object CreationTime -Descending
            } else {
                $JobsList = Get-AzureRmAutomationJob -ResourceGroupName $AutomationAccount.ResourceGroupName -AutomationAccountName $AutomationAccount.AutomationAccountName | Sort-Object CreationTime | Select-Object -Last $NumberOfJobs | Sort-Object CreationTime -Descending
            }
        }
        if (($JobsList | Measure-Object).Count -eq 0) {
            Write-Host ("No jobs found in Automation account '{0}'." -f $AutomationAccount.AutomationAccountName)
        } else {
            if (($JobsList | Measure-Object).Count -eq $NumberOfJobs) {
                Write-Host ("Found '{0}' job(s) in Automation account '{1}'.  Results limited by `$NumberOfJobs value of '{2}'." -f ($JobsList | Measure-Object).Count, $AutomationAccount.AutomationAccountName, $NumberOfJobs)
            } else {
                Write-Host ("Found '{0}' job(s) in Automation account '{1}'." -f ($JobsList | Measure-Object).Count, $AutomationAccount.AutomationAccountName)
            }
            $Jobs = @()
            $JobsList | ForEach-Object {
                Write-Host ("Getting details for job id '{0}' of runbook '{1}'." -f $_.JobId, $_.RunbookName)
                $Jobs += Get-AzureRmAutomationJob -ResourceGroupName $_.ResourceGroupname -AutomationAccountName $_.AutomationAccountName -Id $_.JobId
            }
            Write-Host ("Writing job summary to '{0}\JobsSummary.txt'." -f $ResultsFolder)
            $Jobs | Select-Object JobId, RunbookName, Status, StatusDetails, HybridWorker, StartedBy, CreationTime, StartTime, EndTime, @{Name="Duration";Expression={$_.EndTime - $_.StartTime}}, Exception | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\JobsSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing job summary in CSV to '{0}\JobsSummary.csv'." -f $ResultsFolder)
            $Jobs | Select-Object JobId, RunbookName, Status, StatusDetails, HybridWorker, StartedBy, CreationTime, StartTime, EndTime, @{Name="Duration";Expression={$_.EndTime - $_.StartTime}}, Exception | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\JobsSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing job details in JSON to '{0}\JobsJSON.txt'." -f $ResultsFolder)
            $Jobs | Select-Object *, @{Name="Duration";Expression={$_.EndTime - $_.StartTime}} | ConvertTo-Json -Depth 10 | Out-File ("{0}\JobsJSON.txt" -f $ResultsFolder) -Encoding ascii -Force

            # Process each job to capture job stream data
            $JobStreamRecords = @()
            $Jobs | ForEach-Object {
                Write-Host ("Retrieving job streams for job id '{0}' of runbook '{1}'." -f $_.JobId, $_.RunbookName)
                $JobStreams = $_ | Get-AzureRmAutomationJobOutput -Stream Any | Sort-Object StreamRecordId
                if (($JobStreams | Measure-Object).Count -eq 0) {
                    Write-Host ("No job streams found for job id '{0}'." -f $_.JobId)
                } else {
                    Write-Host ("Found '{0}' job streams for job id '{1}'." -f ($JobStreams | Measure-Object).Count, $_.JobId)
                    foreach ($JobStream in $JobStreams) {
                        $JobStreamRecord = $_
                        Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamRecordId -Value $JobStream.StreamRecordId -Force
                        Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamTime -Value $JobStream.Time -Force
                        Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamType -Value $JobStream.Type -Force
                        Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamSummary -Value $JobStream.Summary -Force
                        if ($IncludeAllStreamValues) {
                            Write-Host ("Getting job stream record for job stream id '{0}'." -f $JobStream.StreamRecordId)
                            $OutputRecord = $JobStream | Get-AzureRmAutomationJobOutputRecord
                            Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamValue -Value ($OutputRecord.Value | ConvertTo-Json -Depth 10) -Force
                        } else {
                            if ($JobStream.Type -eq 'Error') {
                                Write-Host ("Getting job stream record for job stream id '{0}'." -f $JobStream.StreamRecordId)
                                $OutputRecord = $JobStream | Get-AzureRmAutomationJobOutputRecord
                                Add-Member -InputObject $JobStreamRecord -MemberType NoteProperty -Name StreamValue -Value ($OutputRecord.Value | ConvertTo-Json -Depth 10) -Force
                            }
                        }
                        $JobStreamRecords += $JobStreamRecord | Select-Object RunbookName, JobId, Status, StreamRecordId, StreamTime, StreamType, StreamSummary, StreamValue
                    }
                }
            }
            Write-Host ("Writing job stream summary to '{0}\JobStreamsSummary.txt'." -f $ResultsFolder)
            $JobStreamRecords | Select-Object RunbookName, JobId, Status, StreamRecordId, StreamTime, StreamType, StreamSummary | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File ("{0}\JobStreamsSummary.txt" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing job stream summary in CSV to '{0}\JobStreamsSummary.csv'." -f $ResultsFolder)
            $JobStreamRecords | Select-Object RunbookName, JobId, Status, StreamRecordId, StreamTime, StreamType, StreamSummary | ConvertTo-Csv -NoTypeInformation | Out-File ("{0}\JobStreamsSummary.csv" -f $ResultsFolder) -Encoding ascii -Force
            Write-Host ("Writing job stream values in JSON to '{0}\JobStreamsValues.txt'." -f $ResultsFolder)
            if ($IncludeAllStreamValues) {
                $JobStreamRecords | Select-Object StreamRecordId, StreamValue | ConvertTo-Json -Depth 10 | Out-File ("{0}\JobStreamsValues.txt" -f $ResultsFolder) -Encoding ascii -Force
            } else {
                $JobStreamRecords | Where-Object { $_.StreamType -eq 'Error' } | Select-Object StreamRecordId, StreamValue | ConvertTo-Json -Depth 10 | Out-File ("{0}\JobStreamsValues.txt" -f $ResultsFolder) -Encoding ascii -Force
            }
        }
    }


# Create folder structure needed for results
CreateResultFolder
Start-Transcript -Path ("{0}\Transcript.txt" -f $AzureAutomationDiagResultPath)

# Verify required modules are available
VerifyModules

# Login to Azure.
Write-Host ("Prompting user to login to Azure.")
Add-AzureRmAccount

# Select subscription if more than one is available
Write-Host ("Selecting desired Azure Subscription.")
$Subscriptions = Get-AzureRmSubscription
switch (($Subscriptions | Measure-Object).Count) {
    0 { throw "No subscriptions found." }
    1 { 
        $Subscription = $Subscriptions[0] 
        $AzureContext = Get-AzureRmContext
    }
    default { 
        Write-Host ("Multiple Subscriptions found, prompting user to select desired Azure Subscription.")
        $Subscription = ($Subscriptions | Out-GridView -Title 'Select Azure Subscription' -PassThru)
        $AzureContext = Select-AzureRmSubscription -SubscriptionId $Subscription.SubscriptionId
    }
}
Write-Host ("Subscription successfully selected.")
$AzureContext | Format-List

# Get list of Automation accounts to be processed
if ($AutomationAccountNames) {
    $AutomationAccountNames | ForEach-Object { Write-Host("Scoping results to include Automation account '{0}'." -f $_) }
    $AutomationAccountsResults = Get-AzureRmAutomationAccount | Where-Object { $AutomationAccountNames -contains $_.AutomationAccountName } | Sort-Object AutomationAccountName
} else {
    Write-Host ("Retrieving list of Automation accounts.")
    $AutomationAccountsResults = Get-AzureRmAutomationAccount | Sort-Object AutomationAccountName
}

# Retrieve all details for each automation account
$AutomationAccounts = @()
$AutomationAccountsResults | ForEach-Object {
    Write-Host ("Getting details for Automation account '{0}'." -f $_.AutomationAccountName)
    $AutomationAccounts += Get-AzureRmAutomationAccount -ResourceGroupName $_.ResourceGroupName -Name $_.AutomationAccountName
}

# Write Automation accounts out to results folder
$AutomationAccountsResultsFile = ("{0}\AutomationAccounts.txt" -f $AzureAutomationDiagResultPath)
Write-Host ("Writing Azure automation account details to '{0}'." -f $AutomationAccountsResultsFile)
$AutomationAccounts | Format-Table * -AutoSize | Out-String -Width 8000 | Out-File $AutomationAccountsResultsFile -Encoding ascii -Force

# Enumerate through the Automation accounts
$AutomationAccounts | ForEach-Object {
    $AutomationAccountResultFolder = ("{0}\{1}" -f $AzureAutomationDiagResultPath, $_.AutomationAccountName)
    CreateFolder $AutomationAccountResultFolder

    WriteModuleDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteRunbookDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteScheduleDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteScheduledRunbookDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteVariableDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteConnectionDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteCertificateDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteCredentialDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
    WriteJobDetails -AutomationAccount $_ -ResultsFolder $AutomationAccountResultFolder
}

Write-Host ("Execution completed.")
Stop-Transcript

# Open the diagnostics result path in Explorer
start $AzureAutomationDiagResultPath
