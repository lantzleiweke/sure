# Lunch Money provider integration points

Implementation checklist for a family-scoped banking provider, based on the current
Lunch Flow implementation and the provider-family generator guide.

## Generator-shaped files and registrations

The generator guide (`docs/api/rails_provider_generator.md`, “Provider:Family
Generator”) describes the generated migration, item/account models, `Provided`
concern, adapter, controller, manual settings panel, routes, and settings-controller
updates. For a provider named `lunch_money`, the generated convention is the
corresponding `LunchMoney*` names; the existing source below uses `lunchflow` names.

- [ ] Generate the family item/account tables and credential columns. The current
  analogous records are `LunchflowItem` (`app/models/lunchflow_item.rb`) and
  `LunchflowAccount` (`app/models/lunchflow_account.rb`), joined by
  `has_many :lunchflow_accounts` / `belongs_to :lunchflow_item`.
- [ ] Generate the item `Provided` concern. Current
  `LunchflowItem::Provided#lunchflow_provider` builds `Provider::Lunchflow` with
  the family item credentials (`app/models/lunchflow_item/provided.rb`).
- [ ] Include `Syncable`, `Provided`, `Unlinking`, and `Encryptable` in the item;
  current inclusion is in `LunchflowItem`.
- [ ] Add the family association/connectable concern. Current
  `Family::LunchflowConnectable` (`app/models/family/lunchflow_connectable.rb`)
  adds `has_many :lunchflow_items`, `can_connect_lunchflow?`,
  `create_lunchflow_item!`, and `has_lunchflow_credentials?`; it is included by
  `Family` (`app/models/family.rb`).
- [ ] Generate the adapter and register it explicitly. Current
  `Provider::LunchflowAdapter` includes `Provider::Syncable` and
  `Provider::InstitutionMetadata`, then calls
  `Provider::Factory.register("LunchflowAccount", self)` at class load
  (`app/models/provider/lunchflow_adapter.rb`). `Provider::Factory` discovers
  `app/models/provider/*_adapter.rb` and constantizes each file
  (`app/models/provider/factory.rb`).
- [ ] Implement family credential construction and connection configs in the
  adapter: `build_provider(family:)`, `supported_account_types`, and
  `connection_configs(family:)`. Current supported types are
  `Depository`, `CreditCard`, `Loan`, and `Investment`; paths use
  `select_accounts_lunchflow_items_path` and
  `select_existing_account_lunchflow_items_path`.
- [ ] Add the item controller and matching view partial names. Current controller
  is `LunchflowItemsController` (`app/controllers/lunchflow_items_controller.rb`)
  and renders/streams `lunchflow_items/setup_required`,
  `lunchflow_items/api_error`, `lunchflow_items/lunchflow_item`, and
  `settings/providers/lunchflow_panel`. Existing files include
  `app/views/settings/providers/_lunchflow_panel.html.erb` and
  `app/views/lunchflow_items/_lunchflow_item.html.erb`.

## Manual hardcoded settings registrations

These are not provided by the provider configuration registry and must be added to
the family-panel lists and dispatch paths in
`app/controllers/settings/providers_controller.rb`:

- [ ] Add `{ key: "lunchflow", title: "Lunch Flow", turbo_id: "lunchflow",
  partial: "lunchflow_panel" }` to `FAMILY_PANELS` (current lines 190–211).
- [ ] Add `"lunchflow" => "LunchflowItem"` to `PANEL_SYNCABLE_TYPES` (current
  lines 215–237).
- [ ] Add the `when "lunchflow"` branch in `load_provider_items`, assigning
  `@lunchflow_items = Current.family.lunchflow_items.ordered`.
- [ ] Load the settings-page collection in `prepare_show_context`; current source
  filters `api_key` and selects `:id`.
- [ ] Map `"lunchflow" => @lunchflow_items` in `family_panel_items` so sync-health
  computation can query `PANEL_SYNCABLE_TYPES`.
- [ ] Ensure the settings view renders the panel partial and the panel’s
  `turbo_id`; the current panel uses `settings.providers.lunchflow_panel.*`
  translation keys and posts to `lunchflow_items_path` or
  `lunchflow_item_path`.
- [ ] Keep the family-panel status branch in `app/helpers/settings_helper.rb`:
  `when "lunchflow"` checks `@lunchflow_items`.

## Routes and locale keys

- [ ] Add the family item routes in `config/routes.rb`: `resources
  :lunchflow_items` for `index`, `new`, `create`, `show`, `edit`, `update`, and
  `destroy`; collection `GET preload_accounts`, `GET select_accounts`, `POST
  link_accounts`, `GET select_existing_account`, `POST link_existing_account`;
  member `POST sync`, `GET setup_accounts`, and `POST complete_account_setup`.
- [ ] Add the provider-panel connect-form routes under `settings/providers`: the
  generic `GET :connect_form` route receives `provider_key`; current route names
  are `connect_form_settings_providers_path`-shaped and are dispatched by
  `Settings::ProvidersController#connect_form`.
- [ ] Add/maintain locale files under `config/locales/views/lunchflow_items/`.
  The English source is `config/locales/views/lunchflow_items/en.yml` and covers
  `api_error`, `setup_required`, `create`, `destroy`, `index`, `loading`,
  `link_accounts`, `lunchflow_item`, `select_accounts`,
  `select_existing_account`, `link_existing_account`, `setup_accounts`,
  `complete_account_setup`, `sync`, and `update`. The settings panel uses
  `config/locales/views/settings/providers/en.yml` keys under
  `settings.providers.lunchflow_panel`.

## Sync and import integration

- [ ] Provide `LunchflowItem::Syncer`, `LunchflowItem::Importer`, account and
  entry processors. Current files are `app/models/lunchflow_item/syncer.rb`,
  `app/models/lunchflow_item/importer.rb`, `app/models/lunchflow_account/processor.rb`,
  and `app/models/lunchflow_entry/processor.rb`.
- [ ] Use `AccountProvider` for the provider link. Current
  `LunchflowAccount` has polymorphic `has_one :account_provider`; the controller
  creates `AccountProvider` with `provider: lunchflow_account`.
  `Account::ProviderImportAdapter` imports entries keyed by both `external_id`
  and `source`, and recognizes `lunchflow` pending metadata.
- [ ] Preserve adapter metadata methods from
  `Provider::InstitutionMetadata`; current Lunch Flow overrides domain, name,
  URL, and color in `Provider::LunchflowAdapter`.
- [ ] Do not add scheduler registration: `Family::Syncer#syncable_item_associations`
  reflects on `Family` `has_many` associations whose names end in `_items` and
  whose classes include `Syncable`. It therefore auto-discovers
  `lunchflow_items` once the association and concern are present.

## Current-source finding / plan mismatch

The requested connector is called “Lunch Money,” but the current integration and
generator example are named `Lunchflow` / “Lunch Flow” throughout. No
`LunchMoney` class, route, locale namespace, or provider key appears in the
examined source. The implementation must resolve that naming mismatch before
using the generated `lunch_money` names; this document records the current
`lunchflow` registration points without introducing new behavior.
