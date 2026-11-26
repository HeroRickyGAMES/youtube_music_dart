#include "include/tomato_player/tomato_player_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tomato_player_plugin.h"

void TomatoPlayerPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tomato_player::TomatoPlayerPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
