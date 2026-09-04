# frozen_string_literal: true

class LunchMoneyItem < ApplicationRecord
  attr_accessor :reconcile_deletion_suppressed_account_ids
  attr_accessor :unavailable_balance_account_ids
  include Syncable, Provided, Unlinking

  enum :status, { good: "good", requires_update: "requires_update" }, default: :good

  # Helper to detect if ActiveRecord Encryption is configured for this app
  def self.encryption_ready?
    creds_ready = Rails.application.credentials.active_record_encryption.present?
    env_ready = ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"].present? &&
                ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"].present?
    creds_ready || env_ready
  end

  # Encrypt sensitive credentials if ActiveRecord encryption is configured
  if encryption_ready?
    encrypts :access_token, deterministic: true
  end

  validates :name, presence: true
  validates :access_token, presence: true, on: :create

  belongs_to :family
  has_one_attached :logo, dependent: :purge_later

  has_many :lunch_money_accounts, dependent: :destroy
  has_many :accounts, through: :lunch_money_accounts

  def as_json(options = nil)
    super(options).except("access_token")
  end

  scope :active, -> { where(scheduled_for_deletion: false) }
  scope :ordered, -> { order(created_at: :desc) }
  scope :needs_update, -> { where(status: :requires_update) }
  # Family::Syncer discovers provider items reflectively and calls `syncable` on every
  # `*_items` association whose model includes Syncable. Omitting this scope breaks the
  # whole nightly family sync, not just this provider.
  scope :syncable, -> { active }

  def reconcile_deletion_suppressed_account_ids
    @reconcile_deletion_suppressed_account_ids ||= []
  end

  def syncer
    LunchMoneyItem::Syncer.new(self)
  end

  def destroy_later
    update!(scheduled_for_deletion: true)
    DestroyJob.perform_later(self)
  end


  # Import data from provider API
  def import_latest_lunch_money_data(sync: nil)
    provider = lunch_money_provider
    unless provider
      Rails.logger.error "LunchMoneyItem #{id} - Cannot import: provider is not configured"
      raise StandardError, I18n.t("lunch_money_items.errors.provider_not_configured")
    end

    LunchMoneyItem::Importer.new(self, lunch_money_provider: provider, sync: sync).import
  rescue => e
    Rails.logger.error "LunchMoneyItem #{id} - Failed to import data: #{e.message}"
    raise
  end

  # Process linked accounts after data import
  def process_accounts(unavailable_balance_account_ids: self.unavailable_balance_account_ids || [])
    return [] if lunch_money_accounts.empty?

    results = []
    linked_lunch_money_accounts.includes(account_provider: :account).each do |lunch_money_account|
      begin
        result = LunchMoneyAccount::Processor.new(lunch_money_account, unavailable_balance_account_ids: unavailable_balance_account_ids).process
        raise "Lunch Money transaction processing failed" unless result[:success]
        results << { lunch_money_account_id: lunch_money_account.id, success: true, result: result }
      rescue => e
        Rails.logger.error "LunchMoneyItem #{id} - Failed to process account #{lunch_money_account.id}: #{e.message}"
        results << { lunch_money_account_id: lunch_money_account.id, success: false, error: e.message }
        raise
      end
    end

    results
  end

  # Schedule sync jobs for all linked accounts
  def schedule_account_syncs(parent_sync: nil, window_start_date: nil, window_end_date: nil)
    return [] if accounts.empty?

    results = []
    accounts.visible.each do |account|
      begin
        account.sync_later(
          parent_sync: parent_sync,
          window_start_date: window_start_date,
          window_end_date: window_end_date
        )
        results << { account_id: account.id, success: true }
      rescue => e
        Rails.logger.error "LunchMoneyItem #{id} - Failed to schedule sync for account #{account.id}: #{e.message}"
        results << { account_id: account.id, success: false, error: e.message }
      end
    end

    results
  end

  def upsert_lunch_money_snapshot!(accounts_snapshot)
    assign_attributes(
      raw_payload: accounts_snapshot
    )

    save!
  end

  def has_completed_initial_setup?
    accounts.any?
  end

  # Linked accounts (have AccountProvider association)
  def linked_lunch_money_accounts
    lunch_money_accounts.joins(:account_provider)
  end

  # Unlinked accounts (no AccountProvider association)
  def unlinked_lunch_money_accounts
    lunch_money_accounts.left_joins(:account_provider).where(account_providers: { id: nil })
  end

  def sync_status_summary
    total_accounts = total_accounts_count
    linked_count = linked_accounts_count
    unlinked_count = unlinked_accounts_count

    if total_accounts == 0
      I18n.t("lunch_money_items.sync_status.no_accounts")
    elsif unlinked_count == 0
      I18n.t("lunch_money_items.sync_status.synced", count: linked_count)
    else
      I18n.t("lunch_money_items.sync_status.synced_with_setup", linked: linked_count, unlinked: unlinked_count)
    end
  end

  def linked_accounts_count
    lunch_money_accounts.joins(:account_provider).count
  end

  def unlinked_accounts_count
    lunch_money_accounts.left_joins(:account_provider).where(account_providers: { id: nil }).count
  end

  def total_accounts_count
    lunch_money_accounts.count
  end

  def institution_display_name
    institution_name.presence || institution_domain.presence || name
  end

  def connected_institutions
    lunch_money_accounts.includes(:account)
                  .where.not(institution_metadata: nil)
                  .map { |acc| acc.institution_metadata }
                  .uniq { |inst| inst["name"] || inst["institution_name"] }
  end

  def institution_summary
    institutions = connected_institutions
    case institutions.count
    when 0
      I18n.t("lunch_money_items.institution_summary.none")
    else
      I18n.t("lunch_money_items.institution_summary.count", count: institutions.count)
    end
  end

  def credentials_configured?
    access_token.present?
  end

  def mark_requires_update!
    update!(status: :requires_update)
  end
end
