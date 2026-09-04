require "test_helper"

class LunchMoneyItem::SyncerTest < ActiveSupport::TestCase
  test "perform_sync processes linked accounts exactly once" do
    family = families(:empty)
    sure_account = family.accounts.create!(name: "Local", balance: 25, currency: "USD", accountable: Depository.new)
    sure_account.set_current_balance(25)
    item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token", updated_since_watermark: 1.day.ago)
    provider_account = item.lunch_money_accounts.create!(name: "Provider", currency: "USD", lunch_money_account_id: "sync-1", raw_transactions_payload: [])
    provider_account.ensure_account_provider!(sure_account)
    api = Object.new
    api.define_singleton_method(:get_plaid_accounts) { { plaid_accounts: [{ id: "sync-1", display_name: "Provider", currency: "USD", balance: 10, status: "active", type: "depository", subtype: "checking" }] } }
    api.define_singleton_method(:get_transactions) { |**| [] }
    item.define_singleton_method(:lunch_money_provider) { api }
    sync = Sync.create!(syncable: item, status: :syncing, sync_stats: {})
    LunchMoneyItem::Syncer.new(item).perform_sync(sync)
    assert_equal 10, sure_account.reload.balance
    assert_equal 10, sure_account.balance
    assert item.reload.updated_since_watermark > 1.day.ago
  end

  test "retains watermark when transaction processing raises" do
    item, sync, api = sync_fixture(watermark: 2.days.ago, raw_transactions_payload: [{ "id" => "tx" }])
    api.define_singleton_method(:get_transactions) { |**| [] }
    LunchMoneyAccount::Transactions::Processor.any_instance.stubs(:process).raises(StandardError, "processor failed")

    assert_raises(StandardError) { LunchMoneyItem::Syncer.new(item).perform_sync(sync) }
    assert_in_delta 2.days.ago.to_f, item.reload.updated_since_watermark.to_f, 1.second
  end

  test "retains watermark when a later account transaction fetch fails" do
    item, sync, api = sync_fixture(watermark: 2.days.ago, account_ids: %w[first second])
    api.define_singleton_method(:get_transactions) do |**kwargs|
      raise Provider::LunchMoney::Error.new("failed", :server_error) if kwargs[:plaid_account_id] == "second"
      []
    end

    assert_raises(Provider::LunchMoney::Error) { LunchMoneyItem::Syncer.new(item).perform_sync(sync) }
    assert_in_delta 2.days.ago.to_f, item.reload.updated_since_watermark.to_f, 1.second
  end

  private

    def sync_fixture(watermark:, account_ids: ["sync-1"], raw_transactions_payload: nil)
      family = families(:empty)
      item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token", updated_since_watermark: watermark)
      account_ids.each do |id|
        sure_account = family.accounts.create!(name: "Local #{id}", balance: 25, currency: "USD", accountable: Depository.new)
        sure_account.set_current_balance(25)
        account = item.lunch_money_accounts.create!(name: id, currency: "USD", lunch_money_account_id: id, raw_transactions_payload: raw_transactions_payload || [])
        account.ensure_account_provider!(sure_account)
      end
      api = Object.new
      api.define_singleton_method(:get_plaid_accounts) do
        { plaid_accounts: account_ids.map { |id| { id: id, display_name: id, currency: "USD", balance: 10, status: "active", type: "depository", subtype: "checking" } } }
      end
      item.define_singleton_method(:lunch_money_provider) { api }
      [item, Sync.create!(syncable: item, status: :syncing, sync_stats: {}), api]
    end
end
