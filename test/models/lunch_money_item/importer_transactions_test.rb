require "test_helper"

class LunchMoneyItem::ImporterTransactionsTest < ActiveSupport::TestCase
  test "fetches account transactions with overlap, merges snapshots, and advances watermark after success" do
    family = families(:empty)
    item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token")
    account = item.lunch_money_accounts.create!(name: "Checking", currency: "USD", lunch_money_account_id: "7", raw_transactions_payload: [{ "id" => "old" }])
    provider = Object.new
    provider.define_singleton_method(:get_transactions) do |**kwargs|
      @kwargs = kwargs
      [{ "id" => "new", "amount" => 1, "date" => "2026-01-01" }, { "id" => "delete", "status" => "delete_pending" }]
    end
    importer = LunchMoneyItem::Importer.new(item, lunch_money_provider: provider)
    importer.send(:import_transactions, account, nil)
    assert_empty importer.send(:stats).fetch("errors", [])
    assert_equal %w[delete new old], account.reload.raw_transactions_payload.map { |row| row["id"] }.sort
    assert_nil item.reload.updated_since_watermark
    assert_equal "7", provider.instance_variable_get(:@kwargs)[:plaid_account_id]
    assert_equal 2000, provider.instance_variable_get(:@kwargs)[:limit]
  end

  test "does not advance watermark after provider failure" do
    family = families(:empty)
    item = LunchMoneyItem.create!(family: family, name: "Lunch Money", access_token: "token")
    account = item.lunch_money_accounts.create!(name: "Checking", currency: "USD", lunch_money_account_id: "7")
    provider = Object.new
    provider.define_singleton_method(:get_transactions) { |**| raise Provider::LunchMoney::Error.new("failed", :server_error) }
    importer = LunchMoneyItem::Importer.new(item, lunch_money_provider: provider)
    assert_raises(Provider::LunchMoney::Error) { importer.send(:import_transactions, account, nil) }
    assert_nil item.reload.updated_since_watermark
  end

  test "uses stored watermark minus 24 hours without writing it per account" do
    item = LunchMoneyItem.create!(family: families(:empty), name: "Lunch Money", access_token: "token", updated_since_watermark: Time.utc(2026, 1, 3, 12))
    account = item.lunch_money_accounts.create!(name: "Checking", currency: "USD", lunch_money_account_id: "7")
    provider = Object.new
    provider.define_singleton_method(:get_transactions) { |**kwargs| @kwargs = kwargs; [] }
    importer = LunchMoneyItem::Importer.new(item, lunch_money_provider: provider)
    importer.send(:import_transactions, account, nil)
    assert_equal "2026-01-02T12:00:00Z", provider.instance_variable_get(:@kwargs)[:updated_since]
    assert_equal Time.utc(2026, 1, 3, 12), item.reload.updated_since_watermark
  end

  test "accumulates delete_pending counts across accounts" do
    item = LunchMoneyItem.create!(family: families(:empty), name: "Lunch Money", access_token: "token")
    first = item.lunch_money_accounts.create!(name: "One", currency: "USD", lunch_money_account_id: "1")
    second = item.lunch_money_accounts.create!(name: "Two", currency: "USD", lunch_money_account_id: "2")
    provider = Object.new
    provider.define_singleton_method(:get_transactions) { |**kwargs| [{ "id" => kwargs[:plaid_account_id], "status" => "delete_pending" }] }
    importer = LunchMoneyItem::Importer.new(item, lunch_money_provider: provider)
    importer.send(:import_transactions, first, nil)
    importer.send(:import_transactions, second, nil)
    assert_equal 2, importer.send(:stats)["delete_pending"]
  end
end
