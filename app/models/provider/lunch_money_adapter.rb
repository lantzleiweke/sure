class Provider::LunchMoneyAdapter < Provider::Base
  include Provider::Syncable
  include Provider::InstitutionMetadata

  # Register this adapter with the factory
  Provider::Factory.register("LunchMoneyAccount", self)

  # Define which account types this provider supports
  def self.supported_account_types
    # Banking providers typically support these account types
    # TODO: Adjust based on your provider's capabilities
    %w[Depository CreditCard Loan]
  end

  # Returns connection configurations for this provider
  def self.connection_configs(family:)
    return [] unless family.can_connect_lunch_money?

    [ {
      key: "lunch_money",
      name: "Lunch Money",
      description: "Connect to your bank via Lunch Money",
      can_connect: true,
      new_account_path: ->(accountable_type, return_to) {
        Rails.application.routes.url_helpers.select_accounts_lunch_money_items_path(
          accountable_type: accountable_type,
          return_to: return_to
        )
      },
    } ]
  end

  def provider_name
    "lunch_money"
  end

  # Build a LunchMoney provider instance with family-specific credentials
  # @param family [Family] The family to get credentials for (required)
  # @return [Provider::LunchMoney, nil] Returns nil if credentials are not configured
  def self.build_provider(family: nil)
    return nil unless family.present?

    # Get family-specific credentials
    lunch_money_item = family.lunch_money_items.where.not(access_token: nil).first
    return nil unless lunch_money_item&.credentials_configured?

    # TODO: Implement provider initialization
    # Provider::LunchMoney.new(
    #   lunch_money_item.access_token
    # )
    raise NotImplementedError, "Implement Provider::LunchMoney.new in #{__FILE__}"
  end

  def sync_path
    Rails.application.routes.url_helpers.sync_lunch_money_item_path(item)
  end

  def item
    provider_account.lunch_money_item
  end


  def institution_domain
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    domain = metadata["domain"]
    url = metadata["url"]

    # Derive domain from URL if missing
    if domain.blank? && url.present?
      begin
        domain = URI.parse(url).host&.gsub(/^www\./, "")
      rescue URI::InvalidURIError
        Rails.logger.warn("Invalid institution URL for LunchMoney account #{provider_account.id}: #{url}")
      end
    end

    domain
  end

  def institution_name
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["name"] || item&.institution_name
  end

  def institution_url
    metadata = provider_account.institution_metadata
    return nil unless metadata.present?

    metadata["url"] || item&.institution_url
  end

  def institution_color
    item&.institution_color
  end
end
