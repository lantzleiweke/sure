require "test_helper"

class Settings::ProvidersLunchMoneyPanelTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "registers the Lunch Money family panel" do
    panel = Settings::ProvidersController::FAMILY_PANELS.find { |entry| entry[:key] == "lunch_money" }

    assert_equal "Lunch Money", panel[:title]
    assert_equal "lunch_money", panel[:turbo_id]
    assert_equal "lunch_money_panel", panel[:partial]
    assert_equal "LunchMoneyItem", Settings::ProvidersController::PANEL_SYNCABLE_TYPES.fetch("lunch_money")
  end

  test "provider sync queues an idle Lunch Money item once" do
    sign_in users(:family_admin)
    item = LunchMoneyItem.create!(family: families(:dylan_family), name: "Lunch Money", access_token: "token")

    assert_enqueued_jobs 1, only: SyncJob do
      post sync_provider_settings_providers_path(provider_key: "lunch_money")
    end
    assert_redirected_to settings_providers_path
  end

  test "family reflective sync includes Lunch Money items" do
    assert_includes Family::Syncer.new(families(:dylan_family)).send(:syncable_item_associations), :lunch_money_items
  end
end
