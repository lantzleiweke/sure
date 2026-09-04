module LunchMoney
  class AccountStatusMapper
    STALE_AFTER = 3.days

    RECONNECT = %w[relink error revoked not\ found].freeze
    NOT_SYNCING = %w[inactive closed deactivated not\ supported].freeze

    attr_reader :account_status, :balance_last_update

    def initialize(account_status:, balance_last_update: nil, sync_succeeded: false, provider_failure: nil)
      @account_status = account_status.to_s
      @balance_last_update = balance_last_update
      @sync_succeeded = sync_succeeded
      @provider_failure = provider_failure
    end

    def health_state
      return :requires_reconnect if RECONNECT.include?(account_status)
      return :not_syncing if NOT_SYNCING.include?(account_status)
      return :pending_setup if account_status == "syncing"
      return :healthy if account_status == "active"

      :unknown
    end

    def stale_balance?
      timestamp = parse_timestamp
      timestamp.nil? || timestamp < STALE_AFTER.ago
    end

    def item_requires_update?
      health_state == :requires_reconnect && @provider_failure != :transient
    end

    def actionable_message
      "Reconnect this account in Lunch Money."
    end

    private

      def parse_timestamp
        return balance_last_update.to_time if balance_last_update.is_a?(Time) || balance_last_update.is_a?(DateTime) || balance_last_update.is_a?(ActiveSupport::TimeWithZone)

        Time.iso8601(balance_last_update.to_s)
      rescue ArgumentError, TypeError
        nil
      end
  end
end
