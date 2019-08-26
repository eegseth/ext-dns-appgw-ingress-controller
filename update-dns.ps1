#Set the needed variables and fetch the secrets
$tokenk8s = get-content '/var/run/secrets/kubernetes.io/serviceaccount/token'
$annotationformat = 'azure/application-gateway'
$Resource = "https://management.core.windows.net/"
$subscriptionId = $env:subscriptionid
$resourceGroupName = $env:resourcegroupname
$zoneName = $env:zonename
$TenantId = $env:tenantid
$ClientId = $env:clientid
$ClientSecret = $env:clientsecret
$appgwIp = $env:applicationGatewayIp
$RequestAccessTokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/token"
$azureRecordsGet = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Network/dnsZones/$zoneName/A?api-version=2018-05-01"
$k8sUri = 'https://kubernetes.default.svc/apis/networking.k8s.io/v1beta1/ingresses'
$stop = $false
$sleep = 10

#Fetch an auth token from azure and build our header for requests
$body = "grant_type=client_credentials&client_id=$ClientId&client_secret=$ClientSecret&resource=$Resource"
$Token = Invoke-RestMethod -Uri $RequestAccessTokenUri -Body $body -ContentType 'application/x-www-form-urlencoded'
$Headers = @{}
$Headers.Add("Authorization","$($Token.token_type) "+ " " + "$($Token.access_token)")

#do until infinity
Write-Output 'Starting main loop constuct'
do
{
  #Fetch ingresses from k8s
  Write-Output ('{0} - [REQ] Fething ingresses from k8s' -f $(get-date -format 'HH:mm:ss'))
  $ingresses = Invoke-WebRequest -Method Get -Uri $k8sUri -Headers @{"Authorization"="Bearer $tokenk8s"} -SkipCertificateCheck
  Write-Output ''
  $ingresses = $ingresses | ConvertFrom-Json
  $ingresses = $ingresses.items.metadata

  #Fetch DNS records from Azure
  Write-Output ('{0} - [REQ] Fething records from Azure DNS' -f $(get-date -format 'HH:mm:ss'))
  $records = Invoke-WebRequest -Method Get -Uri $azureRecordsGet -Headers $Headers -ErrorAction Stop
  Write-Output ''
  $records = ($records | ConvertFrom-Json).value

  #Loop trough the ingresses
  foreach($ingress in $ingresses)
  {
    Write-Output ('{0} - [ADD] Looking for interesting ingresses' -f $(get-date -format 'HH:mm:ss'))
    $createDns = $null
    $dnsrecords = $null
    $diff = $null
    $dnsentrys = @()

    #Check if it is a appgateway ingress class
    if((($ingress.annotations.'kubectl.kubernetes.io/last-applied-configuration' | convertfrom-json).metadata.annotations.'kubernetes.io/ingress.class') -like $annotationformat)
    {
      Write-Output ('{0} - [ADD] We have a match - {1}' -f $(get-date -format 'HH:mm:ss'), $ingress.name)
      #Fetch the hostnames defined in the ingress
      $dnsrecords = ($ingress.annotations.'kubectl.kubernetes.io/last-applied-configuration' | convertfrom-json).spec.rules.host

      if($dnsrecords)
      {
        foreach ($entry in $dnsrecords)
        {
          $dnsentrys += $entry.Split('.')[0]
        }

        if($records.name)
        {
          $diff = Compare-Object -ReferenceObject $records.name -DifferenceObject $dnsentrys
          #If it is 'new'
          $createDns = ($diff | Where-Object SideIndicator -like '=>').InputObject
        }
        else
        {
          $createDns = $dnsentrys
        }
  
        
        if($createDns)
        {
          Write-Output ('{0} - [ADD] The diff between Azure and k8s result to be added to Azure DNS is' -f $(get-date -format 'HH:mm:ss'))
          $createDns
        }
        else
        {
          Write-Output ('{0} - [ADD] No diff to write to Azure DNS' -f $(get-date -format 'HH:mm:ss'))
        }
      }

      if($createDns)
      {
        #Foreach hostname defined in the ingress
        foreach($record in $createDns)
        {
          $requestbody = @"
{
  "properties": {
    "metadata": {
      "managedBy": "appgw-external-dns"
    },
    "TTL": 3600,
    "ARecords": [
      {
        "ipv4Address": "$appgwIp"
      }
    ]
  }
}
"@
          #Push it to azure
          $azureDnsUri = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Network/dnsZones/{2}/A/{3}?api-version=2018-05-01' -f $subscriptionId, $resourceGroupName, $zoneName, $record)
          Write-Output $azureDnsUri
          try
          {
            $writerequest = Invoke-WebRequest -Uri $azureDnsUri -Body $requestbody -Method Put -Headers $Headers -ContentType 'application/json' -ErrorAction stop
            Write-Output ''
            Write-Output ('{0} - [ADD] Wrote record {1} to Azure DNS' -f $(get-date -format 'HH:mm:ss'), $record)
          }
          catch
          {
            Write-Output ('{0} - [ADD] Failed to write record {1} to Azure DNS' -f $(get-date -format 'HH:mm:ss'), $record)
          }
        }
      }
    }
  }

  #Azure DNS
  if($records.name)
  {
    try
    {
      $norecords = $true

      foreach($dnsrecord in $records)
      {
        $fqdn = ('{0}.{1}' -f $dnsrecord.name, $zoneName)
        if($fqdn -notin ($ingresses.annotations.'kubectl.kubernetes.io/last-applied-configuration' | convertfrom-json).spec.rules.host)
        {
          $managedBy = $dnsrecord.properties.metadata.managedBy
          $recordName = $dnsrecord.name
          if($managedBy -like 'appgw-external-dns')
          {
            $norecords = $false
            try
            {
              $azureRecordsDel = ('https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Network/dnsZones/{2}/A/{3}?api-version=2018-05-01' -f $subscriptionId, $resourceGroupName, $zoneName, $recordName)
              $del = Invoke-WebRequest -Method Delete -Uri $azureRecordsDel -Headers $Headers -ErrorAction Stop
              Write-Output ''
              if($del.StatusCode -ne 200)
              {
                throw '[DEL] Failed to delete record'
              }
              Write-Output ('{0} - [DEL] Deleted record {1} from Azure' -f $(get-date -format 'HH:mm:ss'), $recordName)
            }
            catch
            {
              Write-Output ('{0} - [DEL] Failed to delete record {1} from Azure' -f $(get-date -format 'HH:mm:ss'), $recordName)
            }
          }
        }
      }
      if($norecords)
      {
        Write-Output ('{0} - [DEL] Nothing to do.' -f $(get-date -format 'HH:mm:ss'))
      }
    }
    catch
    {
      Write-Output ('{0} - [DEL] Failed get records from Azure' -f $(get-date -format 'HH:mm:ss'))
    }
  }
  else
  {
    Write-Output ('{0} - [DEL] No records present, skipping delete procedure' -f $(get-date -format 'HH:mm:ss'))
  }
  Write-Output ('{0} - Sleeping {1} seconds before next iteration...' -f $(get-date -format 'HH:mm:ss'), $sleep)
  Start-Sleep -Seconds $sleep
}while($stop -eq $false)
