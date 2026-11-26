#include <flutter/method_call.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <gtest/gtest.h>
#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include "tomato_player_plugin.h"

namespace tomato_player {
namespace test {

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResultFunctions;

EncodableMap MakeMap(const std::string& key, const std::string& value) {
  return {{EncodableValue(key), EncodableValue(value)}};
}

}  // namespace

TEST(TomatoPlayerPlugin, OpenWithoutCreateReturnsNotCreated) {
  TomatoPlayerPlugin plugin(nullptr);

  // Guarda o código do erro retornado.
  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("open",
                 std::make_unique<EncodableValue>(MakeMap("uri", "https://x"))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string&,
                        const EncodableValue*) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "not_created");
}

TEST(TomatoPlayerPlugin, UnknownPropertyWithoutEngineIsError) {
  TomatoPlayerPlugin plugin(nullptr);

  std::string error_code;
  plugin.HandleMethodCall(
      MethodCall("setProperty",
                 std::make_unique<EncodableValue>(MakeMap("name", "volume"))),
      std::make_unique<MethodResultFunctions<>>(
          nullptr,
          [&error_code](const std::string& code, const std::string&,
                        const EncodableValue*) { error_code = code; },
          nullptr));

  EXPECT_EQ(error_code, "not_created");
}

}  // namespace test
}  // namespace tomato_player