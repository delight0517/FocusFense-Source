#ifndef RUNNER_GAME_BUDGET_OVERLAY_H_
#define RUNNER_GAME_BUDGET_OVERLAY_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

class GameBudgetOverlay {
 public:
  explicit GameBudgetOverlay(flutter::BinaryMessenger* messenger);
  ~GameBudgetOverlay();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_GAME_BUDGET_OVERLAY_H_
