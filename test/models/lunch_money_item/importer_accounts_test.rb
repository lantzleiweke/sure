require "test_helper"

class LunchMoneyItem::ImporterAccountsTest < ActiveSupport::TestCase
  setup do
    @item = LunchMoneyItem.create!(family: families(:empty), name: "Lunch Money", access_token: "token")
    @provider = Minitest::Mock.new
    @importer = LunchMoneyItem::Importer.new(@item, lunch_money_provider: @provider)
  end

  test "discovers and persists Plaid account snapshots while ignoring manual accounts" do
    @provider.expect :get_plaid_accounts, { plaid_accounts: [ { id: 7, display_name: "Checking", mask: "1234", currency: "USD", balance: 0, status: "active", type: "depository", subtype: "checking", plaid_item_id: "pi" }, { id: 8, display_name: "Manual", type: "manual" } ] }
    @importer.send(:import_accounts, nil)
    account = @item.lunch_money_accounts.find_by(lunch_money_account_id: "7")
    assert_equal "Checking", account.name
    assert_equal 0, account.current_balance.to_i
    assert_equal "active", account.account_status
    assert_equal "healthy", account.health_state
    assert_nil @item.lunch_money_accounts.find_by(lunch_money_account_id: "8")
    @provider.verify
  end

  test "relink marks item and pruning removes only unlinked disappeared accounts" do
    linked = @item.lunch_money_accounts.create!(name: "Linked", currency: "USD", lunch_money_account_id: "1")
    linked.ensure_account_provider!(Account.create!(family: families(:empty), name: "Sure", currency: "USD", balance: 0, accountable: Depository.new))
    @item.lunch_money_accounts.create!(name: "Gone", currency: "USD", lunch_money_account_id: "2")
    @provider.expect :get_plaid_accounts, { plaid_accounts: [ { id: 1, display_name: "Linked", currency: "USD", status: "relink", type: "depository", subtype: "checking", plaid_item_id: "new" } ] }
    @importer.send(:import_accounts, nil)
    assert_equal "requires_update", @item.reload.status
    assert LunchMoneyAccount.exists?(linked.id)
    refute LunchMoneyAccount.exists?(lunch_money_account_id: "2")
    @provider.verify
  end

  test "normalizes string-key Plaid accounts and preserves all account metadata" do
    @provider.expect :get_plaid_accounts, { "plaid_accounts" => [{ "id" => 9, "display_name" => "Savings", "mask" => "9876", "currency" => "CAD", "balance" => "12.50", "status" => "active", "type" => "depository", "subtype" => "savings", "plaid_item_id" => "p9", "allow_transaction_modifications" => false, "balance_last_update" => "2026-09-03T00:00:00Z", "import_start_date" => "2020-01-01" }] }
    @importer.send(:import_accounts, nil)
    account = @item.lunch_money_accounts.first
    assert_equal "Savings", account.name
    assert_equal "9876", account.account_number
    assert_equal "CAD", account.currency
    assert_equal "p9", account.plaid_item_id
    assert_equal false, account.allow_transaction_modifications
    assert_equal Date.parse("2020-01-01"), account.import_start_date
  end

  test "blank or provider-error account responses never prune" do
    existing = @item.lunch_money_accounts.create!(name: "Existing", currency: "USD", lunch_money_account_id: "old")
    @provider.expect :get_plaid_accounts, { "plaid_accounts" => [] }
    @importer.send(:import_accounts, nil)
    assert LunchMoneyAccount.exists?(existing.id)
    failing_provider = Object.new
    failing_provider.define_singleton_method(:get_plaid_accounts) { raise Provider::LunchMoney::Error.new("boom", :server_error) }
    @importer = LunchMoneyItem::Importer.new(@item, lunch_money_provider: failing_provider)
    assert_raises(Provider::LunchMoney::Error) { @importer.send(:import_accounts, nil) }
    assert LunchMoneyAccount.exists?(existing.id)
  end

  test "nil and empty collection responses never prune" do
    existing = @item.lunch_money_accounts.create!(name: "Existing", currency: "USD", lunch_money_account_id: "old")
    [nil, []].each do |response|
      provider = Object.new
      provider.define_singleton_method(:get_plaid_accounts) { response }
      LunchMoneyItem::Importer.new(@item, lunch_money_provider: provider).send(:import_accounts, nil)
      assert LunchMoneyAccount.exists?(existing.id)
    end
  end

  test "relink guard denies reconciliation only for changed nonblank Plaid item IDs" do
    account = @item.lunch_money_accounts.create!(name: "Existing", currency: "USD", lunch_money_account_id: "old", plaid_item_id: "same")
    provider = Object.new
    provider.define_singleton_method(:get_plaid_accounts) { { plaid_accounts: [{ id: "old", display_name: "Existing", currency: "USD", status: "active", type: "depository", subtype: "checking", plaid_item_id: "same" }] } }
    importer = LunchMoneyItem::Importer.new(@item, lunch_money_provider: provider)
    importer.send(:import_accounts, nil)
    assert importer.reconciliation_deletion_allowed_for?(account)

    provider.define_singleton_method(:get_plaid_accounts) { { plaid_accounts: [{ id: "old", display_name: "Existing", currency: "USD", status: "active", type: "depository", subtype: "checking", plaid_item_id: "changed" }] } }
    importer.send(:import_accounts, nil)
    refute importer.reconciliation_deletion_allowed_for?(account.reload)
  end

  test "invalid balance preserves linked Sure balance and logs one sanitized diagnostic" do
    account = @item.lunch_money_accounts.create!(name: "Existing", currency: "USD", lunch_money_account_id: "old", current_balance: 10)
    @provider.expect :get_plaid_accounts, { plaid_accounts: [{ id: "old", display_name: "Existing", currency: "USD", balance: "BAD_BALANCE_SENTINEL", status: "active", type: "depository", subtype: "checking" }] }
    @importer.send(:import_accounts, nil)
    assert_equal 10, account.reload.current_balance
    entry = DebugLogEntry.order(created_at: :desc).first
    assert_equal "lunch_money", entry.provider_key
    refute_includes entry.metadata.to_s, "BAD_BALANCE_SENTINEL"
  end

  test "NaN and infinity balances preserve the linked balance" do
    account = @item.lunch_money_accounts.create!(name: "Existing", currency: "USD", lunch_money_account_id: "special", current_balance: 10)
    account.update_columns(current_balance: 10)
    @provider.expect :get_plaid_accounts, { plaid_accounts: [{ id: "special", display_name: "Existing", currency: "USD", balance: "NaN", status: "active", type: "depository", subtype: "checking" }, { id: "infinity", display_name: "Other", currency: "USD", balance: "Infinity", status: "active", type: "depository", subtype: "checking" }] }
    @importer.send(:import_accounts, nil)
    assert_equal 10, account.reload.current_balance
    @provider.verify
  end

  test "missing linked balance preserves the Sure account and current anchor" do
    sure_account = Account.create!(family: families(:empty), name: "Linked", currency: "USD", balance: 25, accountable: Depository.new)
    sure_account.set_current_balance(25)
    provider_account = @item.lunch_money_accounts.create!(name: "Linked", currency: "USD", lunch_money_account_id: "linked")
    provider_account.ensure_account_provider!(sure_account)
    @provider.expect :get_plaid_accounts, { plaid_accounts: [{ id: "linked", display_name: "Linked", currency: "USD", status: "active", type: "depository", subtype: "checking", balance: nil }] }
    @importer.send(:import_accounts, nil)
    assert_equal 25, sure_account.reload.balance
    assert_equal 25, sure_account.balance
    assert_equal sure_account.id, provider_account.reload.account_provider.account_id
  end

  test "normal import flow preserves linked balance across reload for unavailable balance" do
    sure_account = Account.create!(family: families(:empty), name: "Linked", currency: "USD", balance: 25, accountable: Depository.new)
    sure_account.set_current_balance(25)
    provider_account = @item.lunch_money_accounts.create!(name: "Linked", currency: "USD", lunch_money_account_id: "flow", current_balance: 10)
    provider_account.ensure_account_provider!(sure_account)
    @provider.expect :get_plaid_accounts, { plaid_accounts: [{ id: "flow", display_name: "Linked", currency: "USD", balance: "BAD_BALANCE", status: "active", type: "depository", subtype: "checking" }] }
    @importer.import
    assert_equal 25, sure_account.reload.balance
    assert_equal 25, sure_account.balance
    assert DebugLogEntry.where(provider_key: "lunch_money").exists?
  end
end
