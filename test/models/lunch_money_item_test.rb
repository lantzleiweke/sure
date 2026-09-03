require "test_helper"

class LunchMoneyItemTest < ActiveSupport::TestCase
  test "includes the syncable interface" do
    assert_includes LunchMoneyItem.ancestors, Syncable
    assert_respond_to LunchMoneyItem, :syncable
  end

  test "does not expose its access token in serialization or inspection" do
    item = LunchMoneyItem.new(name: "Lunch Money", access_token: "PRIVATE_TOKEN")
    refute_includes item.to_json, "PRIVATE_TOKEN"
    refute_includes item.inspect, "PRIVATE_TOKEN"
  end
end
