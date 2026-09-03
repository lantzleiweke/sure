# frozen_string_literal: true

module LunchMoneyItem::Provided
  extend ActiveSupport::Concern

  def lunch_money_provider
    return nil unless credentials_configured?

    Provider::LunchMoney.new(
      access_token: access_token
    )
  end

  # Returns credentials hash for API calls that need them passed explicitly
  def lunch_money_credentials
    return nil unless credentials_configured?

    {
      access_token: access_token
    }
  end
end
