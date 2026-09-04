# frozen_string_literal: true

class LunchMoneyAccount::Processor
  include LunchMoneyAccount::DataHelpers

  attr_reader :lunch_money_account

  def initialize(lunch_money_account, unavailable_balance_account_ids: [])
    @lunch_money_account = lunch_money_account
    @unavailable_balance_account_ids = unavailable_balance_account_ids
  end

  def process
    account = lunch_money_account.current_account
    return unless account

    Rails.logger.info "LunchMoneyAccount::Processor - Processing account #{lunch_money_account.id} -> Sure account #{account.id}"

    # Update account balance FIRST (before processing transactions/holdings/activities)
    update_account_balance(account)

    # Process transactions
    transactions_count = lunch_money_account.raw_transactions_payload&.size || 0
    Rails.logger.info "LunchMoneyAccount::Processor - Transactions payload has #{transactions_count} items"

    if lunch_money_account.raw_transactions_payload.present?
      Rails.logger.info "LunchMoneyAccount::Processor - Processing transactions..."
      LunchMoneyAccount::Transactions::Processor.new(lunch_money_account).process
    else
      Rails.logger.warn "LunchMoneyAccount::Processor - No transactions payload to process"
    end

    # Trigger immediate UI refresh so entries appear in the activity feed
    account.broadcast_sync_complete
    Rails.logger.info "LunchMoneyAccount::Processor - Broadcast sync complete for account #{account.id}"

    { transactions_processed: transactions_count > 0 }
  end

  private

    def update_account_balance(account)
      return if @unavailable_balance_account_ids.include?(lunch_money_account.id)

      # Get balance from provider data
      return if lunch_money_account.current_balance.nil?
      balance = lunch_money_account.current_balance

      # Banking sign convention:
      # - CreditCard and Loan accounts may need sign inversion
      # Provider returns negative for positive balance, so we negate it
      if account.accountable_type == "CreditCard" || account.accountable_type == "Loan"
        balance = -balance
      end

      Rails.logger.info "LunchMoneyAccount::Processor - Balance update: #{balance}"

      account.assign_attributes(
        balance: balance,
        cash_balance: balance,
        currency: lunch_money_account.currency || account.currency
      )
      account.save!

      # Create or update the current balance anchor valuation for linked accounts
      # This is critical for reverse sync to work correctly
      account.set_current_balance(balance)
    end
end
