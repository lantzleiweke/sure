# frozen_string_literal: true

class LunchMoneyItem::Importer
  include SyncStats::Collector
  include LunchMoneyAccount::DataHelpers

  attr_reader :lunch_money_item, :lunch_money_provider, :sync

  def initialize(lunch_money_item, lunch_money_provider:, sync: nil)
    @lunch_money_item = lunch_money_item
    @lunch_money_provider = lunch_money_provider
    @sync = sync
  end

  class CredentialsError < StandardError; end

  def reconciliation_deletion_allowed_for?(account)
    !lunch_money_item.reconcile_deletion_suppressed_account_ids.include?(account.id)
  end

  def import
    lunch_money_item.reconcile_deletion_suppressed_account_ids.clear
    @unavailable_balance_account_ids = []
    lunch_money_item.unavailable_balance_account_ids = @unavailable_balance_account_ids
    Rails.logger.info "LunchMoneyItem::Importer - Starting import for item #{lunch_money_item.id}"

    credentials = lunch_money_item.lunch_money_credentials
    unless credentials
      raise CredentialsError, "No LunchMoney credentials configured for item #{lunch_money_item.id}"
    end

    # Step 1: Fetch and store all accounts
    import_accounts(credentials)

    # Step 2: For LINKED accounts only, fetch data
    # Unlinked accounts just need basic info (name, balance) for the setup modal
    linked_accounts = LunchMoneyAccount
      .where(lunch_money_item_id: lunch_money_item.id)
      .joins(:account_provider)

    Rails.logger.info "LunchMoneyItem::Importer - Found #{linked_accounts.count} linked accounts to process"

    linked_accounts.each do |lunch_money_account|
      Rails.logger.info "LunchMoneyItem::Importer - Processing linked account #{lunch_money_account.id}"
      import_account_data(lunch_money_account, credentials)
    end

    # Update raw payload on the item
    lunch_money_item.upsert_lunch_money_snapshot!(stats)
  rescue Provider::LunchMoney::AuthenticationError => e
    lunch_money_item.update!(status: :requires_update)
    raise
  end

  private

    def stats
      @stats ||= {}
    end

    def persist_stats!
      return unless sync&.respond_to?(:sync_stats)
      merged = (sync.sync_stats || {}).merge(stats)
      sync.update_columns(sync_stats: merged)
    end

    def import_accounts(credentials)
      Rails.logger.info "LunchMoneyItem::Importer - Fetching accounts"

      response = lunch_money_provider.get_plaid_accounts
      accounts_data = if response.nil? || response.is_a?(Array)
        response || []
      else
        response[:plaid_accounts] || response["plaid_accounts"] || response
      end
      accounts_data = Array(accounts_data).map { |account| sdk_object_to_hash(account).with_indifferent_access }

      stats["api_requests"] = stats.fetch("api_requests", 0) + 1
      stats["total_accounts"] = accounts_data.size

      # Track upstream account IDs to detect removed accounts
      upstream_account_ids = []

      accounts_data.each do |account_data|
        begin
          next if account_data[:type].to_s == "manual"
          id = account_data[:id] || account_data[:account_id]
          next if id.blank?
          upstream_account_ids << id.to_s
          import_account(account_data, credentials)
        rescue => e
          Rails.logger.error "LunchMoneyItem::Importer - Failed to import account: #{e.message}"
          stats["accounts_skipped"] = stats.fetch("accounts_skipped", 0) + 1
          register_error(e, account_data: account_data)
        end
      end

      persist_stats!

      # Clean up accounts that no longer exist upstream
      prune_removed_accounts(upstream_account_ids) if upstream_account_ids.any?
    end

    def import_account(account_data, credentials)
      id = (account_data[:id] || account_data[:account_id]).to_s
      account = lunch_money_item.lunch_money_accounts.find_or_initialize_by(lunch_money_account_id: id)
      previous_plaid_item_id = account.plaid_item_id
      previous_balance = account.current_balance
      incoming_balance = account_data[:balance]
      unavailable_balance = incoming_balance.nil? || invalid_balance?(incoming_balance)
      @unavailable_balance_account_ids ||= []
      @unavailable_balance_account_ids << account.id if unavailable_balance
      account.upsert_from_lunch_money!(account_data)
      if incoming_balance.nil? || invalid_balance?(incoming_balance)
        account.current_balance = previous_balance
        account.save!
        capture_balance_failure(account, incoming_balance)
      end
      account.update!(
        plaid_item_id: account_data[:plaid_item_id],
        allow_transaction_modifications: account_data[:allow_transaction_modifications],
        balance_last_update: account_data[:balance_last_update],
        import_start_date: account_data[:import_start_date],
        last_fetch: account_data[:last_fetch],
        last_import: account_data[:last_import],
        plaid_last_successful_update: account_data[:plaid_last_successful_update],
        health_state: account.health_state_for_sync.health_state
      )
      account.update_columns(current_balance: previous_balance) if incoming_balance.nil? || invalid_balance?(incoming_balance)
      if previous_plaid_item_id.present? && previous_plaid_item_id != account.plaid_item_id
        @relink_detected_account_ids ||= []
        @relink_detected_account_ids << account.id
        lunch_money_item.reconcile_deletion_suppressed_account_ids << account.id
        lunch_money_item.update!(status: :requires_update)
      end

      stats["accounts_imported"] = stats.fetch("accounts_imported", 0) + 1
    end

    def import_account_data(lunch_money_account, credentials)
      # Import transactions
      import_transactions(lunch_money_account, credentials)
    end

    def import_transactions(lunch_money_account, credentials)
      Rails.logger.info "LunchMoneyItem::Importer - Fetching transactions for account #{lunch_money_account.id}"

      begin
        # Determine date range
        start_date = calculate_transaction_start_date(lunch_money_account)
        end_date = Date.current

        # TODO: Implement API call to fetch transactions
        # transactions_data = lunch_money_provider.get_transactions(
        #   account_id: lunch_money_account.lunch_money_account_id,
        #   start_date: start_date,
        #   end_date: end_date
        # )
        transactions_data = []

        stats["api_requests"] = stats.fetch("api_requests", 0) + 1

        if transactions_data.any?
          # Convert SDK objects to hashes and merge with existing
          transactions_hashes = transactions_data.map { |t| sdk_object_to_hash(t) }
          merged = merge_transactions(lunch_money_account.raw_transactions_payload || [], transactions_hashes)
          lunch_money_account.upsert_lunch_money_transactions_snapshot!(merged)
          stats["transactions_found"] = stats.fetch("transactions_found", 0) + transactions_data.size
        end
      rescue => e
        Rails.logger.warn "LunchMoneyItem::Importer - Failed to fetch transactions: #{e.message}"
        register_error(e, context: "transactions", account_id: lunch_money_account.id)
      end
    end

    def calculate_transaction_start_date(lunch_money_account)
      # Use user-specified start date if available
      user_start = lunch_money_account.sync_start_date
      return user_start if user_start.present?

      # For accounts with existing transactions, use incremental sync
      existing_count = (lunch_money_account.raw_transactions_payload || []).size
      if existing_count >= 10 && lunch_money_item.last_synced_at.present?
        # Incremental: go back 7 days from last sync to catch updates
        (lunch_money_item.last_synced_at - 7.days).to_date
      else
        # Full sync: go back 90 days
        90.days.ago.to_date
      end
    end

    def merge_transactions(existing, new_transactions)
      # Merge by ID, preferring newer data
      by_id = {}
      existing.each { |t| by_id[transaction_key(t)] = t }
      new_transactions.each { |t| by_id[transaction_key(t)] = t }
      by_id.values
    end

    def transaction_key(transaction)
      transaction = transaction.with_indifferent_access if transaction.is_a?(Hash)
      # Use ID if available, otherwise generate key from date/amount/description
      transaction[:id] || transaction["id"] ||
        [ transaction[:date], transaction[:amount], transaction[:description] ].join("-")
    end

    def prune_removed_accounts(upstream_account_ids)
      return if upstream_account_ids.empty?

      # Find accounts that exist locally but not upstream
      removed = lunch_money_item.lunch_money_accounts.without_linked
        .where.not(lunch_money_account_id: upstream_account_ids)

      if removed.any?
        Rails.logger.info "LunchMoneyItem::Importer - Pruning #{removed.count} removed accounts"
        removed.destroy_all
      end
    end

    def invalid_balance?(value)
      !BigDecimal(value.to_s).finite?
    rescue ArgumentError, TypeError
      true
    end

    def capture_balance_failure(account, value)
      DebugLogEntry.capture(
        category: "provider_sync", level: "warn", source: self.class.name,
        family: lunch_money_item.family, account: account.account, account_provider: account.account_provider,
        provider_key: "lunch_money", message: "Lunch Money balance was unavailable",
        metadata: { lunch_money_account_id: account.lunch_money_account_id, reason: value.nil? ? "missing" : "invalid" }
      )
    end

    def register_error(error, **context)
      stats["errors"] ||= []
      stats["errors"] << {
        message: error.message,
        context: context.to_s,
        timestamp: Time.current.iso8601
      }
    end
end
