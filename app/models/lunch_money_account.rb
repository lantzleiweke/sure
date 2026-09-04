# frozen_string_literal: true

class LunchMoneyAccount < ApplicationRecord
  include PlaidAccount::TypeMappable
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
      name: data[:display_name] || data[:name] || data[:account_name],
      account_number: data[:mask],
      current_balance: parse_decimal(data.key?(:balance) ? data[:balance] : data[:current_balance]),
      currency: extract_currency(data, fallback: "USD"),
      account_status: data[:status] || data[:account_status],
      account_type: data[:type] || data[:account_type],
      account_subtype: map_subtype(data[:type] || data[:account_type], data[:subtype]),
      plaid_item_id: data[:plaid_item_id],
      provider: data[:provider] || data[:brokerage_name],
      institution_metadata: extract_institution_metadata(data),
      raw_payload: account_data
    )
    apply_health!(status: data[:status] || data[:account_status], balance_last_update: data[:balance_last_update])
  end

  def apply_health!(status:, balance_last_update: nil, provider_failure: nil)
    return unless persisted?

    self.account_status = status
    self.balance_last_update = balance_last_update if respond_to?(:balance_last_update=)
    mapper = LunchMoney::AccountStatusMapper.new(account_status: status, balance_last_update: balance_last_update, provider_failure: provider_failure)
    update!(account_status: status, balance_last_update: balance_last_update, health_state: mapper.health_state)
    lunch_money_item.update!(status: :requires_update) if mapper.item_requires_update?
  end

  def reconnect_message
    LunchMoney::AccountStatusMapper.new(account_status: account_status).actionable_message
  end

  def health_state_for_sync(sync_succeeded: false, provider_failure: nil)
    LunchMoney::AccountStatusMapper.new(
      account_status: account_status,
      balance_last_update: balance_last_update,
      sync_succeeded: sync_succeeded,
      provider_failure: provider_failure
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
