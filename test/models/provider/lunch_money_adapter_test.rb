require "test_helper"

class Provider::LunchMoneyAdapterTest < ActiveSupport::TestCase
  test "registers Lunch Money accounts and exposes banking connection config" do
    assert Provider::Factory.registered?("LunchMoneyAccount")
    assert_equal %w[Depository CreditCard Loan], Provider::LunchMoneyAdapter.supported_account_types
    family = Minitest::Mock.new
    family.expect :can_connect_lunch_money?, true
    config = Provider::LunchMoneyAdapter.connection_configs(family: family).first
    assert_equal "lunch_money", config[:key]
    assert config[:new_account_path].call("Depository", "/accounts")
    family.verify
  end
end
