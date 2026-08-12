$p = "translations/translation_en.xml"
$c = Get-Content $p -Raw
if ($c -contains 'sf_multi_tank_short') { Write-Host "SKIP"; exit 0 }
$s = @"
    <e k="sf_multi_tank_short"             v="Multi-Tank Application" />
    <e k="sf_multi_tank_long"              v="Apply fertilizer to multiple tanks at once (front + rear)" />
    <e k="sf_desc_multiTankApplication"   v="When enabled, applying product also fills or drains secondary tanks proportionally" />
"@
$c = $c -replace '</elements>', "$s`n</elements>"
Set-Content $p $c
Write-Host "OK"