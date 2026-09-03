# frozen_string_literal: true

class LunchMoneyItem::Syncer
  include SyncStats::Collector

  attr_reader :lunch_money_item

  def initialize(lunch_money_item)
    @lunch_money_item = lunch_money_item
  end

  def perform_sync(sync)
    Rails.logger.info "LunchMoneyItem::Syncer - Starting sync for item #{lunch_money_item.id}"

    # Phase 1: Import data from provider API
    sync.update!(status_text: I18n.t("lunch_money_items.sync.status.importing")) if sync.respond_to?(:status_text)
    lunch_money_item.import_latest_lunch_money_data(sync: sync)

    # Phase 2: Collect setup statistics
    finalize_setup_counts(sync)

    # Phase 3: Process data for linked accounts
    linked_lunch_money_accounts = lunch_money_item.linked_lunch_money_accounts.includes(account_provider: :account)
    if linked_lunch_money_accounts.any?
      sync.update!(status_text: I18n.t("lunch_money_items.sync.status.processing")) if sync.respond_to?(:status_text)
      mark_import_started(sync)
      lunch_money_item.process_accounts

      # Phase 4: Schedule balance calculations
      sync.update!(status_text: I18n.t("lunch_money_items.sync.status.calculating")) if sync.respond_to?(:status_text)
      lunch_money_item.schedule_account_syncs(
        parent_sync: sync,
        window_start_date: sync.window_start_date,
        window_end_date: sync.window_end_date
      )

      # Phase 5: Collect statistics
      account_ids = linked_lunch_money_accounts.filter_map { |pa| pa.current_account&.id }
      collect_transaction_stats(sync, account_ids: account_ids, source: "lunch_money")
    end

    # Mark sync health
    collect_health_stats(sync, errors: nil)
  rescue Provider::LunchMoney::AuthenticationError => e
    lunch_money_item.update!(status: :requires_update)
    collect_health_stats(sync, errors: [ { message: e.message, category: "auth_error" } ])
    raise
  rescue => e
    collect_health_stats(sync, errors: [ { message: e.message, category: "sync_error" } ])
    raise
  end

  # Public: called by Sync after finalization
  def perform_post_sync
    # Override for post-sync cleanup if needed
  end

  private

    def mark_import_started(sync)
      # Mark that we're now processing imported data
      sync.update!(status_text: I18n.t("lunch_money_items.sync.status.importing_data")) if sync.respond_to?(:status_text)
    end

    def finalize_setup_counts(sync)
      sync.update!(status_text: I18n.t("lunch_money_items.sync.status.checking_setup")) if sync.respond_to?(:status_text)

      unlinked_count = lunch_money_item.unlinked_accounts_count

      if unlinked_count > 0
        lunch_money_item.update!(pending_account_setup: true)
        sync.update!(status_text: I18n.t("lunch_money_items.sync.status.needs_setup", count: unlinked_count)) if sync.respond_to?(:status_text)
      else
        lunch_money_item.update!(pending_account_setup: false)
      end

      # Collect setup stats
      collect_setup_stats(sync, provider_accounts: lunch_money_item.lunch_money_accounts)
    end
end
