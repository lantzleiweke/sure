# frozen_string_literal: true

class LunchMoneyAccount < ApplicationRecord
  include CurrencyNormalizable
  include LunchMoneyAccount::DataHelpers

  belongs_to :lunch_money_item

  # Association through account_providers
  has_one :account_provider, as: :provider, dependent: :destroy
  has_one :account, through: :account_provider, source: :account
  has_one :linked_account, through: :account_provider, source: :account

  validates :name, :currency, presence: true

  # Scopes
  scope :with_linked, -> { joins(:account_provider) }
  scope :without_linked, -> { left_joins(:account_provider).where(account_providers: { id: nil }) }
  scope :ordered, -> { order(created_at: :desc) }

  # Callbacks
  after_destroy :enqueue_connection_cleanup

  # Helper to get account using account_providers system
  def current_account
    account
  end

  # Idempotently create or update AccountProvider link
  # CRITICAL: After creation, reload association to avoid stale nil
  def ensure_account_provider!(linked_account)
    return nil unless linked_account

    provider = account_provider || build_account_provider
    provider.account = linked_account
    provider.save!

    # Reload to clear cached nil value
    reload_account_provider
    account_provider
  end

  def upsert_from_lunch_money!(account_data)
    # Convert SDK object to hash if needed
    data = sdk_object_to_hash(account_data).with_indifferent_access

    # TODO: Customize this mapping based on your provider's API response
    update!(
      lunch_money_account_id: (data[:id] || data[:account_id])&.to_s,
      name: data[:name] || data[:account_name],
      current_balance: parse_decimal(data[:balance] || data[:current_balance]),
      currency: extract_currency(data, fallback: "USD"),
      account_status: data[:status] || data[:account_status],
      account_type: data[:type] || data[:account_type],
      provider: data[:provider] || data[:brokerage_name],
      institution_metadata: extract_institution_metadata(data),
      raw_payload: account_data
    )
  end

  def upsert_lunch_money_transactions_snapshot!(transactions_snapshot)
    assign_attributes(
      raw_transactions_payload: transactions_snapshot
    )

    save!
  end

  private

    def extract_institution_metadata(data)
      {
        name: data[:institution_name] || data.dig(:institution, :name),
        logo: data[:institution_logo] || data.dig(:institution, :logo),
        domain: data[:institution_domain] || data.dig(:institution, :domain)
      }.compact
    end

    def enqueue_connection_cleanup
      return unless lunch_money_item

      LunchMoneyConnectionCleanupJob.perform_later(
        lunch_money_item_id: lunch_money_item.id,
        account_id: id
      )
    end

    def log_invalid_currency(currency_value)
      Rails.logger.warn("Invalid currency code '#{currency_value}' for LunchMoney account #{id}, defaulting to USD")
    end
end
