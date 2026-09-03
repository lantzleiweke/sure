class AddLunchMoneyTask5Columns < ActiveRecord::Migration[8.1]
  def change
    change_table :lunch_money_items, bulk: true do |t|
      t.datetime :updated_since_watermark
      t.datetime :last_reconciled_at
      t.datetime :full_history_imported_at
    end

    change_table :lunch_money_accounts, bulk: true do |t|
      t.string :plaid_item_id
      t.string :health_state
      t.boolean :allow_transaction_modifications
      t.datetime :balance_last_update
      t.date :import_start_date
      t.datetime :last_fetch
      t.datetime :last_import
      t.datetime :plaid_last_successful_update
      t.string :account_subtype
    end
  end
end
