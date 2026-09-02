# Lunch Money integration points

This checklist records the current Sure integration points for the approved
Lunch Money design. It is a source-map, not an instruction to duplicate every
nearby provider's behavior.

## Generator output versus manual additions

`Provider::FamilyGenerator#update_settings_controller` generates only the
`prepare_show_context` item-assignment and item-exclusion logic in
`app/controllers/settings/providers_controller.rb`. It does **not** generate
the family panel or panel-sync registrations, or the panel item-loading
helpers. `FAMILY_PANELS`, `PANEL_SYNCABLE_TYPES`, `load_provider_items`, and
`family_panel_items` are manual hardcoded additions in the generated-provider
integration's corresponding application files.

The family generator also creates or updates these provider integration
surfaces:

- Unlinking, Syncer, and Importer components.
- Account DataHelpers and processors.
- The provider SDK.
- The cleanup job.
- Generated tests.
- `Provider::FamilyGenerator#update_accounts_controller` targeting
  `app/controllers/accounts_controller.rb`.
- `Provider::FamilyGenerator#update_accounts_index_view` targeting
  `app/views/accounts/index.html.erb`.
- `Provider::FamilyGenerator#update_source_enums` targeting
  `app/models/provider_merchant.rb` and `app/models/data_enrichment.rb`.

These generated outputs are distinct from the manual hardcoded registrations
and panel wiring described above.

## Routes

The settings provider connect form already has one generic route:
`get :provider_key/connect_form`. It is dispatched by
`Settings::ProvidersController#connect_form`; no provider-specific
connect-form route should be added.

Only genuinely provider-specific routes required by the generated controller
or resource belong in this checklist. The generic settings connect-form route
is not one of those additions.

## Current hardcoded provider registrations

Review the following existing registries and SQL dispatch branches when adding
a provider:

- `ProviderConnectionStatus::PROVIDERS`.
- `Provider::Metadata::PROVIDERS`.
- `Transaction::PENDING_PROVIDERS`.
- The pending-metadata SQL branches in
  `Account::ProviderImportAdapter`.

For Lunch Money, the approved design is posted-only: pending transactions are
intentionally omitted. The integration checklist must make that omission
explicit wherever these pending-provider registrations are considered; it
must not imply pending support or invent pending behavior.

## Naming note

The existing Lunch Flow integration uses `Lunchflow`/`lunchflow`. The approved
Lunch Money naming is documented elsewhere and is not derived from the current
source naming.
