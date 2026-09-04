require "test_helper"

class LunchMoneyAccount::Transactions::ProcessorTest < ActiveSupport::TestCase
  test "persists real LM entries, skips non-money rows, deduplicates, and protects user edits" do
    family = families(:empty)
    sure = family.accounts.create!(name: "Checking", balance: 100, currency: "USD", accountable: Depository.new)
    provider_item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token")
    provider_account = provider_item.lunch_money_accounts.create!(name: "Checking", currency: "USD", lunch_money_account_id: "real-1", raw_transactions_payload: [
      { id: "child", amount: 12, date: "2026-01-01", payee: "Shop", original_name: "Original", merchant: "Shop Co", to_base: 13, currency: "usd", group_parent_id: "parent" },
      { id: "parent", amount: 12, date: "2026-01-01", is_group_parent: true },
      { id: "pending", amount: 1, date: "2026-01-01", is_pending: true },
      { id: "deleted", amount: 1, date: "2026-01-01", status: "delete_pending" }
    ])
    provider_account.ensure_account_provider!(sure)

    result = LunchMoneyAccount::Transactions::Processor.new(provider_account).process
    assert_equal 1, result[:imported]
    assert_equal 1, result[:skipped_parents]
    assert_equal 1, result[:skipped_pending]
    assert_equal 1, result[:skipped_delete_pending]
    entry = sure.entries.find_by(external_id: "lunch_money_child", source: "lunch_money")
    assert entry
    assert_equal(-12, entry.amount.to_f)
    assert_equal "Shop", entry.name
    assert_equal "usd", entry.currency.downcase
    assert_equal "Original", entry.transaction.extra["original_name"]
    assert_equal "Shop Co", entry.transaction.extra["merchant"]
    assert_equal 13, entry.transaction.extra["to_base"]
    assert_equal 1, sure.entries.where(external_id: "lunch_money_child").count

    entry.transaction.update!(extra: { "user_note" => "User Note" })
    entry.update!(user_modified: true)
    provider_account.update!(raw_transactions_payload: [{ id: "child", amount: 99, date: "2026-01-01", payee: "Changed", currency: "usd" }])
    LunchMoneyAccount::Transactions::Processor.new(provider_account).process
    assert_equal 1, sure.entries.where(external_id: "lunch_money_child", source: "lunch_money").count
    entry.reload
    assert_equal(-12, entry.amount.to_f)
    assert_equal "Shop", entry.name
    assert_equal "User Note", entry.transaction.extra["user_note"]
  end

  test "maps posted children, inverts LM sign, and skips non-money rows" do
    account = Struct.new(:currency, :family, :id) do
      def current_account = self
      def present? = true
    end.new("USD", nil, "account-1")
    provider_account = Struct.new(:id, :current_account, :raw_transactions_payload).new("provider-1", account, [
      { id: 1, amount: 12.5, date: "2026-01-01", payee: "Shop", original_name: "Original", currency: "usd" },
      { id: 2, amount: -5, date: "2026-01-01", is_group_parent: true },
      { id: 3, amount: 4, date: "2026-01-01", is_pending: true },
      { id: 4, amount: 4, date: "2026-01-01", status: "delete_pending" }
    ])
    adapter = Object.new
    adapter.define_singleton_method(:import_transaction) { |**kwargs| @kwargs = kwargs; true }
    Account::ProviderImportAdapter.stub :new, adapter do
      result = LunchMoneyAccount::Transactions::Processor.new(provider_account).process
      assert_equal 1, result[:imported]
      assert_equal 3, result[:skipped]
      assert_equal 1, result[:skipped_parents]
      assert_equal 1, result[:skipped_pending]
      assert_equal 1, result[:skipped_delete_pending]
    end
  end
end
