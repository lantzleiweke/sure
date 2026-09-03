# frozen_string_literal: true

class LunchMoneyItemsController < ApplicationController
  before_action :set_lunch_money_item, only: [ :show, :edit, :update, :destroy, :sync, :setup_accounts ]

  def index
    @lunch_money_items = Current.family.lunch_money_items.ordered
  end

  def show
  end

  def new
    @lunch_money_item = Current.family.lunch_money_items.build
  end

  def edit
  end

  def create
    @lunch_money_item = Current.family.lunch_money_items.build(lunch_money_item_params)
    @lunch_money_item.name ||= "LunchMoney Connection"

    if @lunch_money_item.save
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully configured LunchMoney.")
        @lunch_money_items = Current.family.lunch_money_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "lunch_money-providers-panel",
            partial: "settings/providers/lunch_money_panel",
            locals: { lunch_money_items: @lunch_money_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @lunch_money_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "lunch_money-providers-panel",
          partial: "settings/providers/lunch_money_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def update
    if @lunch_money_item.update(lunch_money_item_params)
      if turbo_frame_request?
        flash.now[:notice] = t(".success", default: "Successfully updated LunchMoney configuration.")
        @lunch_money_items = Current.family.lunch_money_items.ordered
        render turbo_stream: [
          turbo_stream.replace(
            "lunch_money-providers-panel",
            partial: "settings/providers/lunch_money_panel",
            locals: { lunch_money_items: @lunch_money_items }
          ),
          *flash_notification_stream_items
        ]
      else
        redirect_to settings_providers_path, notice: t(".success"), status: :see_other
      end
    else
      @error_message = @lunch_money_item.errors.full_messages.join(", ")

      if turbo_frame_request?
        render turbo_stream: turbo_stream.replace(
          "lunch_money-providers-panel",
          partial: "settings/providers/lunch_money_panel",
          locals: { error_message: @error_message }
        ), status: :unprocessable_entity
      else
        redirect_to settings_providers_path, alert: @error_message, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @lunch_money_item.destroy_later
    redirect_to settings_providers_path, notice: t(".success", default: "Scheduled LunchMoney connection for deletion.")
  end

  def sync
    unless @lunch_money_item.syncing?
      @lunch_money_item.sync_later
    end

    respond_to do |format|
      format.html { redirect_back_or_to accounts_path }
      format.json { head :ok }
    end
  end

  def preload_accounts
    # Trigger a sync to fetch accounts from the provider
    lunch_money_item = Current.family.lunch_money_items.first
    unless lunch_money_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    lunch_money_item.sync_later unless lunch_money_item.syncing?
    redirect_to select_accounts_lunch_money_items_path(accountable_type: params[:accountable_type], return_to: params[:return_to])
  end

  def select_accounts
    @accountable_type = params[:accountable_type]
    @return_to = params[:return_to]

    lunch_money_item = Current.family.lunch_money_items.first
    unless lunch_money_item&.credentials_configured?
      redirect_to settings_providers_path, alert: t(".no_credentials_configured")
      return
    end

    @lunch_money_accounts = lunch_money_item.lunch_money_accounts
                                                .left_joins(:account_provider)
                                                .where(account_providers: { id: nil })
                                                .order(:name)
  end

  def setup_accounts
    @unlinked_accounts = @lunch_money_item.unlinked_lunch_money_accounts.order(:name)

    if @unlinked_accounts.empty?
      redirect_to accounts_path, notice: t(".all_accounts_linked")
    end
  end

  private

    def set_lunch_money_item
      @lunch_money_item = Current.family.lunch_money_items.find(params[:id])
    end

    def lunch_money_item_params
      params.require(:lunch_money_item).permit(
        :name,
        :sync_start_date,
        :access_token
      )
    end

end
