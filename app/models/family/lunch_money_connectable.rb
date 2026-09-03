module Family::LunchMoneyConnectable
  extend ActiveSupport::Concern

  included do
    has_many :lunch_money_items, dependent: :destroy
  end

  def can_connect_lunch_money?
    # Families can configure their own LunchMoney credentials
    true
  end

  def create_lunch_money_item!(access_token:, item_name: nil)
    lunch_money_item = lunch_money_items.create!(
      name: item_name || "Lunch Money Connection",
      access_token: access_token
    )

    lunch_money_item.sync_later

    lunch_money_item
  end

  def has_lunch_money_credentials?
    lunch_money_items.where.not(access_token: nil).exists?
  end
end
