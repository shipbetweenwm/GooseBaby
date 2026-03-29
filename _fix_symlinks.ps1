$symDir = "e:\baby\GooseBaby\windows\flutter\ephemeral\.plugin_symlinks"
$cache = "C:\Users\Admin\AppData\Local\Pub\Cache\hosted\pub.dev"

$plugins = @{
    "hotkey_manager_windows" = "hotkey_manager_windows-0.2.0"
    "media_kit_libs_windows_video" = "media_kit_libs_windows_video-1.0.11"
    "media_kit_video" = "media_kit_video-2.0.1"
    "screen_retriever_windows" = "screen_retriever_windows-0.2.0"
    "system_tray" = "system_tray-2.0.3"
    "window_manager" = "window_manager-0.4.3"
}

foreach ($name in $plugins.Keys) {
    $target = Join-Path $cache $plugins[$name]
    $link = Join-Path $symDir $name
    if (Test-Path $link) { Remove-Item $link -Force -Recurse }
    Write-Host "Creating junction: $link -> $target"
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}
Write-Host "Done!"
