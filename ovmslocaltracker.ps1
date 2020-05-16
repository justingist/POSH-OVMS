param(
    [Parameter(Mandatory = $false)]
    [switch] $rawlog,
    [Parameter(Mandatory = $true)]
    [string] $configpath
)
# Websocket logic lifted from https://github.com/markwragg/Powershell-SlackBot
# Relies on a proprietary Serilog-based powershell logging module (will look to change later)

# Let's load config data

$settings = get-content $configpath | ConvertFrom-Json

Function Write-LocalJSON ($json) {
    $ds = get-date -format yyyyMMdd
    $out = [pscustomobject]@{'Time' = (get-date -format yyyyMMdd_HH:mm:ss)
                          'Message' = $json}
    $out | Export-Csv -Path ($settings.rawlogdir + $ds + "ovmsclean.csv") -Append
}

 $megalol = @()
 Import-Module ENSLogger
$logger = new-logger -ConfigFilePath $settings.loggerconfig

 while ($true){
    try {
    Write-Log -Logger $logger -Level Verbose -MessageTemplate "Attempting to open OVMS http login"
    $loginbody = [ordered]@{
    "username"=  $settings.username
    "password"=  $settings.password} # later need to change this to encrypt as secure object (this is temporary for initial release)
    $wlogin =  Invoke-RestMethod -Method Post -WebSession $wsesh -UserAgent $nagent -Uri $settings.loginurl -Body $loginbody 

    $WS = New-Object System.Net.WebSockets.ClientWebSocket                                                
    $CT = New-Object System.Threading.CancellationToken                                                   

    $Conn = $WS.ConnectAsync($settings.wsurl, $CT)  
    $conn.Status                                                
    While (!$Conn.IsCompleted) { Start-Sleep -Milliseconds 500 }
    $conn.Status
        $Size = 1024
    $Array = [byte[]] @(,0) * $Size
    $Recv = New-Object System.ArraySegment[byte] -ArgumentList @(,$Array)
    While ($WS.State -eq 'Open') {
        #write-host go

        $RTM = ""

        Do {
            #write-host omg
            $Conn = $WS.ReceiveAsync($Recv, $CT)
            $conn.Status
            While (!$Conn.IsCompleted) { Start-Sleep -Milliseconds 500 }
            $conn.Status
            $Recv.Array[0..($Conn.Result.Count - 1)] | ForEach-Object { $RTM = $RTM + [char]$_ }
            $rtm
            if ($rawlog) {
                $ds = get-date -format yyyyMMdd
                $rtm | Out-File ($settings.rawlogdir + $ds + "ovmsraw.json") -Append
            }
            try {
                $json = $null
                if ($fragment -and ($rtm -notmatch '^{')) {
                    $rtm = ($fragment + $rtm ) -join ''
                    write-log -level Verbose -Logger $logger -MessageTemplate "Attempting to merge lines" -ForContext @{'Merged Content' = $rtm}
                }else{
                    $fragment = $null
                }
                $jsonrawboom = $rtm  | ConvertFrom-Json
                Write-LocalJSON -json $rtm
                $json = ( $jsonrawboom | where-object {$_.metrics}).metrics 
                $hashobj = @{}
                foreach ($member in ($json.psobject.members | where-object {$_.membertype -match 'property'}).name){
                        $mclean= $member.Replace('.','_')
                        $hashobj.Add($mclean,$json.$member)
                    }
                if ($json.'v.c.current') {
                    $chargingcurrent = $json.'v.c.current'
                }
                if ($json.'v.c.time') {
                    $ptime = New-TimeSpan -Seconds $json.'v.c.time'
                    $phtime = [string]$ptime.Days + " Days " + $ptime.Hours+':'+$ptime.Minutes
                    $hashobj.Add('TimeElapsed',$phtime )
                    $hashobj.Add('Activity','Charging')
                    $hashobj.Add('KW',$json.'xmi.c.power.ac')
                    $hashobj.Add('kWh',$json.'xmi.c.kwh.ac')
                }elseif ($json.'v.e.parktime') {
                    $ptime = New-TimeSpan -Seconds $json.'v.e.parktime'
                    $phtime = [string]$ptime.Days + " Days " + $ptime.Hours+':'+$ptime.Minutes
                    $hashobj.Add('TimeElapsed',$phtime )
                    $hashobj.Add('Activity','Parked')
                }elseif ($json.'v.e.drivetime') {
                    $ptime = New-TimeSpan -Seconds $json.'v.e.drivetime'
                    $phtime = [string]$ptime.Days + " Days " + $ptime.Hours+':'+$ptime.Minutes
                    $hashobj.Add('TimeElapsed',$phtime )
                    $hashobj.Add('Activity','Drivetime')
                }else{
                    $hashobj.Add('TimeElapsed','' )
                    $hashobj.Add('Activity','')
                }
                if($json.'v.c.voltage'){
                            
                    $hashobj.add('Amps',$chargingcurrent)
                    $kw= 
                    Write-Log -Logger $logger -MessageTemplate "Charging {Voltage}v AC / {Amps}A ({KW}KW) - {kWh} KwH {TimeElapsed} {Activity}" -Properties $json.'v.c.voltage' -Level Information -ForContext $hashobj
                }elseif ($json.'v.b.12v.voltage') {
                            
                            
                            
                    Write-Log -Logger $logger -MessageTemplate "OVMS Accessory Voltage {12v}v after {TimeElapsed} {Activity}" -Properties $json.'v.b.12v.voltage' -Level Information -ForContext $hashobj

                }elseif($json.'xmi.b.soc.real'){
                            
                            

                    $body =  [ordered]@{'TimeElapsed' = $hashobj.TimeElapsed;'SOC' = $json.'xmi.b.soc.real';'Activity' = $hashobj.activity } | convertto-json -Compress

                    Invoke-RestMethod -ContentType 'application/json' -Method Post -Uri $settings.webcorepistonuri -Body $body
                            
                    Write-Log -Logger $logger -MessageTemplate "OVMS Traction Battery {SOC}% SOC after {TimeElapsed} {Activity}" -Properties $json.'xmi.b.soc.real' -Level Information -ForContext $hashobj

                    

                }
                if ($fragment) {
                    Write-Log -Logger $logger -Level Verbose -MessageTemplate 'We think merge worked'
                    $fragment = $null
                }
            }catch{
                write-host unable to log
                if ($fragment) {
                    Write-Log -Logger $logger -MessageTemplate "Failed to merge" -Level Warning -ErrorException $_.exception
                    $fragment = $null
                }else{
                    #$rtm -match ''
                    Write-LocalJSON -json 'FragmentDetected'
                    $fragment = $rtm -join ''
                }
                Write-Log -Logger $logger -MessageTemplate "Unable to Log" -Level Error -ErrorException $_.exception 
            }
            
                    
        } Until ($Conn.Result.Count -lt $Size)

        }

        }catch{
        If ($WS) { 
    Write-Log -Logger $logger -Level Verbose -MessageTemplate "Closing websocket"
    $WS.Dispose()}
    Write-Log -Logger $logger -Level Error -MessageTemplate "Unable to connect to OVMS" -ErrorException $_.exception
        start-sleep 60

        }
        }
