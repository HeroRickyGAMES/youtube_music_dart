#include <flutter_linux/flutter_linux.h>
#include <gmock/gmock.h>
#include <gtest/gtest.h>

#include "include/tomato_player/tomato_player_plugin.h"

namespace tomato_player {
namespace test {

// O plugin não expõe API pública além destas; verifica contrato mínimo.
TEST(TomatoPlayerPlugin, HasRegistrationExport) {
  EXPECT_NE(tomato_player_plugin_get_type,
            static_cast<GType (*)(void)>(nullptr));
}

}  // namespace test
}  // namespace tomato_player