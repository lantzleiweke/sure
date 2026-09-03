require "test_helper"

class Settings::ProvidersLunchMoneyPanelTest < ActionDispatch::IntegrationTest
  test "registers the Lunch Money family panel" do
    panel = Settings::ProvidersController::FAMILY_PANELS.find { |entry| entry[:key] == "lunch_money" }

    assert_equal "Lunch Money", panel[:title]
    assert_equal "lunch_money", panel[:turbo_id]
    assert_equal "lunch_money_panel", panel[:partial]
    assert_equal "LunchMoneyItem", Settings::ProvidersController::PANEL_SYNCABLE_TYPES.fetch("lunch_money")
  end
end
