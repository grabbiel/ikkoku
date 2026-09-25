$ErrorActionPreference = 'Stop'
$root = (Get-Item -LiteralPath $SourceRoot).FullName
function FileRecord($file, $hash) {
    $record = [ordered]@{path=$file.FullName.Substring($root.Length+1).Replace('\','/'); bytes=$file.Length}
    if ($hash) { $record.sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLower() }
    return [PSCustomObject]$record
}
$players = @(Get-ChildItem -LiteralPath $root -Directory -Filter '*_Data' | ForEach-Object {
    $managed=Test-Path -LiteralPath (Join-Path $_.FullName 'Managed')
    $il2cpp=Test-Path -LiteralPath (Join-Path $_.FullName 'il2cpp_data')
    $backend=if ($il2cpp) {'il2cpp'} elseif ($managed) {'mono'} else {'unknown'}
    $version=$null
    $ggm=Join-Path $_.FullName 'globalgamemanagers'
    if (Test-Path -LiteralPath $ggm) {
        $stream=[IO.File]::OpenRead($ggm)
        try {
            $buffer=New-Object byte[] 256
            $count=$stream.Read($buffer,0,$buffer.Length)
            $match=[regex]::Match([Text.Encoding]::ASCII.GetString($buffer,0,$count),'[0-9]+\.[0-9]+\.[0-9]+[abfp][0-9]+')
            if ($match.Success) {$version=$match.Value}
        } finally {$stream.Dispose()}
    }
    [PSCustomObject]@{dataDirectory=$_.Name; backend=$backend; hasManaged=$managed; hasIl2CppData=$il2cpp; unityVersion=$version}
})
$assemblies = @(foreach ($player in $players) {
    $dir=Join-Path (Join-Path $root $player.dataDirectory) 'Managed'
    if (Test-Path -LiteralPath $dir) {Get-ChildItem -LiteralPath $dir -Filter '*.dll' -File | ForEach-Object {FileRecord $_ $true}}
})
$bundles = @(Get-ChildItem -LiteralPath (Join-Path $root 'abdata') -Recurse -File -Filter '*.unity3d' | ForEach-Object {FileRecord $_ $false})
$tools = @(Get-ChildItem -LiteralPath (Join-Path $root '[MODDING] Tools') -Recurse -File -ErrorAction SilentlyContinue | Where-Object {$_.Extension -in '.exe','.py'} | ForEach-Object {FileRecord $_ $false})
[PSCustomObject]@{schemaVersion=1; sourceRoot=$root; capturedAtUtc=[DateTime]::UtcNow.ToString('o'); players=$players; assemblies=$assemblies; bundles=$bundles; tools=$tools} | ConvertTo-Json -Depth 8
