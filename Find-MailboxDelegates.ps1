﻿<#
.DESCRIPTION

###############Disclaimer#####################################################
The sample scripts are not supported under any Microsoft standard support 
program or service. The sample scripts are provided AS IS without warranty  
of any kind. Microsoft further disclaims all implied warranties including,  
without limitation, any implied warranties of merchantability or of fitness for 
a particular purpose. The entire risk arising out of the use or performance of  
the sample scripts and documentation remains with you. In no event shall 
Microsoft, its authors, or anyone else involved in the creation, production, or 
delivery of the scripts be liable for any damages whatsoever (including, 
without limitation, damages for loss of business profits, business interruption, 
loss of business information, or other pecuniary loss) arising out of the use 
of or inability to use the sample scripts or documentation, even if Microsoft 
has been advised of the possibility of such damages.
###############Disclaimer#####################################################

We have developed this script because cross premises permissions are not supported with Exchange Hybrid environments: https://technet.microsoft.com/en-us/library/jj906433(v=exchg.150).aspx.
With this script you can export Exchange 2010/2013 on premises permissions, find their associated delegates, and produce a report of mailboxes with their recommended batch to minimize impact to those users.   

Steps performed by the script: 
 
    1)Collect permissions 
    2)Find batches based on the output permissions
    3)Create Migration schedule (this is built in the format required by the Microsoft FastTrack Mail Migration team).

*For extra large environments with many mailboxes, you may consider running multiple instances of the script. For example: 
    1)Create multiple csv files that has different emails each. The number of csv files depends on the number of powershell sessions you will have going in parallel.
    2)Spin up multiple powershell sessions and run the script pointed at different InputMailboxesCSV files
    3)Merge the permissions output files from each script into one singular permissions file
    4)Run one of the scripts with the -BatchUsers - this will bypass collecting permissions and jump straight into batching users using the permissinos output in the same directory as the script  

=========================================
Published date: 06/15/2017

Authors: 
Alejandro Lopez - alejanl@microsoft.com
Sam Portelli - Sam.Portelli@microsoft.com
=========================================

.PARAMETER InputMailboxesCSV
Use this parameter to specify a list of users to collect permissions for, rather than all mailboxes.
Make sure that the CSV file provided has a header titled "PrimarySMTPAddress"

.PARAMETER ExcludeServiceAcctsCSV
In cases where you have service accounts with permissions to a large number of mailboxes, e.g. Blackberry service accounts, you can use this to exclude those accounts from the batching processing. 
Provide the path to a csv file (no header needed) with each service account primarySMTPaddress on its own line. 
 
*This will slow down processing. 

.PARAMETER FullAccess
Collect Full Access permissions. Keep in mind that "Full Access" permissions are now supported in cross premises scenarios. Not including "Full Access" will speed up processing. 

.PARAMETER SendOnBehalfTo
Collect SendOnBehalfTo permissions

.PARAMETER Calendar
Collect calendar permissions

.PARAMETER SendAs
Collect Send As permissions

.PARAMETER EnumerateGroups
This will enumerate groups that have permissions to mailboxes and include in the batching logic.

*This will slow down processing.

.PARAMETER ExcludeGroupsCSV
Use this to exclude groups that you don't want to enumerate. Provide the path to a csv file (no header needed) with each group name on its own line. 

.PARAMETER ExchServerFQDN
Connect to a specific Exchange Server

.PARAMETER Resume
Use this to resume the script in case of a failure while running the script on a large number of users. This way you don't have to start all over.
The way this works is that it will look for the progress xml file where it keeps track of mailboxes that are pending processing.
Make sure not to use in conjunction with the InputMailboxesCSV switch.

.PARAMETER BatchUsers
Use this if you want to skip collecting permissions and only run Step 2 and Step 3. 
Make sure you have the permissions output file in the same directory (Find-MailboxDelegates-Permissions.csv).

.EXAMPLE
#Export only SendOnBehalfTo and Send As permissions and Enumerate Groups for all mailboxes.  
.\Find-MailboxDelegates.ps1 -SendOnBehalfTo -SendAs -EnumerateGroups

.EXAMPLE
#Export only Full Access and Send As permissions and Enumerate Groups for the provided user list. Make sure to use "PrimarySMTPAddress" as header. 
.\Find-MailboxDelegates.ps1 -InputMailboxesCSV "C:\Users\administrator\Desktop\userlist.csv" -FullAccess -SendAs -EnumerateGroups

.EXAMPLE
#Resume the script after a script interruption and failure to pick up on where it left off. Make sure to include the same switches as before EXCEPT the InputMailboxesCSV otherwise it'll yell at you
.\Find-MailboxDelegates.ps1 -FullAccess -SendAs -EnumerateGroups -Resume

.EXAMPLE
#Export all permissions and enumerate groups for all mailboxes
.\Find-MailboxDelegates.ps1 -FullAccess -SendOnBehalfTo -SendAs -Calendar -EnumerateGroups 

.EXAMPLE
#Export all permissions but don't enumerate groups for all mailboxes
.\Find-MailboxDelegates.ps1 -FullAccess -SendOnBehalfTo -SendAs -Calendar

.EXAMPLE
#Export all permissions and exclude service accounts for all mailboxes
.\Find-MailboxDelegates.ps1 -FullAccess -SendOnBehalfTo -SendAs -Calendar -ExcludeServiceAcctsCSV "c:\serviceaccts.csv" 

.EXAMPLE
#Export all permissions and exclude service accounts for all mailboxes
.\Find-MailboxDelegates.ps1 -FullAccess -SendOnBehalfTo -SendAs -Calendar -ExcludeServiceAcctsCSV "c:\serviceaccts.csv" -ExcludeGroupsCSV "c:\groups.csv"

.EXAMPLE
#Skip collect permissions (assumes you already have a permissions output file) and only run Step 2 and 3 to batch users
.\Find-MailboxDelegates.ps1 -BatchUsers


#>

param(
    [string]$InputMailboxesCSV,
    [switch]$FullAccess,
    [switch]$SendOnBehalfTo,
    [switch]$Calendar,
    [switch]$SendAs,
    [switch]$EnumerateGroups,
    [string]$ExcludeServiceAcctsCSV,
    [string]$ExcludeGroupsCSV,
    [string]$ExchServerFQDN,
    [switch]$Resume,
    [switch]$BatchUsers
)

Begin{
    try{
        $WarningPreference = "SilentlyContinue"
        $ErrorActionPreference = "SilentlyContinue"

        ""
        Write-Host "Pre-Flight Check" -ForegroundColor Green
        
        #Requirement is Powershell V3 in order to use PSCustomObjets which are data structures
        If($host.version.major -lt 3){
            throw "Powershell V3+ is required."
        }

        If($BatchUsers -and ($FullAccess -or $SendOnBehalfTo -or $Calendar -or $SendAs -or $InputMailboxesCSV -or $EnumerateGroups -or $ExcludeServiceAccts -or $ExcludeGroups -or $Resume)){
            throw "BatchUsers can't be combined with these other switches."
        }
        If(!$FullAccess -and !$SendOnBehalfTo -and !$Calendar -and !$SendAs -and !$BatchUsers){
            throw "Include the switches for the permissions you want to query on. Check the read me file for more details."
        }

        #Load functions
        Function Write-LogEntry {
               param(
                  [string] $LogName ,
                  [string] $LogEntryText,
                  [string] $ForegroundColor
               )
               if ($LogName -NotLike $Null) {
                  # log the date and time in the text file along with the data passed
                  "$([DateTime]::Now.ToShortDateString()) $([DateTime]::Now.ToShortTimeString()) : $LogEntryText" | Out-File -FilePath $LogName -append;
                  if ($ForeGroundColor -NotLike $null) {
                     # for testing i pass the ForegroundColor parameter to act as a switch to also write to the shell console
                     write-host $LogEntryText -ForegroundColor $ForeGroundColor
                  }
               }
            }

        Function Get-Permissions(){
	            param(
                    [string]$UserEmail,
                    [bool]$gatherfullaccess,
                    [bool]$gatherSendOnBehalfTo,
                    [bool]$gathercalendar,
                    [bool]$gathersendas,
                    [bool]$EnumerateGroups,
                    [string[]]$ExcludedGroups,
                    [string[]]$ExcludedServiceAccts
                )

                try{
                    #Variables
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Get Permissions for: $UserEmail"
                    $CollectPermissions = New-Object System.Collections.Generic.List[System.Object] 
                    $Mailbox = Get-mailbox $UserEmail

                    #Enumerate Groups/Send As - moving this part outside of the function for faster processing
                    <#
                    If(($EnumerateGroups -eq $true) -or ($gathersendas -eq $true)){
                        $dse = [ADSI]"LDAP://Rootdse"
                        $ext = [ADSI]("LDAP://CN=Extended-Rights," + $dse.ConfigurationNamingContext)
                        $dn = [ADSI]"LDAP://$($dse.DefaultNamingContext)"
                        $dsLookFor = new-object System.DirectoryServices.DirectorySearcher($dn)

                        $permission = "Send As"
                        $right = $ext.psbase.Children | ? { $_.DisplayName -eq $permission }
                    }
                    #>
            
                    If($gathercalendar -eq $true){
                        $Error.Clear()
	                    $CalendarPermission = Get-MailboxFolderPermission -Identity ($Mailbox.alias + ':\Calendar') -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | ?{$_.User -notlike "Anonymous" -and $_.User -notlike "Default"} | Select User, AccessRights
	                    if (!$CalendarPermission){
                            $Calendar = (($Mailbox.PrimarySmtpAddress.ToString())+ ":\" + (Get-MailboxFolderStatistics -Identity $Mailbox.DistinguishedName -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | where-object {$_.FolderType -eq "Calendar"} | Select-Object -First 1).Name)
                            $CalendarPermission = Get-MailboxFolderPermission -Identity $Calendar -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | ?{$_.User -notlike "Anonymous" -and $_.User -notlike "Default"} | Select User, AccessRights
	                    }
            
                        If($CalendarPermission){
                            Foreach($perm in $CalendarPermission){
                                $ifGroup = Get-Group -identity $perm.User.ADRecipient.Identity.tostring() -ErrorAction SilentlyContinue
                                If($ifGroup){
                                    If($EnumerateGroups -eq $true){
				                        If(-not ($excludedGroups -contains $ifGroup.Name)){
					                        $dsLookFor.Filter = "(&(memberof:1.2.840.113556.1.4.1941:=$($ifGroup.distinguishedName))(objectCategory=user))" 
	                                        $dsLookFor.PageSize  = 1000
	                                        $dsLookFor.SearchScope = "subtree" 
	                                        $mail = $dsLookFor.PropertiesToLoad.Add("mail")
	                                        $lstUsr = $dsLookFor.findall()
	                                        foreach ($usrTmp in $lstUsr) {
                                                $usrTmpEmail = $usrTmp.Properties["mail"]
                                                If($ExcludedServiceAccts){
                                                    if(-not ($ExcludedServiceAccts -contains $usrTmpEmail[0] -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                        $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Calendar Folder"})
                                                    }
                                                }
                                                Else{
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Calendar Folder"})
                                                }
	                                        }
				                        }
                                    }
                                }
                                Else{
                                    $delegate = Get-Recipient -Identity $perm.User.ADRecipient.Identity.tostring() 
                        
                                    If($mailbox.primarySMTPAddress -and $delegate.primarySMTPAddress){
							            If(-not ($mailbox.primarySMTPAddress.ToString() -eq $delegate.primarySMTPAddress.ToString())){
                                            If($ExcludedServiceAccts){
                                                if(-not ($ExcludedServiceAccts -contains $delegate.primarySMTPAddress.tostring() -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Calendar Folder"})
                                                }
                                            }
                                            Else{
                                                $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Calendar Folder"})
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        If($Error){
                            Write-LogEntry -LogName:$Script:LogFile -LogEntryText "$($Mailbox.PrimarySMTPAddress) : Check CalendarFolder  : $Error"
                        }
                    }

                    If($gatherfullaccess -eq $true){
                        $Error.Clear()
                        $FullAccessPermissions = Get-MailboxPermission -Identity ($Mailbox.PrimarySMTPAddress).tostring() | ? {($_.AccessRights -like “*FullAccess*”) -and ($_.IsInherited -eq $false) -and ($_.User -notlike “NT AUTHORITY\SELF”) -and ($_.User -notlike "S-1-5*") -and ($_.User -notlike $Mailbox.PrimarySMTPAddress)}
                
                        If($FullAccessPermissions){
                            Foreach($perm in $FullAccessPermissions){
                                $ifGroup = Get-Group -identity $perm.user.tostring() -ErrorAction SilentlyContinue 
                                If($ifGroup){
                                    If($EnumerateGroups -eq $true){
				                        If(-not ($excludedGroups -contains $ifGroup.Name)){
					                        $dsLookFor.Filter = "(&(memberof:1.2.840.113556.1.4.1941:=$($ifGroup.distinguishedName))(objectCategory=user))" 
	                                        $dsLookFor.PageSize  = 1000
	                                        $dsLookFor.SearchScope = "subtree" 
	                                        $mail = $dsLookFor.PropertiesToLoad.Add("mail")
	                                        $lstUsr = $dsLookFor.findall()
	                                        foreach ($usrTmp in $lstUsr) {
                                                $usrTmpEmail = $usrTmp.Properties["mail"]
                                                If($ExcludedServiceAccts){
                                                    if(-not ($ExcludedServiceAccts -contains $usrTmpEmail[0] -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                        $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Full Access"})
                                                    }
                                                }
                                                Else{
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Full Access"})
                                                }
	                                        }
				                        }
                                    }
                                }
                                Else{
                                    $delegate = Get-Recipient -Identity $perm.user.tostring() 
                        
                                    If($mailbox.primarySMTPAddress -and $delegate.primarySMTPAddress){
							            If(-not ($mailbox.primarySMTPAddress.ToString() -eq $delegate.primarySMTPAddress.ToString())){
                                            If($ExcludedServiceAccts){
                                                if(-not ($ExcludedServiceAccts -contains $delegate.primarySMTPAddress.tostring() -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Full Access"})
                                                }
                                            }
                                            Else{
                                                $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Full Access"})
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        If($Error){
                            Write-LogEntry -LogName:$Script:LogFile -LogEntryText "$($Mailbox.PrimarySMTPAddress) : Check FullAccess  : $Error"
                        }
                    }

                    If($gathersendas -eq $true){
                        $Error.Clear()
                        #$SendAsPermissions = Get-ADPermission $Mailbox.DistinguishedName | ?{($_.ExtendedRights -like "*send-as*") -and ($_.IsInherited -eq $false) -and -not ($_.User -like "NT AUTHORITY\SELF") }
                
                        $SendAsPermissions = New-Object System.Collections.Generic.List[System.Object] 
                        $userDN = [ADSI]("LDAP://$($mailbox.DistinguishedName)")
                        $userDN.psbase.ObjectSecurity.Access | ? { ($_.ObjectType -eq [GUID]$right.RightsGuid.Value) -and ($_.IsInherited -eq $false) } | select -ExpandProperty identityreference | %{
				            If(-not ($_ -like "NT AUTHORITY\SELF")){
					            $SendAsPermissions.add($_)
				            }
			            }
                

                        If($SendAsPermissions){
                            Foreach($perm in $SendAsPermissions){
                                $ifGroup = Get-Group -identity $perm.tostring() -ErrorAction SilentlyContinue
                                If($ifGroup){
                                    If($EnumerateGroups -eq $true){
				                        If(-not ($ExcludedGroups -contains $ifGroup.Name)){
					                        $dsLookFor.Filter = "(&(memberof:1.2.840.113556.1.4.1941:=$($ifGroup.distinguishedName))(objectCategory=user))" 
	                                        $dsLookFor.PageSize  = 1000
	                                        $dsLookFor.SearchScope = "subtree" 
	                                        $mail = $dsLookFor.PropertiesToLoad.Add("mail")
	                                        $lstUsr = $dsLookFor.findall()
	                                        foreach ($usrTmp in $lstUsr) {
                                                $usrTmpEmail = $usrTmp.Properties["mail"]
                                                If($ExcludedServiceAccts){
                                                    if(-not ($ExcludedServiceAccts -contains $usrTmpEmail[0] -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                        $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Send As"})
                                                    }
                                                }
                                                Else{
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $usrTmpEmail[0]; AccessRights = "Send As"})
                                                }
	                                        }
				                        }
                                    }
                                }
                                Else{
                                    $delegate = Get-Recipient -Identity $perm.tostring()
                        
                                    If($mailbox.primarySMTPAddress -and $delegate.primarySMTPAddress){
							            If(-not ($mailbox.primarySMTPAddress.ToString() -eq $delegate.primarySMTPAddress.ToString())){
								            If($ExcludedServiceAccts){
                                                if(-not ($ExcludedServiceAccts -contains $delegate.primarySMTPAddress.tostring() -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                    $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Send As"})
                                                }
                                            }
                                            Else{
                                                $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "Send As"})
                                            }
                                        }
                                    }
                                }
                            }    
                        }

                        If($Error){
                            Write-LogEntry -LogName:$Script:LogFile -LogEntryText "$($Mailbox.PrimarySMTPAddress) : Check SendAs  : $Error"
                        }
                    }

                    If($gatherSendOnBehalfTo -eq $true){
                        $Error.Clear()
                        $GrantSendOnBehalfToPermissions = $Mailbox.grantsendonbehalfto.ToArray()

                        If($GrantSendOnBehalfToPermissions){
                            Foreach($perm in $GrantSendOnBehalfToPermissions){
                                $delegate = Get-Recipient -Identity $perm.tostring() 
                        
                                If($mailbox.primarySMTPAddress -and $delegate.primarySMTPAddress){
							        If(-not ($mailbox.primarySMTPAddress.ToString() -eq $delegate.primarySMTPAddress.ToString())){
                                        If($ExcludedServiceAccts){
                                            if(-not ($ExcludedServiceAccts -contains $delegate.primarySMTPAddress.tostring() -or $ExcludedServiceAccts -contains $mailbox.primarySMTPAddress.ToString())){
                                                $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "GrantSendOnBehalfTo"})
                                            }
                                        }
                                        Else{
                                            $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = $delegate.primarySMTPAddress.ToString(); AccessRights = "GrantSendOnBehalfTo"})
                                        }
                                    }
                                }
                            }
                        }
                        
                        If($Error){
                            Write-LogEntry -LogName:$Script:LogFile -LogEntryText "$($Mailbox.PrimarySMTPAddress) : Check SendOnBehalfTo  : $Error"
                        }
                    }
                    
                    
                    
                    If($CollectPermissions.Count -eq 0){
                        #write progress to xml file
                        $updateXML = [System.Xml.XmlDocument](Get-Content $ProgressXMLFile)
                        $node = $updateXML.Mailboxes.Mailbox | ?{$_.Name -eq $Mailbox.PrimarySMTPAddress}
                        If($node -ne $null){
                            $node.Progress = "Completed"
                        }
                        $updateXML.save($ProgressXMLFile)
                        $CollectPermissions.add([pscustomobject]@{Mailbox = $Mailbox.PrimarySMTPAddress; User = "None"; AccessRights = "None"})
                        Return $CollectPermissions
                    }
                    else{
                        #write progress to xml file
                        $updateXML = [System.Xml.XmlDocument](Get-Content $ProgressXMLFile)
                        $node = $updateXML.Mailboxes.Mailbox | ?{$_.Name -eq $Mailbox.PrimarySMTPAddress}
                        If($node -ne $null){
                            $node.Progress = "Completed"
                        }
                        $updateXML.save($ProgressXMLFile)
                        Return $CollectPermissions
                    }
                }
                catch{
                    $updateXML = [System.Xml.XmlDocument](Get-Content $ProgressXMLFile)
                    $node = $updateXML.Mailboxes.Mailbox | ?{$_.Name -eq $Mailbox.PrimarySMTPAddress}
                    If($node -ne $null){
                        $node.Progress = "Failed"
                    }
                    $updateXML.save($ProgressXMLFile)
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "$Mailbox.PrimarySMTPAddress : $_ "
                }
            }

        Function Create-Batches(){
                param(
                    [string]$InputPermissionsFile
                )
		
                #Variables
                If(-not (Test-Path $InputPermissionsFile)){
                    throw [System.IO.FileNotFoundException] "$($InputPermissionsFile) file not found."
                }
                Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Run function: Create-Batches" -ForegroundColor White 
    
                $data = import-csv $InputPermissionsFile
                $hashData = $data | Group Mailbox -AsHashTable -AsString
	            $hashDataByDelegate = $data | Group user -AsHashTable -AsString
	            $usersWithNoDependents = New-Object System.Collections.ArrayList
                $batch = @{}
                $batchNum = 0
                $hashDataSize = $hashData.Count
                $yyyyMMdd = Get-Date -Format 'yyyyMMdd'
	
                try{
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Build ArrayList for users with no dependents"
                    If($hashDataByDelegate["None"].count -gt 0){
		                $hashDataByDelegate["None"] | %{$_.Mailbox} | %{[void]$usersWithNoDependents.Add($_)}
	                }	    

                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Identify users with no permissions on them, nor them have perms on another" 
	                If($usersWithNoDependents.count -gt 0){
		                $($usersWithNoDependents) | %{
			                if($hashDataByDelegate.ContainsKey($_)){
				                $usersWithNoDependents.Remove($_)
			                }	
		                }
            
                        Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Remove users with no dependents from hash" 
		                $usersWithNoDependents | %{$hashData.Remove($_)}
		                #Clean out hashData of users in hash data with no delegates, otherwise they'll get batched
                        Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Clean out hashData of users in hash with no delegates"  
		                foreach($key in $($hashData.keys)){
                                if(($hashData[$key] | select -expandproperty user ) -eq "None"){
				                $hashData.Remove($key)
			                }
		                }
	                }
                    #Execute batch functions
                    If(($hashData.count -ne 0) -or ($usersWithNoDependents.count -ne 0)){
                        Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Run function: Find-Links" -ForegroundColor White  
                        while($hashData.count -ne 0){Find-Links $hashData | out-null} 
                        Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Run function: Create-BatchFile" -ForegroundColor White
                        Create-BatchFile $batch $usersWithNoDependents
                    }
                }
                catch {
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Error: $_"
                }
            }

        Function Find-Links($hashData){
                try{
                    $nextInHash = $hashData.Keys | select -first 1
                    $batch.Add($nextInHash,$hashData[$nextInHash])
	
	                Do{
		                $checkForMatches = $false
		                foreach($key in $($hashData.keys)){
			                Write-Progress -Activity "Step 2 of 3: Analyze Delegates" -status "Items remaining: $($hashData.Count)" `
    		                -percentComplete (($hashDataSize-$hashData.Count) / $hashDataSize*100)
			
	                        #Checks
			                $usersHashData = $($hashData[$key]) | %{$_.mailbox}
                            $usersBatch = $($batch[$nextInHash]) | %{$_.mailbox}
                            $delegatesHashData = $($hashData[$key]) | %{$_.user} 
			                $delegatesBatch = $($batch[$nextInHash]) | %{$_.user}

			                $ifMatchesHashUserToBatchUser = [bool]($usersHashData | ?{$usersBatch -contains $_})
			                $ifMatchesHashDelegToBatchDeleg = [bool]($delegatesHashData | ?{$delegatesBatch -contains $_})
			                $ifMatchesHashUserToBatchDelegate = [bool]($usersHashData | ?{$delegatesBatch -contains $_})
			                $ifMatchesHashDelegToBatchUser = [bool]($delegatesHashData | ?{$usersBatch -contains $_})
			
			                If($ifMatchesHashDelegToBatchDeleg -OR $ifMatchesHashDelegToBatchUser -OR $ifMatchesHashUserToBatchUser -OR $ifMatchesHashUserToBatchDelegate){
	                            if(($key -ne $nextInHash)){ 
					                $batch[$nextInHash] += $hashData[$key]
					                $checkForMatches = $true
	                            }
	                            $hashData.Remove($key)
	                        }
	                    }
	                } Until ($checkForMatches -eq $false)
        
                    return $hashData
	            }
	            catch{
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Error: $_" -ForegroundColor Red 
                }
            }

        Function Create-BatchFile($batchResults,$usersWithNoDepsResults){
	            try{
                     "Batch,User" > $Script:BatchesFile
	                 foreach($key in $batchResults.keys){
                        $batchNum++
                        $batchName = "BATCH-$batchNum"
		                $output = New-Object System.Collections.ArrayList
		                $($batch[$key]) | %{$output.add($_.mailbox) | out-null}
		                $($batch[$key]) | %{$output.add($_.user) | out-null}
		                $output | select -Unique | % {
                           "$batchName"+","+$_ >> $Script:BatchesFile
		                }
                     }
	                 If($usersWithNoDepsResults.count -gt 0){
		                 $batchNum++
		                 foreach($user in $usersWithNoDepsResults){
		 	                #$batchName = "BATCH-$batchNum"
                            $batchName = "BATCH-NoDependencies"
			                "$batchName"+","+$user >> $Script:BatchesFile
		                 }
	                 }
                 }
                 catch{
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Error: $_" -ForegroundColor Red  
                 }
            } 

        Function Create-MigrationSchedule(){
                param(
                    [string]$InputBatchesFile 
                )
	            try{
                    If(-not (Test-Path $InputBatchesFile)){
                        throw [System.IO.FileNotFoundException] "$($InputBatchesFile) file not found."
                    }
                    $usersFromBatch = import-csv $InputBatchesFile
                    "Migration Date(MM/dd/yyyy),Migration Window,Migration Group,PrimarySMTPAddress,SuggestedBatch,MailboxSize(MB),Notes" > $Script:MigrationScheduleFile
                    $userInfo = New-Object System.Text.StringBuilder
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Number of users in the migration schedule: $($usersFromBatch.Count)" -ForegroundColor White

                    $usersFromBatchCounter = 0
                    foreach($item in $usersFromBatch){
                        $usersFromBatchCounter++
                        $usersFromBatchRemaining = $usersFromBatch.count - $usersFromBatchCounter
                        Write-Progress -Activity "Step 3 of 3: Creating migration schedule" -status "Items remaining: $($usersFromBatchRemaining)" `
    		                -percentComplete (($usersFromBatchCounter / $usersFromBatch.count)*100)

                       #Check if using UseImportCSVFile and if yes, check if the user was part of that file, otherwise mark 
                       $isUserPartOfInitialCSVFile = ""
                       If($Script:InputMailboxesCSV -ne ""){
                        If(-not ($Script:ListOfMailboxes.PrimarySMTPAddress -contains $item.user)){
                            $isUserPartOfInitialCSVFile = "User was not part of initial csv file"
                        }
                       }

                       $user = get-user $item.user -erroraction SilentlyContinue
		   
                       If(![string]::IsNullOrEmpty($user.WindowsEmailAddress)){
			                $mbStats = Get-MailboxStatistics $user.WindowsEmailAddress.tostring() | select totalitemsize
			                If($mbStats.totalitemsize.value){
                                $mailboxSize =  $mbStats.totalitemsize.value.ToMb()
			                }
			                Else{
                                $mailboxSize = 0
                            }

                           $userInfo.AppendLine(",,,$($user.WindowsEmailAddress),$($item.Batch),$($mailboxSize),$isUserPartOfInitialCSVFile") | Out-Null
                       }
		               Else{ #there was an error either getting the user from Get-User or the user doesn't have an email address
					       $userInfo.AppendLine(",,,$($item.user),$($item.Batch),n/a,,User not found or doesn't have an email address") | Out-Null
		               }
                    }
                    $userInfo.ToString().TrimEnd() >> $Script:MigrationScheduleFile
                }
                catch{
                    Write-LogEntry -LogName:$Script:LogFile -LogEntryText "Error: $($_) at $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
                }
            }

        If($ExchServerFQDN -ne ""){
            try{
                ""
                #If want to save creds without having to enter password into Get-Credential every time
                #$password = "Password" | ConvertTo-SecureString -asPlainText -Force
                #$username = "administrator@contoso.com" 
                #$Creds = New-Object System.Management.Automation.PSCredential($username,$password)

                $ExchServerFQDN = "$env:computername.$env:userdnsdomain"
                $Creds = Get-Credential -Message "This account will be used to connect to exchange on premises"
	            $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchServerFQDN/PowerShell/ -Authentication Kerberos -Credential $Creds -WarningAction 'SilentlyContinue' -ErrorAction SilentlyContinue
                If(!$session){
                    $ExchServerFQDN = Read-host "Type in the FQDN of the Exchange Server to connect to"
                    $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchServerFQDN/PowerShell/ -Authentication Kerberos -Credential $Creds -WarningAction 'SilentlyContinue' 
                }
	            $Connect = Import-Module (Import-PSSession $Session -AllowClobber -WarningAction 'SilentlyContinue' -DisableNameChecking) -Global -WarningAction 'SilentlyContinue'
            }
            catch{
                throw "Unable to establish a session with the Exchange Server: $($ExchServerFQDN)"
                exit
            }
        }
        Else{
            #check if a session already exists
            $error.clear()
            get-command get-mailbox -ErrorAction SilentlyContinue | out-null
            If($error){
                try{
                    ""
                    #If want to save creds without having to enter password into Get-Credential every time
                    #$password = "Password" | ConvertTo-SecureString -asPlainText -Force
                    #$username = "administrator@contoso.com" 
                    #$Creds = New-Object System.Management.Automation.PSCredential($username,$password)

                    $ExchServerFQDN = "$env:computername.$env:userdnsdomain"
                    $Creds = Get-Credential -Message "This account will be used to connect to exchange on premises"
	                $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchServerFQDN/PowerShell/ -Authentication Kerberos -Credential $Creds -WarningAction 'SilentlyContinue' -ErrorAction SilentlyContinue
                    If(!$session){
                        $ExchServerFQDN = Read-host "Type in the FQDN of the Exchange Server to connect to"
                        $session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri http://$ExchServerFQDN/PowerShell/ -Authentication Kerberos -Credential $Creds -WarningAction 'SilentlyContinue' 
                    }
	                $Connect = Import-Module (Import-PSSession $Session -AllowClobber -WarningAction 'SilentlyContinue' -DisableNameChecking) -Global -WarningAction 'SilentlyContinue'
                }
                catch{
                    throw "Unable to establish a session with the Exchange Server: $($ExchServerFQDN)"
                    exit
                }
            }
        }

        #Open connection to AD - this will be used to enumerate groups and collect Send As permissions
        If(($EnumerateGroups -eq $true) -or ($SendAs -eq $true)){ 
            $dse = [ADSI]"LDAP://Rootdse"
            $ext = [ADSI]("LDAP://CN=Extended-Rights," + $dse.ConfigurationNamingContext)
            $dn = [ADSI]"LDAP://$($dse.DefaultNamingContext)"
            $dsLookFor = new-object System.DirectoryServices.DirectorySearcher($dn)

            $permission = "Send As"
            $right = $ext.psbase.Children | ? { $_.DisplayName -eq $permission }
        }

        #Script Variables
        $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
        $scriptPath = $PSScriptRoot
        $yyyyMMdd = Get-Date -Format 'yyyyMMdd'
        $LogFile = "$scriptPath\Find-MailboxDelegates-$yyyyMMdd.log"
        $PermsOutputFile = "$scriptPath\Find-MailboxDelegates-Permissions.csv"
        $BatchesFile = "$scriptPath\Find-MailboxDelegates-Batches.csv"
        $MigrationScheduleFile = "$scriptPath\Find-MailboxDelegates-Schedule.csv"
        $ProgressXMLFile = "$scriptPath\Find-MailboxDelegates-Progress.xml"

        #Get Mailboxes
        If($Resume){
            If(!$InputMailboxesCSV){
                If(test-path $ProgressXMLFile){
                    $xmlDoc = [System.Xml.XmlDocument](Get-Content $ProgressXMLFile)
                    $ListOfMailboxes = $xmlDoc.mailboxes.mailbox | ?{$_.Progress -eq "Pending"} | select @{N="PrimarySMTPAddress";E={$_.name}} #-expandproperty name               
                }
                else{
                    throw "Unable to resume due to missing progress file: $($ProgressXMLFile)"
                    exit
                }
                }
                Else{
                throw "Can't have both 'Resume' and 'InputMailboxesCSV' at the same time. Choose 'Resume' if you want to pick up on where you left off from a previous run."
                exit
                }        
        }
        ElseIf(!$Batchusers){
            If($InputMailboxesCSV -ne ""){
                $ListOfMailboxes = Import-Csv $InputMailboxesCSV
                if($ListOfMailboxes.PrimarySMTPAddress -eq $null){
                    throw "Make sure the input csv file header is: PrimarySMTPAddress"
                    exit
                }

                #write to xml for progress tracking
                [xml]$xmlDoc = New-Object System.Xml.XmlDocument
                $dec = $xmlDoc.CreateXmlDeclaration("1.0","UTF-8",$null)
                $xmlDoc.AppendChild($dec) | Out-Null
                $root = $xmlDoc.CreateNode("element","Mailboxes",$null)
                foreach($entry in $ListOfMailboxes.PrimarySMTPAddress){
                    $mbx = $xmlDoc.CreateNode("element","Mailbox",$null)
                    $mbx.SetAttribute("Name",$entry)
                    $mbx.SetAttribute("Progress","Pending")
                    $root.AppendChild($mbx) | Out-Null
                }

                #add root to the document
                $xmlDoc.AppendChild($root) | Out-Null

                #save file
                $xmlDoc.save($ProgressXMLFile)
            }
            Else{
                $ListOfMailboxes = Get-Mailbox -ResultSize Unlimited | select PrimarySMTPAddress

                #write to xml for progress tracking
                [xml]$xmlDoc = New-Object System.Xml.XmlDocument
                $dec = $xmlDoc.CreateXmlDeclaration("1.0","UTF-8",$null)
                $xmlDoc.AppendChild($dec) | Out-Null
                $root = $xmlDoc.CreateNode("element","Mailboxes",$null)
                foreach($entry in $ListOfMailboxes.PrimarySMTPAddress){
                    $mbx = $xmlDoc.CreateNode("element","Mailbox",$null)
                    $mbx.SetAttribute("Name",$entry)
                    $mbx.SetAttribute("Progress","Pending")
                    $root.AppendChild($mbx) | Out-Null
                }

                #add root to the document
                $xmlDoc.AppendChild($root) | Out-Null

                #save file
                $xmlDoc.save($ProgressXMLFile)
            }
        }

        #Get excluded groups
        If($ExcludeGroupsCSV){
         If(test-path $ExcludeGroupsCSV){
            $ExcludeGroups = get-content $ExcludeGroupsCSV
         }
         Else{
            throw "Unable to find the CSV file for excluded groups. Confirm this is the right directory: $($ExcludeGroupsCSV)"
            exit
         }   
        }

        #Get excluded service accts
        If($ExcludeServiceAcctsCSV){
         If(test-path $ExcludeServiceAcctsCSV){
            $ExcludeServiceAccts = get-content $ExcludeServiceAcctsCSV
         }
         Else{
            throw "Unable to find the CSV file for excluded service accounts. Confirm this is the right directory: $($ExcludeServiceAcctsCSV)"
            exit
         }   
        }

        Write-Host "Pre-flight Completed" -ForegroundColor Green
        ""
    }

    catch{
        Write-Host "Pre-flight failed: $_" -ForegroundColor Red
        If($session){
            Remove-PSSession $Session
        }
        ""
		exit
	}
}
Process{
    ""
    If(!$BatchUsers){
        Write-LogEntry -LogName:$LogFile -LogEntryText "STEP 1 of 3: Collect Permissions..." -ForegroundColor Yellow
        If($Resume){Write-LogEntry -LogName:$LogFile -LogEntryText "Resume collect permissions based on xml file" -ForegroundColor White}
        Write-LogEntry -LogName:$LogFile -LogEntryText "Mailbox count: $($ListOfMailboxes.Count)" -ForegroundColor White
        $mailboxCounter = 0
        Foreach($mailbox in $ListOfMailboxes.PrimarySMTPAddress){
            $mailboxCounter++
            Write-Progress -Activity "Step 1 of 3: Gathering Permissions" -status "Items processed: $($mailboxCounter) of $($ListOfMailboxes.Count)" `
    		            -percentComplete (($mailboxCounter / $ListOfMailboxes.Count)*100)
            Get-Permissions -UserEmail $mailbox -gatherfullaccess $FullAccess -gatherSendOnBehalfTo $SendOnBehalfTo -gathercalendar $Calendar -gathersendas $SendAs -EnumerateGroups $EnumerateGroups -ExcludedGroups $ExcludeGroups -ExcludedServiceAccts $ExcludeServiceAccts | export-csv -path $PermsOutputFile -notypeinformation -Append
        }
    }
    ""
    Write-LogEntry -LogName:$LogFile -LogEntryText "STEP 2 of 3: Analyze Delegates..." -ForegroundColor Yellow
    Create-Batches -InputPermissionsFile $PermsOutputFile
    ""
    Write-LogEntry -LogName:$LogFile -LogEntryText "STEP 3 of 3: Create schedule..." -ForegroundColor Yellow
    Create-MigrationSchedule -InputBatchesFile $BatchesFile
    ""
}
End{
    #Cleanup PSSession
    If($session){
        Remove-PSSession $Session
    }
    Write-LogEntry -LogName:$LogFile -LogEntryText "Results: $($scriptPath)"  -ForegroundColor Green
    Write-LogEntry -LogName:$LogFile -LogEntryText "Total Elapsed Time: $($elapsed.Elapsed.ToString())"  -ForegroundColor Green
}

