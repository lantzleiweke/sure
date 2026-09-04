require "test_helper"

class LunchMoney::AccountStatusMapperTest < ActiveSupport::TestCase
  MAPPINGS = {
    "active" => :healthy,
    "syncing" => :pending_setup,
    "relink" => :requires_reconnect,
    "error" => :requires_reconnect,
    "revoked" => :requires_reconnect,
    "not found" => :requires_reconnect,
    "inactive" => :not_syncing,
    "closed" => :not_syncing,
    "deactivated" => :not_syncing,
    "not supported" => :not_syncing,
    "some_new_status" => :unknown
  }.freeze

  test "maps every Lunch Money account status" do
    MAPPINGS.each do |status, expected|
      assert_equal expected, LunchMoney::AccountStatusMapper.new(account_status: status).health_state
    end
  end

  test "flags balances older than three days as stale even after a successful sync" do
    mapper = LunchMoney::AccountStatusMapper.new(account_status: "active", balance_last_update: 3.days.ago - 1.minute, sync_succeeded: true)
    assert mapper.stale_balance?
    refute LunchMoney::AccountStatusMapper.new(account_status: "active", balance_last_update: 3.days.ago + 1.minute, sync_succeeded: true).stale_balance?
  end

  test "treats missing or malformed balance timestamps conservatively as stale" do
    assert LunchMoney::AccountStatusMapper.new(account_status: "active", balance_last_update: nil).stale_balance?
    assert LunchMoney::AccountStatusMapper.new(account_status: "active", balance_last_update: "not-a-timestamp").stale_balance?
  end

  test "requires reconnect metadata is actionable in Lunch Money and marks the item" do
    mapper = LunchMoney::AccountStatusMapper.new(account_status: "relink")
    assert_equal :requires_reconnect, mapper.health_state
    assert_equal true, mapper.item_requires_update?
    assert_includes mapper.actionable_message, "Lunch Money"
    refute LunchMoney::AccountStatusMapper.new(account_status: "active").item_requires_update?
  end

  test "does not mark an item for ordinary transient provider failures" do
    refute LunchMoney::AccountStatusMapper.new(account_status: "error", provider_failure: :transient).item_requires_update?
  end
end
