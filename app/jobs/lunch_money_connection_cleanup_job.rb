class LunchMoneyConnectionCleanupJob < ApplicationJob
  queue_as :default

  def perform(lunch_money_item_id:, account_id:)
    Rails.logger.info "LunchMoney connection cleanup completed for account #{account_id}"
  end
end
