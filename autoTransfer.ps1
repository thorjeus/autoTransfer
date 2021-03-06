### Changelog:
### * fixed "Mandatory parameter 'amount' was not sent" error
### * fixed "Invoke-WebRequest Fails with SSL/TLS Secure Channel" error

$version = "v1.0.3"
[Net.ServicePointManager]::SecurityProtocol = "tls12, tls11, tls"
$path = Split-Path $MyInvocation.MyCommand.Path
$accountSettings = gc "$($path)\autoTransfer.json" -ea silentlyContinue | ConvertFrom-Json
if (!($accountSettings)) { write-host "Cannot find autoTransfer.json file!" -foregroundcolor "DarkRed" -backgroundcolor "yellow"; sleep 30 ; exit }
write-host "`n`n`n`n`n`n`n`n`n`n"

function checkLatest () {
    $repo = "daisy613/autoTransfer"
    $releases = "https://api.github.com/repos/$repo/releases"
    $latestTag = (Invoke-WebRequest $releases | ConvertFrom-Json)[0].tag_name | out-null
    $youngerVer = ($version, $latestTag | Sort-Object)[-1]
    if ($latestTag -and $version -ne $youngerVer) {
        write-log -string "Your version of AutoTransfer [$($version)] is outdated. Newer version [$($latestTag)] is available here: https://github.com/$($repo)/releases/tag/$($latestTag)" -color "Red"
    }
}

Function write-log {
    Param ([string]$string,$color)
    $Logfile = "$($path)\autoTransfer.log"
    $date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$date] $string" -ForegroundColor $color
    Add-Content $Logfile -Value "[$date] $string"
}

function betterSleep () {
    Param ($seconds,$message)
    $doneDT = (Get-Date).AddSeconds($seconds)
    while($doneDT -gt (Get-Date)) {
        $hours = [math]::Round(($seconds / 3600),2)
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -Activity "$($message)" -Status "Sleeping $($hours) hour(s)..." -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
    }
    Write-Progress -Activity "$($message)" -Status "Sleeping $($hours) hour(s)..." -SecondsRemaining 0 -Completed
}

function getAccount () {
    $TimeStamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $QueryString = "&recvWindow=5000&timestamp=$TimeStamp"
    $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha.key = [Text.Encoding]::ASCII.GetBytes($accountSettings.secret)
    $signature = $hmacsha.ComputeHash([Text.Encoding]::ASCII.GetBytes($QueryString))
    $signature = [System.BitConverter]::ToString($signature).Replace('-', '').ToLower()
    $uri = "https://fapi.binance.com/fapi/v1/account?$QueryString&signature=$signature"
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("X-MBX-APIKEY", $accountSettings.key)
    $accountInformation = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
    return $accountInformation
}

function getProfit () {
    Param ($hours)
    # https://binance-docs.github.io/apidocs/futures/en/#get-income-history-user_data
    $start = (Get-Date).AddHours(-$hours)
    $startTime = ([DateTimeOffset]$start).ToUnixTimeMilliseconds()
    $limit = "1000"    # max 1000
    $results = @()
    while ($true) {
        $TimeStamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $QueryString = "&recvWindow=5000&limit=$limit&timestamp=$TimeStamp&startTime=$startTime"
        $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
        $hmacsha.key = [Text.Encoding]::ASCII.GetBytes($accountSettings.secret)
        $signature = $hmacsha.ComputeHash([Text.Encoding]::ASCII.GetBytes($QueryString))
        $signature = [System.BitConverter]::ToString($signature).Replace('-', '').ToLower()
        $uri = "https://fapi.binance.com/fapi/v1/income?$QueryString&signature=$signature"
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("X-MBX-APIKEY", $accountSettings.key)
        $result = @()
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
        $results += $result
        if ($result.length -lt 1000) { break }
        $startTime = [int64]($result.time | sort)[-1] + 1
    }
    $results = $results | ? { $_.incomeType -ne "TRANSFER" }
    $sum = 0
    $results | % { $sum += $_.income }
    return $sum
}

# https://binance-docs.github.io/apidocs/spot/en/#new-future-account-transfer-user_data
function transferFunds () {
    Param ($transferAmount)
    $type = 2
    $asset = "USDT"
    $amount = $transferAmount
    $TimeStamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $QueryString = "&type=$($type)&asset=$($asset)&amount=$($amount)&recvWindow=5000&timestamp=$($TimeStamp)"
    $hmacsha = New-Object System.Security.Cryptography.HMACSHA256
    $hmacsha.key = [Text.Encoding]::ASCII.GetBytes($accountSettings.secret)
    $signature = $hmacsha.ComputeHash([Text.Encoding]::ASCII.GetBytes($QueryString))
    $signature = [System.BitConverter]::ToString($signature).Replace('-', '').ToLower()
    $uriopenorders = "https://api.binance.com/sapi/v1/futures/transfer?$QueryString&signature=$signature"
    $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
    $headers.Add("X-MBX-APIKEY", $accountSettings.key)
    $tranId = (Invoke-RestMethod -Uri $uriopenorders -Headers $headers -Method Post).tranId
    return $tranId
}

function sendDiscord () {
    Param($webHook,$message)
    $hookUrl = $webHook
    if ($hookUrl) {
        $content = $message
        $payload = [PSCustomObject]@{
            content = $content
        }
        Invoke-RestMethod -Uri $hookUrl -Method Post -Body ($payload | ConvertTo-Json) -ContentType 'Application/Json'
    }
}

while ($true) {
    checkLatest
    ### Get current account info and profit
    $profit = getProfit $accountSettings.hours
    $accountInformation = getAccount
    $totalWalletBalance = [math]::Round(($accountInformation.totalWalletBalance), 2)
    try { $marginUsedPercentCurr = (([decimal] $accountInformation.totalInitialMargin + [decimal] $accountInformation.totalMaintMargin) / $accountInformation.totalWalletBalance) * 100 }
    catch { $marginUsedPercentCurr = 100 }
    $transferAmount = $accountSettings.profitPercent * $($profit) / 100

    ### check if used margin percentage is less than defined, and total remaining balance is more than defined. if conditions don't apply, retry once an hour
    while (($marginUsedPercentCurr -gt $accountSettings.maxMarginUsedPercent) -or ($accountSettings.minRemainingBalance -gt ($totalWalletBalance - $transferAmount)) -or $profit -le 0) {
        write-log -string "account[$($accountSettings.name)] totalBalance[$($totalWalletBalance)] currentUsedMargin[$([math]::Round(($marginUsedPercentCurr), 1))%] $($accountSettings.hours)hourProfit[$([math]::Round(($profit), 2))]" -color "Yellow"
        write-log -string "Conditions not fulfilled. Waiting 1 hr to retry..." -color "Yellow"
        $message = "**TRANSFER**: FAILURE  **account**: $($accountSettings.number)  **totalBalance**: $($totalWalletBalance)  **$($accountSettings.hours)hourProfit**: $([math]::Round(($profit), 2))"
        sendDiscord $accountSettings.discord $message
        betterSleep 3600 "AutoTransfer Reattempt (conditions not fulfilled)"
        ### Get current account info and profit
        $profit = getProfit $accountSettings.hours
        $accountInformation = getAccount
        $totalWalletBalance = [math]::Round(($accountInformation.totalWalletBalance), 2)
        try { $marginUsedPercentCurr = (([decimal] $accountInformation.totalInitialMargin + [decimal] $accountInformation.totalMaintMargin) / $accountInformation.totalWalletBalance) * 100 }
        catch { $marginUsedPercentCurr = 100 }
        $transferAmount = $accountSettings.profitPercent * $($profit) / 100
    }

    ### perform the transfer of ($percentsOfProfit * $profit) to Spot
    $tranId = transferFunds $transferAmount
    write-log -string "Transfer Successful!" -color "Green"
    write-log -string "account[$($accountSettings.name)] totalBalance[$($totalWalletBalance)] currentUsedMargin[$([math]::Round($marginUsedPercentCurr,1))%] $($accountSettings.hours)hourProfit[$([math]::Round(($profit), 2))] transferred[$([math]::Round(($transferAmount),2))] tranId[$($tranId)]" -color "Green"
    ### send discord message
    $message = "**TRANSFER**: SUCCESS  **account**: $($accountSettings.name)  **totalBalance**: $($totalWalletBalance)  **$($accountSettings.hours)hourProfit**: $([math]::Round(($profit), 2))  **transferred**: $([math]::Round(($transferAmount),2))  **tranId**: $($tranId)"
    sendDiscord $accountSettings.discord $message

    ### sleep for $hours
    betterSleep ($accountSettings.hours * 3600) "AutoTransfer"
}
