require "test_helper"

class LunchMoneyAccountTest < ActiveSupport::TestCase
  setup do
    @item = LunchMoneyItem.create!(family: families(:empty), name: "Lunch Money", access_token: "token")
  end

  test "persists reconnect health and marks the parent item" do
    account = @item.lunch_money_accounts.create!(name: "Checking", currency: "USD")
    account.upsert_from_lunch_money!(id: 42, display_name: "Checking", currency: "USD", status: "relink", type: "depository", subtype: "checking")
    assert_equal "relink", account.reload.account_status
    assert_equal "requires_reconnect", account.health_state
    assert_equal "requires_update", @item.reload.status
    assert_includes account.reconnect_message, "Lunch Money"
  end

  test "persists fresh active health without changing a good parent item" do
    account = @item.lunch_money_accounts.create!(name: "Checking", currency: "USD")
    account.upsert_from_lunch_money!(id: 42, display_name: "Checking", currency: "USD", status: "active", balance_last_update: Time.current, type: "depository", subtype: "checking")
    assert_equal "active", account.reload.account_status
    assert_equal "healthy", account.health_state
    assert_equal "good", @item.reload.status
  end

  test "transient provider failure leaves a good parent item unchanged" do
    account = @item.lunch_money_accounts.create!(name: "Checking", currency: "USD")
    account.apply_health!(status: "error", balance_last_update: Time.current, provider_failure: :transient)
    assert_equal "good", @item.reload.status
  end

  test "maps a Plaid account snapshot without replacing an explicit zero balance" do
    account = LunchMoneyAccount.new(name: "Existing", currency: "USD")
    account.expects(:update!).with(has_entries(lunch_money_account_id: "42", name: "Checking", current_balance: BigDecimal("0"), account_type: "depository", account_subtype: "checking")).returns(true)
    account.upsert_from_lunch_money!(id: 42, display_name: "Checking", mask: "1234", currency: "USD", balance: 0, status: "active", type: "depository", subtype: "checking", institution_name: "Bank", plaid_item_id: "item", raw: "raw")
  end

  test "preserves nil balance in a provider snapshot" do
    account = LunchMoneyAccount.new(name: "Existing", currency: "USD")
    account.expects(:update!).with(has_entries(current_balance: nil)).returns(true)
    account.upsert_from_lunch_money!(id: 42, display_name: "Checking", currency: "USD", balance: nil, type: "depository", subtype: "checking")
  end

  test "uses provider identity for item-scoped uniqueness" do
    indexes = LunchMoneyAccount.connection.indexes(:lunch_money_accounts)
    index = indexes.find { |candidate| candidate.unique && candidate.columns == %w[lunch_money_item_id lunch_money_account_id] }
    assert index
    assert_equal "(lunch_money_account_id IS NOT NULL)", index.where
  end
end
