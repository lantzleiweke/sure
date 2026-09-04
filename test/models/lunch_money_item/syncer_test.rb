require "test_helper"

class LunchMoneyItem::SyncerTest < ActiveSupport::TestCase
  test "perform_sync processes linked accounts exactly once" do
    family = families(:empty)
    sure_account = family.accounts.create!(name: "Local", balance: 25, currency: "USD", accountable: Depository.new)
    sure_account.set_current_balance(25)
    item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token")
    provider_account = item.lunch_money_accounts.create!(name: "Provider", currency: "USD", lunch_money_account_id: "sync-1", raw_transactions_payload: [])
    provider_account.ensure_account_provider!(sure_account)
    api = Object.new
    api.define_singleton_method(:get_plaid_accounts) { { plaid_accounts: [{ id: "sync-1", display_name: "Provider", currency: "USD", balance: "BAD_BALANCE", status: "active", type: "depository", subtype: "checking" }] } }
    item.define_singleton_method(:lunch_money_provider) { api }
    sync = Sync.create!(syncable: item, status: :syncing, sync_stats: {})
    processor_calls = 0
    LunchMoneyAccount::Processor.any_instance.stubs(:process).with do
      processor_calls += 1
      true
    end
    LunchMoneyItem::Syncer.new(item).perform_sync(sync)
    assert_equal 25, sure_account.reload.balance
    assert_equal 25, sure_account.balance
    assert_equal 1, processor_calls
    assert DebugLogEntry.where(provider_key: "lunch_money").exists?
  end
end
